// siri-bridge: drive the LG CineBeam (webOS) with a 2015 Siri Remote paired to this Mac.
//
//   swiftc -O siri-bridge.swift -o siri-bridge
//   ./siri-bridge --host <projector-ip> [--ssh <ssh-alias>] [--wake <wifi-mac>] [--pairing pairing.json]
//                 [--test BUTTON]
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
//
// With --wake <mac> (the projector's Wi-Fi MAC, and LG's "turn on via Wi-Fi" setting on), a
// button press while the projector is unreachable sends a Wake-on-LAN packet to turn it on.

import Foundation
import IOKit.hid

let stampFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()
func log(_ s: String) { print("\(stampFormatter.string(from: Date())) \(s)"); fflush(stdout) }

var host = ""
var pairingPath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    .deletingLastPathComponent().appendingPathComponent("pairing.json").path
var testButton: String?
var sshHost: String?
var wakeMAC: String?
var argv = CommandLine.arguments.dropFirst().makeIterator()
while let a = argv.next() {
    switch a {
    case "--host": host = argv.next() ?? host
    case "--ssh": sshHost = argv.next()
    case "--wake": wakeMAC = argv.next()
    case "--pairing": pairingPath = argv.next() ?? pairingPath
    case "--test": testButton = argv.next()
    default: log("unknown argument \(a)"); exit(2)
    }
}
if host.isEmpty {
    log("usage: siri-bridge --host <projector-ip> [--ssh <ssh-alias>] [--wake <wifi-mac>] [--pairing pairing.json] [--test BUTTON]")
    exit(2)
}

// Wake-on-LAN magic packet: 6 × 0xFF, then the MAC 16 times. Sent to the limited broadcast, the
// projector's /24 broadcast and the projector itself, on UDP port 9.
func sendWakeOnLAN(mac: String) {
    let bytes = mac.split(whereSeparator: { $0 == ":" || $0 == "-" }).compactMap { UInt8($0, radix: 16) }
    guard bytes.count == 6 else {
        log("bad --wake MAC \(mac)")
        return
    }
    let packet = [UInt8](repeating: 0xFF, count: 6) + Array([[UInt8]](repeating: bytes, count: 16).joined())
    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard fd >= 0 else { return }
    defer { close(fd) }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
    var targets = ["255.255.255.255"]
    let octets = host.split(separator: ".")
    if octets.count == 4 { targets += [octets.prefix(3).joined(separator: ".") + ".255", host] }
    for target in targets {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(9).bigEndian
        guard inet_pton(AF_INET, target, &addr.sin_addr) == 1 else { continue }
        _ = packet.withUnsafeBytes { buffer in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
    log("-> wake-on-LAN \(mac)")
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
    private var lastWake = Date.distantPast
    private let keyFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/cleanbeam-remote/client-key")
    var onReady: (() -> Void)?

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5 // don't sit on a projector that's off
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
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

    // A press while the projector is unreachable wakes it (with --wake) and retries quickly, so
    // keys work again as soon as it's up. The press itself is dropped, like waking an Apple TV.
    private func wakeAndConnect() {
        if let wakeMAC, Date().timeIntervalSince(lastWake) > 3 {
            lastWake = Date()
            sendWakeOnLAN(mac: wakeMAC)
        }
        backoff = 2
        connect()
    }

    func button(_ name: String) {
        guard let pointer else {
            log("not connected, dropped \(name)")
            wakeAndConnect()
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
            wakeAndConnect()
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
            injector?.startIfStopped()
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
        // Right after a wake the projector is booting, so keep retrying quickly.
        backoff = Date().timeIntervalSince(lastWake) < 60 ? 2 : min(backoff * 2, 30)
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
    private var pendingRestart: DispatchWorkItem?
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

    // Called once the projector is reachable again, so long presses work without waiting out the backoff.
    func startIfStopped() {
        guard !isRunning else { return }
        pendingRestart?.cancel()
        backoff = 5
        start()
    }

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
        p.terminationHandler = { [weak self] exited in
            DispatchQueue.main.async {
                guard let self, exited === self.process else { return }
                if Date().timeIntervalSince(self.startedAt) > 60 { self.backoff = 5 }
                if self.backoff == 5 { log("injector exited; retrying every \(Int(self.backoff))–60s until the projector is back") }
                let restart = DispatchWorkItem { self.start() }
                self.pendingRestart = restart
                DispatchQueue.main.asyncAfter(deadline: .now() + self.backoff, execute: restart)
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
// Held volume repeats after repeatDelay, then speeds up: each gap is repeatAcceleration times the
// last, down to repeatFastestInterval (about 6 steps a second at first, 22 after about 1s).
let repeatDelay = 0.4, repeatStartInterval = 0.16, repeatAcceleration = 0.8, repeatFastestInterval = 0.045

func scheduleRepeat(_ m: ButtonMapping, after delay: Double, next interval: Double) {
    repeatTimers[m.bit] = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
        press(m.key)
        scheduleRepeat(m, after: interval, next: max(interval * repeatAcceleration, repeatFastestInterval))
    }
}
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
            cancelBursts()
            streakLength = 0
            if m.bit == 0x80 && strokeStart != nil { clickedDuringStroke = true }
            if m.longPress != nil {
                longPressTimers[m.bit] = Timer.scheduledTimer(withTimeInterval: longPressDelay, repeats: false) { _ in
                    longPressTimers[m.bit] = nil
                    longPressBegan(m)
                }
                continue
            }
            press(m.key)
            if m.repeats { scheduleRepeat(m, after: repeatDelay, next: repeatStartInterval) }
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

// Swipes: the first arrow fires once the finger has travelled swipeDistance, which also locks
// the stroke to that axis. Every further stepDistance along the axis sends another arrow (moving
// back sends the opposite one), so a long drag walks through a grid or skips repeatedly in a
// player. A fast flick keeps going for a few more arrows after the finger lifts. Resting the
// finger after a swipe repeats the last arrow.
// A quick tap near an edge sends that arrow, like the Apple TV remote: in a player, tapping the
// left or right edge skips back or forward. Taps in the middle, and taps that end in a click,
// do nothing.
// Distances are in pad widths (0...1) and speeds in pad widths per second.
let swipeDistance: Float = 0.3
let stepDistance: Float = 0.2
let flickSpeed: Float = 6, flickStepSpeed: Float = 3, maxFlickSteps = 5
let restSpeed: Float = 0.3
let holdBeforeRepeat = 0.6, repeatInterval = 0.18
let tapMaxDuration = 0.35, tapMaxTravel: Float = 0.1, tapEdgeZone: Float = 0.2
var strokeStart: MTPoint?
var strokeStartTime = Date.distantPast
var strokeTravel: Float = 0
var strokeHorizontal: Bool?        // axis, locked by the first arrow
var strokeAnchor: Float = 0        // position along that axis where the last step fired
var strokeDirection: String?       // last arrow sent, repeated while the finger rests
var strokeSteps = 0
var recentPositions: [(time: Double, position: MTPoint)] = [] // time: the touchpad's own frame timestamp
var restingSince: Date?
var lastFired = Date.distantPast
var repeating = false

// Streaks: big swipes (bigSwipeSteps or more steps, or a flick) in quick succession the same way
// scale every arrow in that direction, so a run of swipes scrubs quickly through a 3-hour movie.
// A pause longer than streakGap, a small swipe or a change of direction resets it.
let streakGap = 1.0, bigSwipeSteps = 3
let streakMultipliers = [1, 2, 3, 5, 8]
var streakDirection: String?
var streakLength = 0                 // big swipes so far in the current streak
var streakLastEnded = Date.distantPast
var strokeFirstDirection: String?    // direction of this stroke's first arrow
var strokeMultiplier = 1             // presses per arrow in that direction, for this stroke
var burstClock = Date.distantPast
var burstGeneration = 0
let burstSpacing = 0.03, maxBurstBacklog = 0.25

func arrow(horizontal: Bool, positive: Bool) -> String {
    horizontal ? (positive ? "RIGHT" : "LEFT") : (positive ? "UP" : "DOWN")
}

// Sends count presses burstSpacing apart, queued behind any burst still going out so the order
// holds. Presses that would land more than maxBurstBacklog behind are dropped, so scrolling stops
// as soon as the swiping does instead of playing out a backlog.
func send(_ key: String, count: Int) {
    let generation = burstGeneration
    for _ in 0..<count {
        let at = max(Date(), burstClock.addingTimeInterval(burstSpacing))
        let delay = at.timeIntervalSinceNow
        guard delay <= maxBurstBacklog else { return }
        burstClock = at
        if delay <= 0 { projector.button(key) } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if generation == burstGeneration { projector.button(key) }
            }
        }
    }
}

// Drops any queued presses: on a button press, a tap or a change of swipe direction.
func cancelBursts() {
    burstGeneration += 1
    burstClock = .distantPast
}

func fire(_ direction: String, scaled: Bool = true) {
    strokeDirection = direction
    strokeSteps += 1
    lastFired = Date()
    send(direction, count: scaled && direction == strokeFirstDirection ? strokeMultiplier : 1)
}

// Signed speed along one axis over the last ~60 ms, using the touchpad's frame timestamps:
// frames can reach the main queue in bunches, so arrival times would give absurd speeds.
func recentSpeed(horizontal: Bool) -> Float {
    guard let last = recentPositions.last,
          let first = recentPositions.first(where: { last.time - $0.time <= 0.06 }),
          last.time - first.time >= 0.03 else { return 0 }
    let distance = horizontal ? last.position.x - first.position.x : last.position.y - first.position.y
    return distance / Float(last.time - first.time)
}

func strokeEnded() {
    defer {
        strokeStart = nil
        strokeHorizontal = nil
        strokeDirection = nil
        strokeSteps = 0
        strokeFirstDirection = nil
        strokeMultiplier = 1
        recentPositions.removeAll()
        restingSince = nil
        repeating = false
        clickedDuringStroke = false
    }
    if let horizontal = strokeHorizontal {
        let speed = recentSpeed(horizontal: horizontal)
        var extra = 0
        if abs(speed) >= flickSpeed {
            extra = min(Int((abs(speed) - flickSpeed) / flickStepSpeed) + 1, maxFlickSteps)
            let direction = arrow(horizontal: horizontal, positive: speed > 0)
            send(direction, count: extra * (direction == strokeFirstDirection ? strokeMultiplier : 1))
        }
        if strokeSteps >= bigSwipeSteps || extra > 0 {
            streakLength += 1
            streakLastEnded = Date()
        } else {
            streakLength = 0
        }
        log(String(format: "swipe: %d step(s) x%d, lift speed %.1f, +%d flick, streak %d",
                   strokeSteps, strokeMultiplier, abs(speed), extra, streakLength))
        return
    }
    guard let start = strokeStart, !clickedDuringStroke, heldButtons & 0x80 == 0,
          strokeTravel <= tapMaxTravel, Date().timeIntervalSince(strokeStartTime) <= tapMaxDuration else { return }
    let dx = start.x - 0.5, dy = start.y - 0.5
    guard max(abs(dx), abs(dy)) >= tapEdgeZone else { return }
    cancelBursts()
    streakLength = 0
    projector.button(arrow(horizontal: abs(dx) > abs(dy), positive: abs(dx) > abs(dy) ? dx > 0 : dy > 0))
}

func touchFrame(_ position: MTPoint?, at frameTime: Double) {
    guard let position else {
        if strokeStart != nil { strokeEnded() }
        return
    }
    let now = Date()
    recentPositions.append((frameTime, position))
    recentPositions.removeAll { frameTime - $0.time > 0.2 }
    guard let start = strokeStart else {
        strokeStart = position
        strokeStartTime = now
        strokeTravel = 0
        return
    }
    strokeTravel = max(strokeTravel, abs(position.x - start.x), abs(position.y - start.y))

    guard let horizontal = strokeHorizontal else {
        let dx = position.x - start.x, dy = position.y - start.y
        guard max(abs(dx), abs(dy)) >= swipeDistance else { return }
        let h = abs(dx) > abs(dy)
        let direction = arrow(horizontal: h, positive: (h ? dx : dy) > 0)
        if direction != streakDirection { cancelBursts() }
        if direction != streakDirection || Date().timeIntervalSince(streakLastEnded) > streakGap {
            streakLength = 0
            streakDirection = direction
        }
        strokeHorizontal = h
        strokeAnchor = h ? position.x : position.y
        strokeFirstDirection = direction
        strokeMultiplier = streakMultipliers[min(streakLength, streakMultipliers.count - 1)]
        fire(direction)
        return
    }

    let along = horizontal ? position.x : position.y
    if abs(along - strokeAnchor) >= stepDistance {
        let positive = along > strokeAnchor
        strokeAnchor += positive ? stepDistance : -stepDistance
        restingSince = nil
        repeating = false
        fire(arrow(horizontal: horizontal, positive: positive))
        return
    }

    if abs(recentSpeed(horizontal: horizontal)) >= restSpeed {
        restingSince = nil
        repeating = false
        return
    }
    let rest = restingSince ?? now
    restingSince = rest
    guard let direction = strokeDirection else { return }
    let due = repeating ? now.timeIntervalSince(lastFired) >= repeatInterval : now.timeIntervalSince(rest) >= holdBeforeRepeat
    if due {
        repeating = true
        fire(direction, scaled: false)
    }
}

let contactCallback: ContactCallback = { _, touches, count, timestamp, _ in
    var position: MTPoint?
    for i in 0..<Int(count) {
        let t = touches!.load(fromByteOffset: i * MemoryLayout<MTTouch>.stride, as: MTTouch.self)
        if (3...5).contains(t.state) { position = t.normalized.pos; break }
    }
    DispatchQueue.main.async { touchFrame(position, at: timestamp) }
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
