import XCTest
@testable import HoustonCore

final class SystemStatsTests: XCTestCase {
    func testCoreLoadUsesTickDeltasNotAbsoluteCounts() {
        let before: [[UInt64]] = [[100, 50, 850, 0], [10, 10, 980, 0]]
        let after: [[UInt64]] = [[150, 100, 850, 0], [10, 10, 1080, 0]]
        let loads = SystemMath.coreLoads(previous: before, current: after)
        XCTAssertEqual(loads?.map { Int($0.rounded()) }, [100, 0])
        XCTAssertNil(SystemMath.coreLoads(previous: [], current: after), "A first sample has nothing to compare with")
        XCTAssertNil(SystemMath.coreLoads(previous: [before[0]], current: after), "Core counts must match")
        XCTAssertEqual(SystemMath.coreLoads(previous: after, current: after)?.first, 0, "No elapsed ticks is idle, not a crash")
    }

    func testSensorsGroupAppleSiliconKeysAndIgnoreBogusReadings() {
        let readings: [(key: String, value: Double)] = [("Tp01", 70), ("Tp0c", 88), ("Te05", 61), ("Tg0G", 52), ("Tg0V", 61),
            ("TH0x", 40), ("TB0T", 33), ("TW0P", 45), ("Ta01", 0.5), ("Tp99", 4000), ("TVMS", 87)]
        let sensors = SystemMath.sensors(from: readings)
        XCTAssertEqual(sensors.map(\.name), ["CPU", "GPU", "SSD", "Battery"])
        XCTAssertEqual(sensors[0].hottest, 88)
        XCTAssertEqual(sensors[0].count, 3)
        XCTAssertEqual(Int(sensors[0].average.rounded()), 73)
        XCTAssertEqual(sensors[1].hottest, 61)
        XCTAssertEqual(sensors[2].hottest, 40)
        XCTAssertEqual(sensors[3].hottest, 33)
        let intel = SystemMath.sensors(from: [("TC0P", 55), ("TCXC", 61), ("TG0P", 49)])
        XCTAssertEqual(intel.map { ($0.name, $0.hottest) }.map { "\($0.0) \($0.1)" }, ["CPU 61.0", "GPU 49.0"])
        XCTAssertTrue(SystemMath.sensors(from: []).isEmpty)
    }

    func testSMCDecodingCoversAppleSiliconAndIntelTypes() {
        XCTAssertEqual(SystemMath.decodeSMC(type: "flt ", bytes: [0x00, 0x00, 0x20, 0x41]), 10)
        XCTAssertEqual(SystemMath.decodeSMC(type: "sp78", bytes: [0x3a, 0x80]), 58.5)
        XCTAssertEqual(SystemMath.decodeSMC(type: "fpe2", bytes: [0x27, 0x10]), 2500)
        XCTAssertEqual(SystemMath.decodeSMC(type: "ui8 ", bytes: [1]), 1)
        XCTAssertEqual(SystemMath.decodeSMC(type: "ui16", bytes: [0x02, 0xc1]), 705)
        XCTAssertEqual(SystemMath.decodeSMC(type: "ui32", bytes: [0, 0, 0x0a, 0x78]), 2680)
        XCTAssertNil(SystemMath.decodeSMC(type: "flt ", bytes: [1, 2]))
        XCTAssertNil(SystemMath.decodeSMC(type: "ch8*", bytes: [65, 66]))
    }

    func testMemoryUsedMatchesActivityMonitorFormula() {
        XCTAssertEqual(SystemMath.memoryUsed(internalPages: 1000, purgeable: 100, wired: 200, compressed: 50, pageSize: 16384), 1150 * 16384)
        XCTAssertEqual(SystemMath.memoryUsed(internalPages: 10, purgeable: 100, wired: 5, compressed: 0, pageSize: 4096), 5 * 4096, "Purgeable above internal must not underflow")
    }

    func testFormattingIsHumanReadable() {
        XCTAssertEqual(SystemFormat.uptime(59), "0m")
        XCTAssertEqual(SystemFormat.uptime(3 * 3600 + 5 * 60), "3h 5m")
        XCTAssertEqual(SystemFormat.uptime(2 * 86400 + 3600), "2d 1h")
        XCTAssertEqual(SystemFormat.duration(minutes: 141), "2h 21m")
        XCTAssertEqual(SystemFormat.duration(minutes: 9), "9m")
    }

    func testLiveSamplerReturnsPlausibleValuesOnThisMac() async {
        let sampler = SystemSampler()
        let first = await sampler.sample()
        XCTAssertNil(first.cpuLoad, "CPU load needs two samples")
        XCTAssertGreaterThan(first.memoryTotal, 0)
        try? await Task.sleep(for: .milliseconds(300))
        let second = await sampler.sample()
        if let load = second.cpuLoad { XCTAssertTrue((0...100).contains(load)) }
        XCTAssertEqual(second.cores.count, ProcessInfo.processInfo.processorCount)
        XCTAssertLessThanOrEqual(second.memoryUsed, second.memoryTotal)
        for sensor in second.sensors { XCTAssertTrue((1..<130).contains(sensor.hottest), sensor.name) }
        XCTAssertGreaterThan(second.diskTotal, 0)
    }
}
