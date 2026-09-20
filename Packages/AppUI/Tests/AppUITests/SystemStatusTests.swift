import Darwin
import XCTest

@testable import AppUI

@MainActor
final class SystemStatusTests: XCTestCase {
    func testNativeSamplerReturnsFiniteReadingsWithoutNetworkRequests() async throws {
        let sampler = SystemStatusSampler()
        let first = await sampler.sample()
        XCTAssertNil(first.cpu)
        XCTAssertNil(first.network)
        // v2026.09.06: XNU rate_limit_host_statistics shares a one-second cache
        // across third-party callers. Use the production two-second cadence, not
        // a 150ms assumption that fails under parallel probes. The finite-value
        // assertion remains mandatory; repeated/no ticks are tested separately.
        // https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/host.c
        try await Task.sleep(for: .seconds(2))
        let second = await sampler.sample()
        let cpu = try XCTUnwrap(second.cpu)
        XCTAssertTrue((0...1).contains(cpu))
        let memory = try XCTUnwrap(second.memory)
        XCTAssertGreaterThan(memory.total, 0)
        XCTAssertLessThanOrEqual(memory.used, memory.total)
        XCTAssertGreaterThanOrEqual(second.uptime, first.uptime)
        if let network = second.network {
            XCTAssertTrue(network.received.isFinite && network.received >= 0)
            XCTAssertTrue(network.sent.isFinite && network.sent >= 0)
        }
    }

    func testCPUUsesAllBusyTicksAndHandlesKernelCounterWrap() {
        let old = SystemCPUTicks(user: .max - 4, system: 100, idle: 100, nice: 100)
        let new = SystemCPUTicks(user: 5, system: 110, idle: 170, nice: 110)
        XCTAssertEqual(new.utilization(since: old), 0.3)
        XCTAssertNil(old.utilization(since: old), "No elapsed ticks means unknown, not 0% CPU.")
    }

    func testNetworkRatesUseOnlyContinuousInterfaces() {
        let previous = [
            "en0": SystemNetworkCounter(received: 100, sent: 50),
            "en1": SystemNetworkCounter(received: 1_000, sent: 900),
        ]
        let current = [
            "en0": SystemNetworkCounter(received: 300, sent: 150),
            "en2": SystemNetworkCounter(received: 999_999, sent: 999_999),
        ]
        XCTAssertEqual(
            SystemNetworkRate.between(previous: previous, current: current, elapsed: 2),
            SystemNetworkRate(received: 100, sent: 50))
    }

    func testNativeInterfaceProjectionPreserves64BitCountersAndExcludesVirtualTraffic() throws {
        func message(index: UInt16, flags: Int32, type: UInt8) -> Data {
            var entry = if_msghdr2()
            entry.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.size)
            entry.ifm_type = UInt8(RTM_IFINFO2)
            entry.ifm_index = index
            entry.ifm_flags = flags
            entry.ifm_data.ifi_type = type
            entry.ifm_data.ifi_ibytes = UInt64(UInt32.max) + 8_000
            entry.ifm_data.ifi_obytes = UInt64(UInt32.max) + 4_000
            return withUnsafeBytes(of: &entry) { Data($0) }
        }
        let physical = message(index: 4, flags: IFF_UP, type: UInt8(IFT_ETHER))
        let loopback = message(index: 1, flags: IFF_UP | IFF_LOOPBACK, type: UInt8(IFT_ETHER))
        let down = message(index: 5, flags: 0, type: UInt8(IFT_ETHER))
        let tunnel = message(index: 6, flags: IFF_UP, type: UInt8(IFT_OTHER))
        let counters = try XCTUnwrap(
            SystemNetworkCounter.parseInterfaceList(physical + loopback + down + tunnel))
        XCTAssertEqual(
            counters,
            [
                "4": SystemNetworkCounter(
                    received: UInt64(UInt32.max) + 8_000, sent: UInt64(UInt32.max) + 4_000)
            ])
        XCTAssertNil(SystemNetworkCounter.parseInterfaceList(physical.dropLast()))
        XCTAssertNil(SystemNetworkCounter.parseInterfaceList(Data([0, 0, 0, 0])))
    }

    func testCounterResetOrInvalidIntervalNeverManufacturesTraffic() {
        let old = ["en0": SystemNetworkCounter(received: 999, sent: 999)]
        let reset = ["en0": SystemNetworkCounter(received: 1, sent: 1)]
        XCTAssertNil(SystemNetworkRate.between(previous: old, current: reset, elapsed: 2))
        for elapsed in [0, -1, Double.nan, .infinity] {
            XCTAssertNil(SystemNetworkRate.between(previous: old, current: old, elapsed: elapsed))
        }
        XCTAssertEqual(
            SystemNetworkRate.between(previous: old, current: old, elapsed: 2),
            SystemNetworkRate(received: 0, sent: 0))
    }

    func testBatteryAbsenceIsDifferentFromUnsupportedReading() {
        XCTAssertNotEqual(SystemBatterySnapshot.notPresent, .unavailable)
        XCTAssertNil(SystemBatterySnapshot.notPresent.fraction)
        XCTAssertEqual(
            SystemBatterySnapshot.battery(
                fraction: 0.72, charging: false,
                onACPower: false, minutesRemaining: nil
            ).fraction, 0.72)
    }
}
