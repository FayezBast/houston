import Foundation
import IOKit
import IOKit.ps

/// One reading of this Mac's load, memory, thermals and power. Missing values mean the source is unavailable, never zero.
public struct SystemSnapshot: Sendable {
    public struct Core: Sendable, Identifiable {
        public let id: Int
        public let load: Double
        public let efficiency: Bool
        public init(id: Int, load: Double, efficiency: Bool) { self.id = id; self.load = load; self.efficiency = efficiency }
    }
    public struct Sensor: Sendable, Identifiable {
        public let name: String
        public let hottest: Double
        public let average: Double
        public let count: Int
        public var id: String { name }
        public init(name: String, hottest: Double, average: Double, count: Int) {
            self.name = name; self.hottest = hottest; self.average = average; self.count = count
        }
    }
    public struct Fan: Sendable, Identifiable {
        public let id: Int
        public let rpm: Double
        public let minimum: Double
        public let maximum: Double
        public init(id: Int, rpm: Double, minimum: Double, maximum: Double) { self.id = id; self.rpm = rpm; self.minimum = minimum; self.maximum = maximum }
    }
    public struct Battery: Sendable {
        public let percent: Int
        public let charging: Bool
        public let external: Bool
        public let minutesRemaining: Int?
        public init(percent: Int, charging: Bool, external: Bool, minutesRemaining: Int?) {
            self.percent = percent; self.charging = charging; self.external = external; self.minutesRemaining = minutesRemaining
        }
    }

    public var chip = ""
    public var model = ""
    public var cpuLoad: Double?
    public var cores: [Core] = []
    public var loadAverage: [Double] = []
    public var gpuLoad: Double?
    public var memoryUsed: UInt64 = 0
    public var memoryTotal: UInt64 = 0
    public var swapUsed: UInt64 = 0
    public var sensors: [Sensor] = []
    public var thermalState = "Nominal"
    public var fans: [Fan] = []
    public var systemPower: Double?
    public var chargerPower: Double?
    public var battery: Battery?
    public var diskUsed: UInt64 = 0
    public var diskTotal: UInt64 = 0
    public var uptime: TimeInterval = 0
    public var capturedAt = Date.now
    public init() {}

    public var cpuTemperature: Double? { sensors.first { $0.name == "CPU" }?.hottest }
    public var memoryFraction: Double { memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) : 0 }
    public var diskFraction: Double { diskTotal > 0 ? Double(diskUsed) / Double(diskTotal) : 0 }
}

public enum SystemFormat {
    public static func memory(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory) }
    public static func disk(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
    public static func uptime(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        if minutes >= 1440 { return "\(minutes / 1440)d \((minutes % 1440) / 60)h" }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
    public static func duration(minutes: Int) -> String { minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m" }
}

/// Pure helpers kept separate from the hardware calls so they can be unit tested.
public enum SystemMath {
    /// Per-core load in percent from two `host_processor_info` tick samples (user, system, idle, nice per core).
    public static func coreLoads(previous: [[UInt64]], current: [[UInt64]]) -> [Double]? {
        guard !previous.isEmpty, previous.count == current.count else { return nil }
        return zip(previous, current).map { before, after in
            guard before.count == 4, after.count == 4 else { return 0 }
            let total = zip(after, before).reduce(0.0) { $0 + Double($1.0 >= $1.1 ? $1.0 - $1.1 : 0) }
            let idle = after[2] >= before[2] ? Double(after[2] - before[2]) : 0
            return total > 0 ? max(0, min(100, 100 * (1 - idle / total))) : 0
        }
    }

    public static let sensorGroups: [(name: String, prefixes: [String])] = [
        ("CPU", ["Tp", "Te"]), ("GPU", ["Tg"]), ("SSD", ["TH"]), ("Battery", ["TB"])
    ]

    /// Groups SMC temperature keys into CPU, GPU, SSD and battery readings. Intel keys (`TC`, `TG`) are used only when the Apple silicon ones are absent.
    public static func sensors(from readings: [(key: String, value: Double)]) -> [SystemSnapshot.Sensor] {
        let valid = readings.filter { $0.value > 1 && $0.value < 130 }
        return sensorGroups.compactMap { group in
            var values = valid.filter { reading in group.prefixes.contains { reading.key.hasPrefix($0) } }.map(\.value)
            if values.isEmpty, let legacy = ["CPU": "TC", "GPU": "TG"][group.name] {
                values = valid.filter { $0.key.hasPrefix(legacy) }.map(\.value)
            }
            guard let hottest = values.max() else { return nil }
            return SystemSnapshot.Sensor(name: group.name, hottest: hottest, average: values.reduce(0, +) / Double(values.count), count: values.count)
        }
    }

    /// Decodes an SMC value from its four-character type code.
    public static func decodeSMC(type: String, bytes: [UInt8]) -> Double? {
        switch type {
        case "flt ": return bytes.count == 4 ? Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }) : nil
        case "sp78": return bytes.count == 2 ? Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256 : nil
        case "fpe2": return bytes.count == 2 ? Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4 : nil
        case "ui8 ": return bytes.first.map(Double.init)
        case "ui16": return bytes.count == 2 ? Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) : nil
        case "ui32": return bytes.count == 4 ? Double(bytes.reduce(0) { $0 << 8 | UInt32($1) }) : nil
        default: return nil
        }
    }

    /// Activity Monitor style "memory used": app memory (internal minus purgeable) plus wired and compressed pages.
    public static func memoryUsed(internalPages: UInt64, purgeable: UInt64, wired: UInt64, compressed: UInt64, pageSize: UInt64) -> UInt64 {
        let app = internalPages >= purgeable ? internalPages - purgeable : 0
        return (app + wired + compressed) * pageSize
    }
}

// MARK: - SMC (fans, power, temperature keys)

private struct SMCVersion { var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0; var reserved: UInt8 = 0; var release: UInt16 = 0 }
private struct SMCPLimitData { var version: UInt16 = 0; var length: UInt16 = 0; var cpuPLimit: UInt32 = 0; var gpuPLimit: UInt32 = 0; var memPLimit: UInt32 = 0 }
private struct SMCKeyInfoData { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0 }
private struct SMCKeyData {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

/// Read-only client for the System Management Controller. Keys are enumerated once so temperature sensors work across chip generations.
private final class SMCClient {
    private var connection: io_connect_t = 0
    private var info: [String: SMCKeyInfoData] = [:]
    private(set) var temperatureKeys: [String] = []

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess, MemoryLayout<SMCKeyData>.size == 80 else { return nil }
        enumerateKeys()
    }

    deinit { if connection != 0 { IOServiceClose(connection) } }

    private static func code(_ text: String) -> UInt32 { text.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
    private static func text(_ code: UInt32) -> String {
        String(bytes: [UInt8(code >> 24 & 0xff), UInt8(code >> 16 & 0xff), UInt8(code >> 8 & 0xff), UInt8(code & 0xff)], encoding: .ascii) ?? "?"
    }

    private func call(_ input: inout SMCKeyData) -> SMCKeyData? {
        var output = SMCKeyData()
        var size = MemoryLayout<SMCKeyData>.stride
        guard IOConnectCallStructMethod(connection, 2, &input, size, &output, &size) == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    private func keyInfo(_ key: UInt32) -> SMCKeyInfoData? {
        var request = SMCKeyData()
        request.key = key
        request.data8 = 9
        return call(&request)?.keyInfo
    }

    private func enumerateKeys() {
        guard let total = read("#KEY"), total > 0, total < 20_000 else { return }
        for index in 0..<UInt32(total) {
            var request = SMCKeyData()
            request.data8 = 8
            request.data32 = index
            guard let response = call(&request) else { continue }
            let key = Self.text(response.key)
            guard key.hasPrefix("T"), let info = keyInfo(response.key), ["flt ", "sp78"].contains(Self.text(info.dataType)) else { continue }
            self.info[key] = info
            temperatureKeys.append(key)
        }
    }

    func read(_ key: String) -> Double? {
        let code = Self.code(key)
        guard let info = info[key] ?? keyInfo(code) else { return nil }
        self.info[key] = info
        var request = SMCKeyData()
        request.key = code
        request.keyInfo = info
        request.data8 = 5
        guard let response = call(&request) else { return nil }
        let bytes = withUnsafeBytes(of: response.bytes) { Array($0.prefix(Int(min(info.dataSize, 32)))) }
        return SystemMath.decodeSMC(type: Self.text(info.dataType), bytes: bytes)
    }
}

// MARK: - Sampler

/// Samples the Mac on demand. CPU load needs two samples; the first call returns `cpuLoad == nil`.
public actor SystemSampler {
    private var previousTicks: [[UInt64]] = []
    private var smc: SMCClient?
    private var smcChecked = false
    private let efficiencyCores: Int
    private let chip: String
    private let model: String
    private let memoryTotal: UInt64

    public init() {
        chip = Self.sysctlString("machdep.cpu.brand_string") ?? "Mac"
        model = Self.sysctlString("hw.model") ?? ""
        memoryTotal = Self.sysctlValue("hw.memsize") ?? 0
        let levels = (0..<4).compactMap { level -> (String, Int)? in
            guard let name = Self.sysctlString("hw.perflevel\(level).name"), let count: UInt64 = Self.sysctlValue("hw.perflevel\(level).logicalcpu") else { return nil }
            return (name, Int(count))
        }
        efficiencyCores = levels.first { $0.0.lowercased().hasPrefix("eff") }?.1 ?? 0
    }

    public func sample() -> SystemSnapshot {
        var snapshot = SystemSnapshot()
        snapshot.chip = chip
        snapshot.model = model
        snapshot.memoryTotal = memoryTotal
        snapshot.uptime = ProcessInfo.processInfo.systemUptime
        snapshot.loadAverage = loadAverage()
        snapshot.thermalState = thermalDescription()
        if let ticks = cpuTicks() {
            if let loads = SystemMath.coreLoads(previous: previousTicks, current: ticks) {
                // The kernel numbers efficiency cores first on Apple silicon.
                snapshot.cores = loads.enumerated().map { SystemSnapshot.Core(id: $0.offset, load: $0.element, efficiency: $0.offset < efficiencyCores) }
                snapshot.cpuLoad = loads.reduce(0, +) / Double(loads.count)
            }
            previousTicks = ticks
        }
        snapshot.gpuLoad = gpuLoad()
        (snapshot.memoryUsed, snapshot.swapUsed) = memory()
        if !smcChecked { smcChecked = true; smc = SMCClient() }
        if let smc {
            snapshot.sensors = SystemMath.sensors(from: smc.temperatureKeys.compactMap { key in smc.read(key).map { (key: key, value: $0) } })
            let fanCount = Int(smc.read("FNum") ?? 0)
            snapshot.fans = (0..<min(fanCount, 8)).compactMap { index in
                guard let rpm = smc.read("F\(index)Ac") else { return nil }
                return SystemSnapshot.Fan(id: index, rpm: rpm, minimum: smc.read("F\(index)Mn") ?? 0, maximum: smc.read("F\(index)Mx") ?? 0)
            }
            snapshot.systemPower = smc.read("PSTR").flatMap { $0 > 0 && $0 < 1000 ? $0 : nil }
            snapshot.chargerPower = smc.read("PDTR").flatMap { $0 > 0.5 && $0 < 1000 ? $0 : nil }
        }
        snapshot.battery = battery()
        (snapshot.diskUsed, snapshot.diskTotal) = disk()
        snapshot.capturedAt = .now
        return snapshot
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sysctlValue(_ name: String) -> UInt64? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0, size <= 8 else { return nil }
        var value: UInt64 = 0
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    private func loadAverage() -> [Double] {
        var values = [Double](repeating: 0, count: 3)
        return getloadavg(&values, 3) == 3 ? values : []
    }

    private func thermalDescription() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }

    private func cpuTicks() -> [[UInt64]]? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS, let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        let states = Int(CPU_STATE_MAX)
        guard Int(infoCount) >= Int(count) * states else { return nil }
        return (0..<Int(count)).map { core in (0..<states).map { UInt64(UInt32(bitPattern: info[core * states + $0])) } }
    }

    private func gpuLoad() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            guard let statistics = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] else { continue }
            if let value = statistics["Device Utilization %"] as? Double ?? statistics["GPU Activity(%)"] as? Double { return max(0, min(100, value)) }
        }
        return nil
    }

    private func memory() -> (used: UInt64, swap: UInt64) {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        var used: UInt64 = 0
        if result == KERN_SUCCESS {
            used = SystemMath.memoryUsed(internalPages: UInt64(statistics.internal_page_count), purgeable: UInt64(statistics.purgeable_count),
                                         wired: UInt64(statistics.wire_count), compressed: UInt64(statistics.compressor_page_count), pageSize: UInt64(getpagesize()))
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let swapUsed = sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 ? swap.xsu_used : 0
        return (used, swapUsed)
    }

    private func battery() -> SystemSnapshot.Battery? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int, let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let external = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let remaining = (charging ? description[kIOPSTimeToFullChargeKey] : description[kIOPSTimeToEmptyKey]) as? Int
            return SystemSnapshot.Battery(percent: Int((Double(current) / Double(maximum) * 100).rounded()), charging: charging, external: external,
                                          minutesRemaining: (remaining ?? -1) > 0 ? remaining : nil)
        }
        return nil
    }

    private func disk() -> (used: UInt64, total: UInt64) {
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacityForImportantUsage, total > 0 else { return (0, 0) }
        return (UInt64(max(0, Int64(total) - available)), UInt64(total))
    }
}
