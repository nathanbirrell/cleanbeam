// mtmon: stream touch frames from the Siri Remote's touchpad via the private
// MultitouchSupport framework (the remote shows up as an AppleMultitouchDevice).
//
//   swiftc -O mtmon.swift -o mtmon && ./mtmon [seconds] [--all]

import Foundation

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
let MTDeviceGetFamilyID = sym("MTDeviceGetFamilyID", (@convention(c) (MTDeviceRef, UnsafeMutablePointer<Int32>) -> Int32).self)
let MTDeviceGetDeviceID = sym("MTDeviceGetDeviceID", (@convention(c) (MTDeviceRef, UnsafeMutablePointer<UInt64>) -> Int32).self)
let MTDeviceIsRunning = sym("MTDeviceIsRunning", (@convention(c) (MTDeviceRef) -> Bool).self)
func isRunning(_ dev: MTDeviceRef) -> Bool { MTDeviceIsRunning(dev) }

let duration = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 60 : 60
let remoteFamily: Int32 = 161

let callback: ContactCallback = { device, touches, count, timestamp, frame in
    var id: UInt64 = 0
    if let device { _ = MTDeviceGetDeviceID(device, &id) }
    var line = String(format: "%.3f dev=%llu frame=%d n=%d", timestamp, id, frame, count)
    for i in 0..<Int(count) {
        let t = touches!.load(fromByteOffset: i * MemoryLayout<MTTouch>.stride, as: MTTouch.self)
        line += String(format: " | id=%d st=%d x=%.3f y=%.3f vx=%.2f vy=%.2f size=%.2f",
                       t.identifier, t.state, t.normalized.pos.x, t.normalized.pos.y,
                       t.normalized.vel.x, t.normalized.vel.y, t.size)
    }
    print(line)
    fflush(stdout)
    return 0
}

let includeAll = CommandLine.arguments.contains("--all") // also stream the Mac's own trackpad, to sanity-check
var startedRefs: [UInt64: UnsafeMutableRawPointer] = [:]
var retained: [AnyObject] = []

// The remote drops its BLE link when idle and comes back as a new multitouch device, so keep rescanning.
func scan() {
    let devices = MTDeviceCreateList().takeRetainedValue() as [AnyObject]
    for d in devices {
        let dev = Unmanaged.passUnretained(d).toOpaque()
        var family: Int32 = 0, id: UInt64 = 0
        _ = MTDeviceGetFamilyID(dev, &family)
        _ = MTDeviceGetDeviceID(dev, &id)
        // MTDeviceCreateList hands back fresh refs each call; only a reconnect should start a device again.
        if startedRefs[id] == dev || (startedRefs[id] != nil && isRunning(startedRefs[id]!)) { continue }
        let isRemote = family == remoteFamily
        guard isRemote || includeAll else { continue }
        MTRegisterContactFrameCallback(dev, callback)
        let r = MTDeviceStart(dev, 0)
        startedRefs[id] = dev
        retained.append(d)
        print("started id=\(id) family=\(family)\(isRemote ? " (Siri Remote)" : "") result=\(r)")
        fflush(stdout)
    }
}

scan()
let timer = Timer(timeInterval: 1, repeats: true) { _ in scan() }
RunLoop.current.add(timer, forMode: .default)
print("listening \(Int(duration))s")
fflush(stdout)
CFRunLoopRunInMode(.defaultMode, duration, false)
print("done")
