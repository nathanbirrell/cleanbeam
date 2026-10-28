// siri-bridge: drive the LG CineBeam (webOS) with a 2015 Siri Remote paired to this Mac.
//
//   swiftc -O siri-bridge.swift -o siri-bridge
//   ./siri-bridge [--host 192.168.1.249] [--pairing pairing.json] [--test BUTTON]
//
// Buttons come from the remote's HID button interface (report 0xFA, one bit per button).
// Swipes come from its touchpad through the private MultitouchSupport framework. Keys go to
// the projector over LG's SSAP websocket API (pointer input socket, wss on port 3001).
// pairing.json is LG's remote-app manifest (from hobbyquaker/lgtv2, MIT); the client key the
// projector issues on first pairing is kept in ~/Library/Application Support/cleanbeam-remote.

import Foundation
import IOKit.hid

let stampFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()
func log(_ s: String) { print("\(stampFormatter.string(from: Date())) \(s)"); fflush(stdout) }

var host = "192.168.1.249"
var pairingPath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    .deletingLastPathComponent().appendingPathComponent("pairing.json").path
var testButton: String?
var argv = CommandLine.arguments.dropFirst().makeIterator()
while let a = argv.next() {
    switch a {
    case "--host": host = argv.next() ?? host
    case "--pairing": pairingPath = argv.next() ?? pairingPath
    case "--test": testButton = argv.next()
    default: log("unknown argument \(a)"); exit(2)
    }
}

// MARK: - Projector (SSAP)

final class Projector: NSObject, URLSessionDelegate {
    private var session: URLSession!
    private var main: URLSessionWebSocketTask?
    private var pointer: URLSessionWebSocketTask?
    private var handlers: [String: ([String: Any]) -> Void] = [:]
    private var nextID = 0
    private var connecting = false
    private var backoff = 2.0
    private let keyFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/cleanbeam-remote/client-key")
    var onReady: (() -> Void)?

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.keepAlive() }
    }

    // The projector serves an LG-signed certificate that macOS doesn't trust; accept it for our host only.
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           challenge.protectionSpace.host == host, let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func connect() {
        guard !connecting, pointer == nil else { return }
        connecting = true
        let task = session.webSocketTask(with: URL(string: "wss://\(host):3001")!)
        main = task
        task.resume()
        receive(task)
        register()
    }

    func button(_ name: String) {
        guard let pointer else {
            log("not connected, dropped \(name)")
            connect()
            return
        }
        log("-> \(name)")
        pointer.send(.string("type:button\nname:\(name)\n\n")) { [weak self] err in
            if let err { self?.fail("pointer send: \(err.localizedDescription)") }
        }
    }

    private func register() {
        guard let data = FileManager.default.contents(atPath: pairingPath),
              var pairing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            log("can't read \(pairingPath)")
            exit(1)
        }
        if let key = try? String(contentsOf: keyFile, encoding: .utf8) {
            pairing["client-key"] = key.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            log("no client key yet: accept the connection prompt on the projector")
        }
        send("register", payload: pairing) { [weak self] msg in
            guard let self else { return }
            switch msg["type"] as? String {
            case "registered":
                if let key = (msg["payload"] as? [String: Any])?["client-key"] as? String {
                    try? FileManager.default.createDirectory(at: self.keyFile.deletingLastPathComponent(),
                                                             withIntermediateDirectories: true)
                    try? key.write(to: self.keyFile, atomically: true, encoding: .utf8)
                }
                log("registered with \(host)")
                self.openPointer()
            case "error":
                self.fail("register refused: \(msg["error"] ?? "?")")
            default:
                break // "response" while the pairing prompt is up
            }
        }
    }

    private func openPointer() {
        send("request", uri: "ssap://com.webos.service.networkinput/getPointerInputSocket") { [weak self] msg in
            guard let self else { return }
            guard let path = (msg["payload"] as? [String: Any])?["socketPath"] as? String, let url = URL(string: path) else {
                self.fail("no pointer socket in \(msg)")
                return
            }
            let task = self.session.webSocketTask(with: url)
            self.pointer = task
            task.resume()
            self.drain(task)
            self.connecting = false
            self.backoff = 2
            log("pointer socket open")
            self.onReady?()
        }
    }

    private func send(_ type: String, uri: String? = nil, payload: [String: Any]? = nil,
                      then: (([String: Any]) -> Void)? = nil) {
        nextID += 1
        let id = "\(type)_\(nextID)"
        var msg: [String: Any] = ["id": id, "type": type]
        if let uri { msg["uri"] = uri }
        if let payload { msg["payload"] = payload }
        if let then { handlers[id] = then }
        let text = String(data: try! JSONSerialization.data(withJSONObject: msg), encoding: .utf8)!
        main?.send(.string(text)) { [weak self] err in
            if let err { self?.fail("send: \(err.localizedDescription)") }
        }
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self, task === self.main else { return }
            switch result {
            case .failure(let err):
                self.fail("main socket: \(err.localizedDescription)")
            case .success(let message):
                if case .string(let text) = message,
                   let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                   let id = obj["id"] as? String {
                    self.handlers[id]?(obj)
                }
                self.receive(task)
            }
        }
    }

    private func drain(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self, task === self.pointer else { return }
            if case .failure(let err) = result { self.fail("pointer socket: \(err.localizedDescription)") } else { self.drain(task) }
        }
    }

    private func keepAlive() {
        main?.sendPing { [weak self] err in
            if let err { self?.fail("ping: \(err.localizedDescription)") }
        }
    }

    private func fail(_ why: String) {
        guard main != nil || pointer != nil else { return }
        log("\(why); reconnecting in \(Int(backoff))s")
        main?.cancel()
        pointer?.cancel()
        main = nil
        pointer = nil
        handlers = [:]
        connecting = false
        DispatchQueue.main.asyncAfter(deadline: .now() + backoff) { [weak self] in self?.connect() }
        backoff = min(backoff * 2, 30)
    }
}

let projector = Projector()

if let testButton {
    projector.onReady = {
        projector.button(testButton)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
    }
    projector.connect()
    RunLoop.main.run()
}

// MARK: - Remote buttons (HID report 0xFA)

struct ButtonMapping { let bit: UInt8; let label: String; let key: String; let repeats: Bool }
let buttonMappings = [
    ButtonMapping(bit: 0x80, label: "click", key: "ENTER", repeats: false),
    ButtonMapping(bit: 0x20, label: "menu", key: "BACK", repeats: false),
    ButtonMapping(bit: 0x01, label: "tv", key: "HOME", repeats: false),
    ButtonMapping(bit: 0x10, label: "siri", key: "MENU", repeats: false),
    ButtonMapping(bit: 0x08, label: "play/pause", key: "PLAYPAUSE", repeats: false),
    ButtonMapping(bit: 0x02, label: "vol+", key: "VOLUMEUP", repeats: true),
    ButtonMapping(bit: 0x04, label: "vol-", key: "VOLUMEDOWN", repeats: true),
]

var heldButtons: UInt8 = 0
var repeatTimers: [UInt8: Timer] = [:]
var paused = false

// The pointer socket has separate PLAY and PAUSE keys, so alternate between them.
func press(_ key: String) {
    if key == "PLAYPAUSE" {
        projector.button(paused ? "PLAY" : "PAUSE")
        paused.toggle()
    } else {
        projector.button(key)
    }
}

func buttonsChanged(_ state: UInt8) {
    for m in buttonMappings {
        let isDown = state & m.bit != 0, wasDown = heldButtons & m.bit != 0
        if isDown && !wasDown {
            press(m.key)
            if m.repeats {
                repeatTimers[m.bit] = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in
                    repeatTimers[m.bit] = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in press(m.key) }
                }
            }
        } else if !isDown && wasDown {
            repeatTimers.removeValue(forKey: m.bit)?.invalidate()
        }
    }
    heldButtons = state
}

var reportBuffers: [UnsafeMutablePointer<UInt8>] = []
let hid = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(hid, [kIOHIDVendorIDKey: 0x004C, kIOHIDProductIDKey: 0x026D,
                                    kIOHIDPrimaryUsagePageKey: 0x0C, kIOHIDPrimaryUsageKey: 0x01] as CFDictionary)
IOHIDManagerRegisterDeviceMatchingCallback(hid, { _, _, _, device in
    // Seize so macOS doesn't also act on Play/Pause and volume.
    let seized = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice)) == kIOReturnSuccess
    if !seized { _ = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
    log("remote buttons connected\(seized ? " (seized)" : " (not seized: macOS will also see presses)")")
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    reportBuffers.append(buffer)
    IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, { _, _, _, _, reportID, report, length in
        if reportID == 0xFA && length >= 2 { buttonsChanged(report[1]) }
    }, nil)
}, nil)
IOHIDManagerRegisterDeviceRemovalCallback(hid, { _, _, _, _ in
    log("remote buttons disconnected")
    buttonsChanged(0)
}, nil)
IOHIDManagerScheduleWithRunLoop(hid, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
IOHIDManagerOpen(hid, IOOptionBits(kIOHIDOptionsTypeNone))

// MARK: - Remote touchpad (MultitouchSupport)

// Layout of MultitouchSupport's per-finger struct (96 bytes on 64-bit).
struct MTPoint { var x: Float; var y: Float }
struct MTVector { var pos: MTPoint; var vel: MTPoint }
struct MTTouch {
    var frame: Int32; var timestamp: Double
    var identifier: Int32; var state: Int32; var unknown1: Int32; var unknown2: Int32
    var normalized: MTVector
    var size: Float; var zero1: Int32; var angle: Float; var majorAxis: Float; var minorAxis: Float
    var mm: MTVector
    var zero2: (Int32, Int32); var unknown3: Float
}

typealias MTDeviceRef = UnsafeMutableRawPointer
typealias ContactCallback = @convention(c) (MTDeviceRef?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32

let mts = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)!
func sym<T>(_ name: String, _: T.Type) -> T { unsafeBitCast(dlsym(mts, name)!, to: T.self) }
let MTDeviceCreateList = sym("MTDeviceCreateList", (@convention(c) () -> Unmanaged<CFArray>).self)
let MTRegisterContactFrameCallback = sym("MTRegisterContactFrameCallback", (@convention(c) (MTDeviceRef, ContactCallback) -> Void).self)
let MTDeviceStart = sym("MTDeviceStart", (@convention(c) (MTDeviceRef, Int32) -> Int32).self)
let MTDeviceIsRunning = sym("MTDeviceIsRunning", (@convention(c) (MTDeviceRef) -> Bool).self)
let MTDeviceGetFamilyID = sym("MTDeviceGetFamilyID", (@convention(c) (MTDeviceRef, UnsafeMutablePointer<Int32>) -> Int32).self)
let MTDeviceGetDeviceID = sym("MTDeviceGetDeviceID", (@convention(c) (MTDeviceRef, UnsafeMutablePointer<UInt64>) -> Int32).self)
let remoteFamily: Int32 = 161

// One key per swipe, fired as soon as the finger has travelled far enough. Keeping the finger
// down after a swipe repeats that direction, for scrolling long lists.
let swipeDistance: Float = 0.3
let holdBeforeRepeat = 0.6, repeatInterval = 0.18
var strokeStart: MTPoint?
var strokeDirection: String?
var lastFired = Date.distantPast
var repeating = false

func touchFrame(_ position: MTPoint?) {
    guard let position else {
        strokeStart = nil
        strokeDirection = nil
        repeating = false
        return
    }
    guard let start = strokeStart else {
        strokeStart = position
        return
    }
    if let direction = strokeDirection {
        let wait = repeating ? repeatInterval : holdBeforeRepeat
        if Date().timeIntervalSince(lastFired) >= wait {
            repeating = true
            lastFired = Date()
            projector.button(direction)
        }
        return
    }
    let dx = position.x - start.x, dy = position.y - start.y
    guard max(abs(dx), abs(dy)) >= swipeDistance else { return }
    let direction = abs(dx) > abs(dy) ? (dx > 0 ? "RIGHT" : "LEFT") : (dy > 0 ? "UP" : "DOWN")
    strokeDirection = direction
    lastFired = Date()
    projector.button(direction)
}

let contactCallback: ContactCallback = { _, touches, count, _, _ in
    var position: MTPoint?
    for i in 0..<Int(count) {
        let t = touches!.load(fromByteOffset: i * MemoryLayout<MTTouch>.stride, as: MTTouch.self)
        if (3...5).contains(t.state) { position = t.normalized.pos; break }
    }
    DispatchQueue.main.async { touchFrame(position) }
    return 0
}

var touchpads: [UInt64: MTDeviceRef] = [:]
var retainedTouchpads: [AnyObject] = []

// The remote drops its BLE link when idle and comes back as a new multitouch device, so keep rescanning.
func scanTouchpads() {
    for d in MTDeviceCreateList().takeRetainedValue() as [AnyObject] {
        let dev = Unmanaged.passUnretained(d).toOpaque()
        var family: Int32 = 0, id: UInt64 = 0
        _ = MTDeviceGetFamilyID(dev, &family)
        _ = MTDeviceGetDeviceID(dev, &id)
        guard family == remoteFamily else { continue }
        if let existing = touchpads[id], existing == dev || MTDeviceIsRunning(existing) { continue }
        MTRegisterContactFrameCallback(dev, contactCallback)
        _ = MTDeviceStart(dev, 0)
        touchpads[id] = dev
        retainedTouchpads.append(d)
        log("remote touchpad connected")
    }
}

scanTouchpads()
Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in scanTouchpads() }

log("siri-bridge: projector \(host)")
projector.connect()
RunLoop.main.run()
