import Foundation
import IOKit.ps

struct PowerReading: Equatable, Sendable {
    var batteryLevel: Double?        // 0...1, nil when there is no battery
    var isCharging: Bool
    var isPluggedIn: Bool
    var batteryTimeRemaining: Int?   // minutes; nil when calculating / unknown / not applicable
}

/// Battery + AC state via the IOKit power-sources API (~0.1 ms per read; stateless, any thread).
enum PowerSourceReader {
    static func read() -> PowerReading {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return PowerReading(batteryLevel: nil, isCharging: false, isPluggedIn: true, batteryTimeRemaining: nil)
        }
        // Works for desktops too ("AC Power" with no battery listed).
        let providing = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        var reading = PowerReading(batteryLevel: nil,
                                   isCharging: false,
                                   isPluggedIn: providing.map { $0 != kIOPSBatteryPowerValue } ?? true,
                                   batteryTimeRemaining: nil)

        let sources = (IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]) ?? []
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  (info[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  (info[kIOPSIsPresentKey] as? Bool) ?? true else { continue }

            if let current = info[kIOPSCurrentCapacityKey] as? Int,
               let max = info[kIOPSMaxCapacityKey] as? Int, max > 0 {
                reading.batteryLevel = Swift.min(1, Swift.max(0, Double(current) / Double(max)))
            }
            reading.isCharging = (info[kIOPSIsChargingKey] as? Bool) ?? false
            if let state = info[kIOPSPowerSourceStateKey] as? String {
                reading.isPluggedIn = state == kIOPSACPowerValue
            }
            // -1 means "still calculating"; 0 is reported when not applicable.
            let minutes: Int?
            if reading.isCharging {
                minutes = info[kIOPSTimeToFullChargeKey] as? Int
            } else if !reading.isPluggedIn {
                minutes = info[kIOPSTimeToEmptyKey] as? Int
            } else {
                minutes = nil   // on AC and not charging (full / charge hold): no estimate
            }
            reading.batteryTimeRemaining = minutes.flatMap { $0 > 0 ? $0 : nil }
            break
        }
        return reading
    }
}

/// Fires `handler` on the main thread whenever any power source changes (plug / unplug,
/// percentage, time estimate). Removes itself from the run loop on deinit.
final class PowerSourceObserver {
    private let handler: () -> Void
    private var source: CFRunLoopSource?

    init?(handler: @escaping () -> Void) {
        self.handler = handler
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<PowerSourceObserver>.fromOpaque(context).takeUnretainedValue().handler()
        }, context)?.takeRetainedValue() else { return nil }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    deinit {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
    }
}
