// siri-bridge: drive the LG CineBeam (webOS) with a 2015 Siri Remote paired to this Mac.
//
//   swiftc -O siri-bridge.swift -o siri-bridge
//   ./siri-bridge [--host 192.168.1.249] [--ssh cleanbeam] [--pairing pairing.json] [--test BUTTON]
//
// Buttons come from the remote's HID button interface (report 0xFA, one bit per button).
// Swipes and taps come from its touchpad through the private MultitouchSupport framework. Keys
// go to the projector over LG's SSAP websocket API (pointer input socket, wss on port 3001).
// pairing.json is LG's remote-app manifest (from hobbyquaker/lgtv2, MIT); the client key the
// projector issues on first pairing is kept in ~/Library/Application Support/cleanbeam-remote.
//
// SSAP can only send complete key presses. With --ssh <host> (root SSH to the rooted projector),
// holding the touchpad click becomes a real long press of OK, written straight into the LG
// remote's input device, which opens context menus in apps like Plex and YouTube.

import Foundation
import IOKit.hid

let stampFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()
func log(_ s: String) { print("\(stampFormatter.string(from: Date())) \(s)"); fflush(stdout) }

var host = "192.168.1.249"
var pairingPath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    .deletingLastPathComponent().appendingPathComponent("pairing.json").path
var testButton: String?
var sshHost: String?
var argv = CommandLine.arguments.dropFirst().makeIterator()
while let a = argv.next() {
    switch a {
    case "--host": host = argv.next() ?? host
    case "--ssh": sshHost = argv.next()
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

    func request(_ uri: String) {
        guard pointer != nil else {
            log("not connected, dropped \(uri)")
            connect()
            return
        }
        log("-> \(uri)")
        send("request", uri: uri)
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
        if backoff < 30 { log("\(why); reconnecting in \(Int(backoff))s") }
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

// MARK: - Key injector (root SSH, for real long presses)

// Keeps one SSH session to the projector running a tiny Python 2 loop that writes key down/up
// events into the LG remote's input device (event1), so apps see a key held down.
final class KeyInjector {
    private let host: String
    private var process: Process?
    private var input: FileHandle?
    private var backoff = 5.0
    private var startedAt = Date()
    private static let script = """
    import os, struct, sys, time
    fd = os.open("/dev/input/event1", os.O_WRONLY)
    def ev(t, c, v):
        now = time.time()
        os.write(fd, struct.pack("llHHi", int(now), int(now % 1 * 1e6), t, c, v))
    while True:
        line = sys.stdin.readline()
        if not line:
            break
        action, code = line.split()
        ev(1, int(code), 1 if action == "d" else 0)
        ev(0, 0, 0)
    """

    init(host: String) {
        self.host = host
        start()
    }

    var isRunning: Bool { process?.isRunning ?? false }

    func down(_ code: Int) { write("d \(code)") }
    func up(_ code: Int) { write("u \(code)") }

    private func write(_ line: String) {
        guard isRunning, let input else {
            log("injector not running, dropped \(line)")
            return
        }
        log("-> inject \(line)")
        input.write(Data((line + "\n").utf8))
    }

    private func start() {
        let encoded = Data(Self.script.utf8).base64EncodedString()
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=30", host,
                       "python2.7 -u -c \"import base64; exec(base64.b64decode('\(encoded)'))\""]
        p.standardInput = pipe
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        // While the projector is off, back off to one attempt a minute instead of filling the log.
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if Date().timeIntervalSince(self.startedAt) > 60 { self.backoff = 5 }
                if self.backoff == 5 { log("injector exited; retrying every \(Int(self.backoff))–60s until the projector is back") }
                DispatchQueue.main.asyncAfter(deadline: .now() + self.backoff) { self.start() }
                self.backoff = min(self.backoff * 2, 60)
            }
        }
        do {
            try p.run()
            process = p
            input = pipe.fileHandleForWriting
            startedAt = Date()
        } catch {
            log("injector: \(error.localizedDescription)")
        }
    }
}

let injector = sshHost.map { KeyInjector(host: $0) }

if let testButton {
    projector.onReady = {
        projector.button(testButton)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
    }
    projector.connect()
    RunLoop.main.run()
}

// MARK: - Remote buttons (HID report 0xFA)

// A button with a long-press action sends its short key on release instead of on press, so a
// hold doesn't also fire the short key.
enum LongPress {
    case holdOK      // real held OK via the injector (context menus); plain ENTER without it
    case powerOff
}

struct ButtonMapping { let bit: UInt8; let key: String; let repeats: Bool; var longPress: LongPress? = nil }
let buttonMappings = [
    ButtonMapping(bit: 0x80, key: "ENTER", repeats: false, longPress: .holdOK),     // touchpad click
    ButtonMapping(bit: 0x20, key: "BACK", repeats: false),                          // Menu
    ButtonMapping(bit: 0x01, key: "HOME", repeats: false, longPress: .powerOff),    // TV
    ButtonMapping(bit: 0x10, key: "MENU", repeats: false),                          // Siri
    ButtonMapping(bit: 0x08, key: "PLAYPAUSE", repeats: false),
    ButtonMapping(bit: 0x02, key: "VOLUMEUP", repeats: true),
    ButtonMapping(bit: 0x04, key: "VOLUMEDOWN", repeats: true),
]
let longPressDelay = 0.5
let okKeyCode = 28 // KEY_ENTER, what the LG remote's OK sends

var heldButtons: UInt8 = 0
var repeatTimers: [UInt8: Timer] = [:]
var longPressTimers: [UInt8: Timer] = [:]
var longPressFired: Set<UInt8> = []
var paused = false
var clickedDuringStroke = false

// The pointer socket has separate PLAY and PAUSE keys, so alternate between them.
func press(_ key: String) {
    if key == "PLAYPAUSE" {
        projector.button(paused ? "PLAY" : "PAUSE")
        paused.toggle()
    } else {
        projector.button(key)
    }
}

func longPressBegan(_ m: ButtonMapping) {
    longPressFired.insert(m.bit)
    switch m.longPress {
    case .holdOK:
        if let injector, injector.isRunning { injector.down(okKeyCode) } else { press(m.key) }
    case .powerOff:
        projector.request("ssap://system/turnOff")
    case nil:
        break
    }
}

func longPressEnded(_ m: ButtonMapping) {
    if m.longPress == .holdOK, let injector, injector.isRunning { injector.up(okKeyCode) }
}

func buttonsChanged(_ state: UInt8) {
    for m in buttonMappings {
        let isDown = state & m.bit != 0, wasDown = heldButtons & m.bit != 0
        if isDown && !wasDown {
            if m.bit == 0x80 && strokeStart != nil { clickedDuringStroke = true }
            if m.longPress != nil {
                longPressTimers[m.bit] = Timer.scheduledTimer(withTimeInterval: longPressDelay, repeats: false) { _ in
                    longPressTimers[m.bit] = nil
                    longPressBegan(m)
                }
                continue
            }
            press(m.key)
            if m.repeats {
                repeatTimers[m.bit] = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in
                    repeatTimers[m.bit] = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in press(m.key) }
                }
            }
        } else if !isDown && wasDown {
            repeatTimers.removeValue(forKey: m.bit)?.invalidate()
            if let timer = longPressTimers.removeValue(forKey: m.bit) {
                timer.invalidate()
                press(m.key) // released before the long-press delay: a normal press
            } else if longPressFired.remove(m.bit) != nil {
                longPressEnded(m)
            }
        }
    }
    heldButtons = state
}

// Apple's driver also turns these buttons into Mac media keys (volume, Play/Pause opening Music),
// and seizing the HID device doesn't stop that. Remap them to F24, which macOS ignores, on the
// remote's own services only. The bridge reads raw reports, so it still sees every press. The
// mapping is lost whenever the remote reconnects, so it's reapplied on each connect.
let blankedUsages: [(page: UInt64, usage: UInt64)] = [
    (0x0C, 0xE9), (0x0C, 0xEA), (0x0C, 0xCD), (0x0C, 0x04), // vol+, vol−, play/pause, Siri
    (0x0C, 0x60), (0x0C, 0x30), (0x0C, 0x80), (0x01, 0x86), // TV, power, click, Menu
]

func blankMacMediaKeys() {
    let f24: UInt64 = 0x07 << 32 | 0x73
    let mapping = blankedUsages.map {
        String(format: "{\"HIDKeyboardModifierMappingSrc\":0x%llX,\"HIDKeyboardModifierMappingDst\":0x%llX}",
               $0.page << 32 | $0.usage, f24)
    }.joined(separator: ",")
    let hidutil = Process()
    hidutil.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
    hidutil.arguments = ["property", "--matching", "{\"VendorID\":0x4c,\"ProductID\":0x26d}",
                         "--set", "{\"UserKeyMapping\":[\(mapping)]}"]
    hidutil.standardOutput = FileHandle.nullDevice
    do {
        try hidutil.run()
        hidutil.waitUntilExit()
        if hidutil.terminationStatus != 0 { log("hidutil failed (\(hidutil.terminationStatus)): Mac media keys still active") }
    } catch {
        log("hidutil: \(error.localizedDescription)")
    }
}

var reportBuffers: [UnsafeMutablePointer<UInt8>] = []
let hid = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(hid, [kIOHIDVendorIDKey: 0x004C, kIOHIDProductIDKey: 0x026D,
                                    kIOHIDPrimaryUsagePageKey: 0x0C, kIOHIDPrimaryUsageKey: 0x01] as CFDictionary)
IOHIDManagerRegisterDeviceMatchingCallback(hid, { _, _, _, device in
    // Seize so macOS doesn't also act on Play/Pause and volume.
    let seized = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice)) == kIOReturnSuccess
    if !seized { _ = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
    log("remote buttons connected\(seized ? " (seized)" : "")")
    // The remote's key services can register a moment after its HID device, so apply twice.
    blankMacMediaKeys()
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { blankMacMediaKeys() }
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
let MTDeviceCreateFromService = sym("MTDeviceCreateFromService", (@convention(c) (io_service_t) -> MTDeviceRef?).self)
let MTRegisterContactFrameCallback = sym("MTRegisterContactFrameCallback", (@convention(c) (MTDeviceRef, ContactCallback) -> Void).self)
let MTDeviceStart = sym("MTDeviceStart", (@convention(c) (MTDeviceRef, Int32) -> Int32).self)
let remoteFamily: Int32 = 161

// One key per swipe, fired as soon as the finger has travelled far enough. Keeping the finger
// down after a swipe repeats that direction, for scrolling long lists.
// A quick tap near an edge sends that arrow, like the Apple TV remote: in a player, tapping the
// left or right edge skips back or forward. Taps in the middle, and taps that end in a click,
// do nothing.
let swipeDistance: Float = 0.3
let holdBeforeRepeat = 0.6, repeatInterval = 0.18
let tapMaxDuration = 0.35, tapMaxTravel: Float = 0.1, tapEdgeZone: Float = 0.2
var strokeStart: MTPoint?
var strokeStartTime = Date.distantPast
var strokeTravel: Float = 0
var strokeDirection: String?
var lastFired = Date.distantPast
var repeating = false

func strokeEnded() {
    defer {
        strokeStart = nil
        strokeDirection = nil
        repeating = false
        clickedDuringStroke = false
    }
    guard let start = strokeStart, strokeDirection == nil, !clickedDuringStroke, heldButtons & 0x80 == 0,
          strokeTravel <= tapMaxTravel, Date().timeIntervalSince(strokeStartTime) <= tapMaxDuration else { return }
    let dx = start.x - 0.5, dy = start.y - 0.5
    guard max(abs(dx), abs(dy)) >= tapEdgeZone else { return }
    projector.button(abs(dx) > abs(dy) ? (dx > 0 ? "RIGHT" : "LEFT") : (dy > 0 ? "UP" : "DOWN"))
}

func touchFrame(_ position: MTPoint?) {
    guard let position else {
        if strokeStart != nil { strokeEnded() }
        return
    }
    guard let start = strokeStart else {
        strokeStart = position
        strokeStartTime = Date()
        strokeTravel = 0
        return
    }
    strokeTravel = max(strokeTravel, abs(position.x - start.x), abs(position.y - start.y))
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

// The remote drops its BLE link when idle and comes back as a new multitouch device with a new
// ID. MTDeviceCreateList keeps returning the old, dead device in a long-running process, so
// watch IOKit for new AppleMultitouchDevice services instead and open each one directly.
func startTouchpad(_ service: io_service_t, attempt: Int = 1) {
    guard let dev = MTDeviceCreateFromService(service) else { return }
    MTRegisterContactFrameCallback(dev, contactCallback)
    let result = MTDeviceStart(dev, 0)
    if result == 0 {
        log("remote touchpad connected")
    } else if attempt < 5 {
        // The service can show up before it's ready to start.
        IOObjectRetain(service)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            startTouchpad(service, attempt: attempt + 1)
            IOObjectRelease(service)
        }
    } else {
        log("remote touchpad failed to start (\(result))")
    }
}

func touchpadsAppeared(_ iterator: io_iterator_t) {
    while case let service = IOIteratorNext(iterator), service != 0 {
        let family = IORegistryEntryCreateCFProperty(service, "Family ID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Int
        if family == Int(remoteFamily) { startTouchpad(service) }
        IOObjectRelease(service)
    }
}

let touchpadNotifications = IONotificationPortCreate(kIOMainPortDefault)
CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(touchpadNotifications).takeUnretainedValue(),
                   .defaultMode)
var touchpadIterator: io_iterator_t = 0
IOServiceAddMatchingNotification(touchpadNotifications, kIOFirstMatchNotification, IOServiceMatching("AppleMultitouchDevice"),
                                 { _, iterator in touchpadsAppeared(iterator) }, nil, &touchpadIterator)
touchpadsAppeared(touchpadIterator) // handles a remote that's already connected, and arms the notification

log("siri-bridge: projector \(host)")
projector.connect()
RunLoop.main.run()
