import Darwin
import Foundation

/// Best-effort SoC die temperature on Apple Silicon via the private IOHIDEventSystemClient API,
/// resolved with dlsym so a missing symbol degrades to `nil` instead of a link/launch failure.
///
/// Sensors are HID services matching PrimaryUsagePage 0xff00 / PrimaryUsage 5; each one's
/// `Product` property is its name. Observed on Apple M2 (macOS 27): `PMU tdie1…8`
/// and `PMU2 tdie1…8` (on-die sensors), `PMU tdev1…8` / `PMU2 tdev1…5` (board/package, cooler,
/// some report −1.8), `PMU tcal` (a constant 51.85 calibration value), `NAND CH0 temp`,
/// `gas gauge battery` ×6, `als-temp` (no reading). Older macOS / other chips expose
/// `pACC MTR Temp Sensor*`, `eACC MTR…`, `SOC MTR…`, `GPU MTR…` instead.
///
/// Reported value: the MAX across all on-die sensors (`tdie`, `* MTR Temp Sensor*`,
/// `SOC Die`), i.e. the SoC hotspot – the number that drives throttling on a fanless Air and
/// the one that visibly rises under load (idle ≈ 41 °C, 8 busy threads → 51 °C within 8 s,
/// while the die average only moved 40 → 43 °C). Readings outside 10…130 °C are discarded.
/// If no die sensor exists, falls back to the max of any non-battery/NAND/calibration sensor.
///
/// One read of 16 sensors costs ≈ 0.5 ms CPU but 15–30 ms wall time (blocking IPC into the
/// PMU driver), so call it off the main thread. Not thread-safe: confine to one queue.
final class SoCTemperatureReader {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatchingFn = @convention(c) (CFTypeRef, CFDictionary) -> Void
    private typealias CopyServicesFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias GetFloatValueFn = @convention(c) (CFTypeRef, Int32) -> Double

    private struct API {
        let create: CreateFn
        let setMatching: SetMatchingFn
        let copyServices: CopyServicesFn
        let copyProperty: CopyPropertyFn
        let copyEvent: CopyEventFn
        let getFloatValue: GetFloatValueFn
    }

    private static let temperatureEventType: Int64 = 15            // kIOHIDEventTypeTemperature
    private static let temperatureLevelField: Int32 = 15 << 16     // IOHIDEventFieldBase(type)
    private static let validRange = 10.0...130.0

    private let api: API?
    private var client: CFTypeRef?
    private var sensors: [CFTypeRef] = []
    private var lastDiscovery: UInt64 = 0          // ns
    private var consecutiveFailures = 0

    /// Names of the sensors currently aggregated (for diagnostics).
    private(set) var sensorNames: [String] = []

    init() {
        api = Self.loadAPI()
    }

    /// Max on-die temperature in °C, or nil if unavailable.
    func read() -> Double? {
        guard let api else { return nil }
        if sensors.isEmpty || consecutiveFailures >= 3 {
            // Re-discover (first use, or services went stale e.g. after sleep), at most once a minute.
            let now = clock_gettime_nsec_np(CLOCK_MONOTONIC)
            guard lastDiscovery == 0 || now &- lastDiscovery > 60_000_000_000 else { return nil }
            lastDiscovery = now
            discover(api)
            consecutiveFailures = 0
        }

        var hottest: Double?
        for sensor in sensors {
            guard let event = api.copyEvent(sensor, Self.temperatureEventType, 0, 0)?.takeRetainedValue() else { continue }
            let value = api.getFloatValue(event, Self.temperatureLevelField)
            guard value.isFinite, Self.validRange.contains(value) else { continue }
            hottest = max(hottest ?? value, value)
        }
        consecutiveFailures = hottest == nil ? consecutiveFailures + 1 : 0
        return hottest
    }

    private func discover(_ api: API) {
        sensors = []
        sensorNames = []
        guard let client = api.create(kCFAllocatorDefault)?.takeRetainedValue() else { return }
        self.client = client
        let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
        api.setMatching(client, matching)
        guard let services = api.copyServices(client)?.takeRetainedValue() as? [CFTypeRef] else { return }

        var die: [(CFTypeRef, String)] = []
        var other: [(CFTypeRef, String)] = []
        for service in services {
            guard let name = api.copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String else { continue }
            let lower = name.lowercased()
            if Self.excluded.contains(where: lower.contains) { continue }
            if Self.dieMarkers.contains(where: lower.contains) {
                die.append((service, name))
            } else if !lower.contains("tdev") {
                other.append((service, name))
            }
        }
        let chosen = die.isEmpty ? other : die
        sensors = chosen.map(\.0)
        sensorNames = chosen.map(\.1)
    }

    private static let dieMarkers = ["tdie", "mtr temp sensor", "soc die"]
    private static let excluded = ["battery", "gas gauge", "nand", "tcal", "als-", "ssd"]

    private static func loadAPI() -> API? {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else { return nil }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        guard let create = symbol("IOHIDEventSystemClientCreate", as: CreateFn.self),
              let setMatching = symbol("IOHIDEventSystemClientSetMatching", as: SetMatchingFn.self),
              let copyServices = symbol("IOHIDEventSystemClientCopyServices", as: CopyServicesFn.self),
              let copyProperty = symbol("IOHIDServiceClientCopyProperty", as: CopyPropertyFn.self),
              let copyEvent = symbol("IOHIDServiceClientCopyEvent", as: CopyEventFn.self),
              let getFloatValue = symbol("IOHIDEventGetFloatValue", as: GetFloatValueFn.self)
        else { return nil }
        return API(create: create, setMatching: setMatching, copyServices: copyServices,
                   copyProperty: copyProperty, copyEvent: copyEvent, getFloatValue: getFloatValue)
    }
}
