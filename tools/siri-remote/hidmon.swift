// hidmon: dump everything macOS delivers from the Siri Remote (and any new HID device).
//
//   swiftc -O hidmon.swift -o hidmon && ./hidmon [seconds]
//
// Lists every HID interface at startup, then prints raw input reports and parsed
// element values for Apple (0x004C) devices that aren't the usual keyboard/mouse/trackpad.

import Foundation
import IOKit.hid

let duration = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 60 : 60
let ignoredProducts: Set<Int> = [0x0320, 0x0323, 0x0265, 0x0269] // Magic keyboard/mouse/trackpad

func prop(_ d: IOHIDDevice, _ k: String) -> Any? { IOHIDDeviceGetProperty(d, k as CFString) }
func int(_ d: IOHIDDevice, _ k: String) -> Int { (prop(d, k) as? NSNumber)?.intValue ?? -1 }
func hex(_ p: UnsafePointer<UInt8>, _ n: Int) -> String {
    (0..<n).map { String(format: "%02x", p[$0]) }.joined(separator: " ")
}
func stamp() -> String { String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)) }

func describe(_ d: IOHIDDevice) -> String {
    let name = prop(d, kIOHIDProductKey) as? String ?? "?"
    let transport = prop(d, kIOHIDTransportKey) as? String ?? "?"
    return String(format: "%@ [%@] vid=0x%04x pid=0x%04x page=0x%04x usage=0x%04x",
                  name, transport, int(d, kIOHIDVendorIDKey), int(d, kIOHIDProductIDKey),
                  int(d, kIOHIDPrimaryUsagePageKey), int(d, kIOHIDPrimaryUsageKey))
}

func isTarget(_ d: IOHIDDevice) -> Bool {
    int(d, kIOHIDVendorIDKey) == 0x004C && !ignoredProducts.contains(int(d, kIOHIDProductIDKey))
        && (prop(d, kIOHIDTransportKey) as? String ?? "").lowercased().contains("bluetooth")
}

var buffers: [UnsafeMutablePointer<UInt8>] = []

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, nil)

IOHIDManagerRegisterDeviceMatchingCallback(manager, { _, _, _, device in
    let target = isTarget(device)
    print("\(stamp()) + \(describe(device))\(target ? "  <== watching" : "")")
    guard target else { return }

    if let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] {
        for e in elements where IOHIDElementGetType(e) != kIOHIDElementTypeCollection {
            print(String(format: "    element type=%d page=0x%04x usage=0x%04x report=0x%02x size=%d count=%d",
                         IOHIDElementGetType(e).rawValue, IOHIDElementGetUsagePage(e), IOHIDElementGetUsage(e),
                         IOHIDElementGetReportID(e), IOHIDElementGetReportSize(e), IOHIDElementGetReportCount(e)))
        }
    }

    let size = max(int(device, kIOHIDMaxInputReportSizeKey), 64)
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
    buffers.append(buf)
    IOHIDDeviceRegisterInputReportCallback(device, buf, size, { _, result, _, _, reportID, report, length in
        print("\(stamp()) report id=0x\(String(format: "%02x", reportID)) len=\(length) result=\(result): \(hex(report, length))")
    }, nil)
    IOHIDDeviceRegisterInputValueCallback(device, { _, _, _, value in
        let e = IOHIDValueGetElement(value)
        print(String(format: "%@ value page=0x%04x usage=0x%04x = %ld", stamp(),
                     IOHIDElementGetUsagePage(e), IOHIDElementGetUsage(e), IOHIDValueGetIntegerValue(value)))
    }, nil)
}, nil)

IOHIDManagerRegisterDeviceRemovalCallback(manager, { _, _, _, device in
    print("\(stamp()) - \(describe(device))")
}, nil)

IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
print("IOHIDManagerOpen: \(openResult == kIOReturnSuccess ? "ok" : String(format: "0x%08x", openResult)); listening \(Int(duration))s")

CFRunLoopRunInMode(CFRunLoopMode.defaultMode, duration, false)
print("done")
