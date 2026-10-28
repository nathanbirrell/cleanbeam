// featureget: read (never write) every feature report the Siri Remote exposes.
//
//   swiftc -O featureget.swift -o featureget && ./featureget

import Foundation
import IOKit.hid

func prop(_ d: IOHIDDevice, _ k: String) -> Int { (IOHIDDeviceGetProperty(d, k as CFString) as? NSNumber)?.intValue ?? -1 }

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x004C, kIOHIDProductIDKey: 0x026D] as CFDictionary)
IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
print("\(devices.count) remote interfaces")
for d in devices.sorted(by: { prop($0, kIOHIDPrimaryUsagePageKey) * 0x10000 + prop($0, kIOHIDPrimaryUsageKey) < prop($1, kIOHIDPrimaryUsagePageKey) * 0x10000 + prop($1, kIOHIDPrimaryUsageKey) }) {
    print(String(format: "== page=0x%04x usage=0x%04x maxFeature=%d", prop(d, kIOHIDPrimaryUsagePageKey), prop(d, kIOHIDPrimaryUsageKey), prop(d, kIOHIDMaxFeatureReportSizeKey)))
    let open = IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone))
    if open != kIOReturnSuccess { print(String(format: "   open failed 0x%08x", open)); continue }
    let ids = Set(((IOHIDDeviceCopyMatchingElements(d, nil, 0) as? [IOHIDElement]) ?? [])
        .filter { IOHIDElementGetType($0) == kIOHIDElementTypeFeature }.map { IOHIDElementGetReportID($0) })
    for id in ids.sorted() {
        var len = 512
        var buf = [UInt8](repeating: 0, count: len)
        let r = IOHIDDeviceGetReport(d, kIOHIDReportTypeFeature, CFIndex(id), &buf, &len)
        let hex = buf.prefix(len).map { String(format: "%02x", $0) }.joined(separator: " ")
        print(String(format: "   feature 0x%02x: result=0x%08x len=%d %@", id, r, len, r == kIOReturnSuccess ? hex : ""))
    }
    IOHIDDeviceClose(d, 0)
}
