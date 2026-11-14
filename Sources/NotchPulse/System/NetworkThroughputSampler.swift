import Darwin

struct NetworkThroughput: Equatable, Sendable {
    var downBytesPerSec: Double
    var upBytesPerSec: Double
}

/// Network throughput from per-interface 64-bit byte counters (`sysctl NET_RT_IFLIST2`,
/// `if_msghdr2.ifm_data.ifi_ibytes/ifi_obytes`).
///
/// Only interfaces that are UP + RUNNING, not loopback, and named `en*` are summed
/// (Wi-Fi, Ethernet, USB/iPhone tethering). Everything else is excluded to avoid double
/// counting the same bytes: utun/ipsec/ppp (VPN tunnels ride on en*), awdl/llw (AirDrop
/// peer links), bridge*/vmenet* (Thunderbolt bridge / VM NAT), ap* (Internet Sharing),
/// anpi/gif/stf/nan (internal / unused). Not thread-safe: confine to one queue.
final class NetworkThroughputSampler {
    private struct Counters { var rx: UInt64; var tx: UInt64 }

    private var previous: [String: Counters] = [:]
    private var previousTime: UInt64 = 0   // ns, CLOCK_MONOTONIC (keeps ticking through sleep)

    func reset() {
        previous.removeAll(keepingCapacity: true)
        previousTime = 0
    }

    /// Bytes/sec since the previous call; nil on the first call, on failure, or after a long gap
    /// (sleep / suspended timer), in which case the baseline is simply re-primed.
    func sample() -> NetworkThroughput? {
        guard let current = Self.readCounters() else { return nil }
        let now = clock_gettime_nsec_np(CLOCK_MONOTONIC)
        defer {
            previous = current
            previousTime = now
        }
        guard previousTime != 0, now > previousTime else { return nil }
        let elapsed = Double(now - previousTime) / 1e9
        guard elapsed >= 0.05, elapsed <= 60 else { return nil }

        var rx: UInt64 = 0
        var tx: UInt64 = 0
        for (name, cur) in current {
            // Interfaces that just appeared contribute from the next sample on. A counter that
            // went backwards means the interface was reset/re-created: count 0 this round.
            guard let prev = previous[name] else { continue }
            if cur.rx >= prev.rx { rx &+= cur.rx - prev.rx }
            if cur.tx >= prev.tx { tx &+= cur.tx - prev.tx }
        }
        return NetworkThroughput(downBytesPerSec: Double(rx) / elapsed, upBytesPerSec: Double(tx) / elapsed)
    }

    private static func readCounters() -> [String: Counters]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        var buffer: [UInt8] = []
        // The table can grow between the size query and the read; retry with slack.
        for _ in 0..<3 {
            guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
            length += length / 8
            buffer = [UInt8](repeating: 0, count: length)
            if sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 { break }
            guard errno == ENOMEM else { return nil }
            buffer = []
        }
        guard !buffer.isEmpty else { return nil }

        let headerSize = MemoryLayout<if_msghdr2>.size
        let nameLengthOffset = MemoryLayout<sockaddr_dl>.offset(of: \sockaddr_dl.sdl_nlen) ?? 5
        let nameDataOffset = MemoryLayout<sockaddr_dl>.offset(of: \sockaddr_dl.sdl_data) ?? 8
        let wantedFlags = Int32(IFF_UP | IFF_RUNNING)

        var result: [String: Counters] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + 4 <= length {
                let messageLength = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard messageLength > 0, offset + messageLength <= length else { break }
                defer { offset += messageLength }

                let type = raw.loadUnaligned(fromByteOffset: offset + 3, as: UInt8.self)
                guard Int32(type) == RTM_IFINFO2, messageLength >= headerSize else { continue }
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                guard header.ifm_flags & wantedFlags == wantedFlags,
                      header.ifm_flags & Int32(IFF_LOOPBACK) == 0 else { continue }

                // The interface's sockaddr_dl (carrying its name) follows the header.
                let sdl = offset + headerSize
                guard sdl + nameDataOffset <= offset + messageLength else { continue }
                let nameLength = Int(raw.loadUnaligned(fromByteOffset: sdl + nameLengthOffset, as: UInt8.self))
                let nameStart = sdl + nameDataOffset
                guard nameLength > 0, nameStart + nameLength <= offset + messageLength else { continue }
                let name = String(decoding: UnsafeRawBufferPointer(rebasing: raw[nameStart..<(nameStart + nameLength)]),
                                  as: UTF8.self)
                guard name.hasPrefix("en") else { continue }

                result[name] = Counters(rx: header.ifm_data.ifi_ibytes, tx: header.ifm_data.ifi_obytes)
            }
        }
        return result
    }
}
