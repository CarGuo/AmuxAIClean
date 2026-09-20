import Darwin
import Foundation
import IOKit.ps
import LogKit

struct SystemCPUTicks: Sendable, Equatable {
    let user: UInt32
    let system: UInt32
    let idle: UInt32
    let nice: UInt32

    func utilization(since previous: Self) -> Double? {
        let busy =
            UInt64(user &- previous.user) + UInt64(system &- previous.system)
            + UInt64(nice &- previous.nice)
        let total = busy + UInt64(idle &- previous.idle)
        return total > 0 ? Double(busy) / Double(total) : nil
    }
}

struct SystemNetworkCounter: Sendable, Equatable {
    let received: UInt64
    let sent: UInt64

    /// NET_RT_IFLIST2 contains 64-bit byte counters. getifaddrs exposes if_data's
    /// 32-bit counters, which can wrap between two samples on a fast interface.
    static func parseInterfaceList(_ data: Data) -> [String: Self]? {
        data.withUnsafeBytes { buffer in
            var counters: [String: Self] = [:]
            var offset = 0
            while offset < buffer.count {
                guard buffer.count - offset >= 4 else { return nil }
                let length = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard length >= 4, length <= buffer.count - offset else { return nil }
                let type = buffer.load(fromByteOffset: offset + 3, as: UInt8.self)
                if type == RTM_IFINFO2 {
                    guard length >= MemoryLayout<if_msghdr2>.size else { return nil }
                    let entry = buffer.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    // Exclude virtual tunnels and loopback so the same traffic is not counted twice.
                    if entry.ifm_flags & IFF_UP != 0, entry.ifm_flags & IFF_LOOPBACK == 0,
                        entry.ifm_data.ifi_type == IFT_ETHER
                    {
                        counters[String(entry.ifm_index)] = Self(
                            received: entry.ifm_data.ifi_ibytes, sent: entry.ifm_data.ifi_obytes)
                    }
                }
                offset += length
            }
            return counters
        }
    }
}

struct SystemNetworkRate: Sendable, Equatable {
    let received: Double
    let sent: Double

    static func between(
        previous: [String: SystemNetworkCounter],
        current: [String: SystemNetworkCounter], elapsed: Double
    ) -> Self? {
        guard elapsed.isFinite, elapsed > 0 else { return nil }
        var received = 0.0
        var sent = 0.0
        var matched = false
        for (name, counter) in current {
            guard let old = previous[name], counter.received >= old.received,
                counter.sent >= old.sent
            else { continue }
            matched = true
            received += Double(counter.received - old.received) / elapsed
            sent += Double(counter.sent - old.sent) / elapsed
        }
        return matched ? Self(received: received, sent: sent) : nil
    }
}

struct SystemMemorySnapshot: Sendable, Equatable {
    let used: UInt64
    let total: UInt64
    let compressed: UInt64
    var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

enum SystemBatterySnapshot: Sendable, Equatable {
    case unavailable
    case notPresent
    case battery(fraction: Double, charging: Bool, onACPower: Bool, minutesRemaining: Int?)

    var fraction: Double? {
        if case .battery(let fraction, _, _, _) = self { return fraction }
        return nil
    }
}

struct SystemStatusSample: Sendable, Equatable {
    let uptime: TimeInterval
    let cpu: Double?
    let memory: SystemMemorySnapshot?
    let network: SystemNetworkRate?
    let battery: SystemBatterySnapshot
    let thermalState: Int
}

/// v2026.09.06: read-only native metrics. All Mach, network and IOKit calls run on
/// this actor; the UI receives a small immutable sample every two seconds. Rates
/// need two real samples, interface replacement cannot manufacture traffic, and
/// missing probes remain unknown rather than displaying invented zeroes.
actor SystemStatusSampler {
    private var previousCPU: SystemCPUTicks?
    private var previousNetwork: [String: SystemNetworkCounter]?
    private var previousUptime: TimeInterval?
    private var failedProbes: Set<String> = []

    func reset() {
        previousCPU = nil
        previousNetwork = nil
        previousUptime = nil
    }

    func sample() -> SystemStatusSample {
        let uptime = ProcessInfo.processInfo.systemUptime
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let ticks = cpuTicks(host: host)
        let cpu = ticks.flatMap { value in previousCPU.flatMap { value.utilization(since: $0) } }
        let network = networkCounters()
        let rate: SystemNetworkRate?
        if let network, let previousNetwork, let previousUptime {
            rate = .between(previous: previousNetwork, current: network, elapsed: uptime - previousUptime)
        } else {
            rate = nil
        }
        previousCPU = ticks
        previousNetwork = network
        previousUptime = uptime
        return SystemStatusSample(
            uptime: uptime, cpu: cpu, memory: memory(host: host),
            network: rate, battery: battery(),
            thermalState: ProcessInfo.processInfo.thermalState.rawValue)
    }

    private func cpuTicks(host: host_t) -> SystemCPUTicks? {
        var info = host_cpu_load_info_data_t()
        let capacity = MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(capacity)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard report("cpu", code: status) else { return nil }
        return SystemCPUTicks(
            user: info.cpu_ticks.0, system: info.cpu_ticks.1,
            idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
    }

    private func memory(host: host_t) -> SystemMemorySnapshot? {
        var info = vm_statistics64_data_t()
        let capacity = MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(capacity)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard report("memory", code: status) else { return nil }
        var pageSize: vm_size_t = 0
        guard report("page_size", code: host_page_size(host, &pageSize)) else { return nil }
        let pages =
            UInt64(info.active_count) + UInt64(info.inactive_count)
            + UInt64(info.wire_count) + UInt64(info.compressor_page_count)
        let cached = UInt64(info.purgeable_count) + UInt64(info.external_page_count)
        let total = ProcessInfo.processInfo.physicalMemory
        let used = (pages > cached ? pages - cached : 0) * UInt64(pageSize)
        return SystemMemorySnapshot(
            used: min(total, used), total: total,
            compressed: UInt64(info.compressor_page_count) * UInt64(pageSize))
    }

    private func networkCounters() -> [String: SystemNetworkCounter]? {
        // v2026.09.06: preserve kernel counters at their native 64-bit width.
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else {
            _ = report("network", code: kern_return_t(errno))
            return nil
        }
        var data = Data(count: size)
        let result = data.withUnsafeMutableBytes { buffer in
            sysctl(&mib, u_int(mib.count), buffer.baseAddress, &size, nil, 0)
        }
        guard result == 0 else {
            _ = report("network", code: kern_return_t(errno))
            return nil
        }
        guard let counters = SystemNetworkCounter.parseInterfaceList(data.prefix(size)) else {
            _ = report("network", code: kern_return_t(EINVAL))
            return nil
        }
        _ = report("network", code: 0)
        return counters
    }

    private func battery() -> SystemBatterySnapshot {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return .unavailable }
        for source in sources {
            guard
                let values = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                    as? [String: Any],
                values[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }
            guard let current = values[kIOPSCurrentCapacityKey] as? Int,
                let maximum = values[kIOPSMaxCapacityKey] as? Int, maximum > 0
            else {
                return .unavailable
            }
            let minutes = values[kIOPSTimeToEmptyKey] as? Int
            return .battery(
                fraction: min(1, max(0, Double(current) / Double(maximum))),
                charging: values[kIOPSIsChargingKey] as? Bool ?? false,
                onACPower: values[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                minutesRemaining: minutes.flatMap { $0 > 0 ? $0 : nil })
        }
        return .notPresent
    }

    private func report(_ probe: String, code: kern_return_t) -> Bool {
        if code == 0 {
            failedProbes.remove(probe)
            return true
        }
        if failedProbes.insert(probe).inserted {
            GSYLog.error(.scan, "system_status probe=\(probe) code=\(code)")
        }
        return false
    }
}

@MainActor
final class SystemStatusStore: ObservableObject {
    @Published private(set) var samples: [SystemStatusSample] = []
    private let sampler = SystemStatusSampler()
    private var revision = UUID()
    var latest: SystemStatusSample? { samples.last }

    func run() async {
        let owner = UUID()
        revision = owner
        samples = []
        await sampler.reset()
        while !Task.isCancelled, revision == owner {
            let sample = await sampler.sample()
            guard !Task.isCancelled, revision == owner else { return }
            samples = Array((samples + [sample]).filter { sample.uptime - $0.uptime <= 60 }.suffix(31))
            do {
                try await Task.sleep(for: .seconds(2))
            } catch { return }  // Cancellation is the lifecycle terminal of this read-only sampler.
        }
    }
}
