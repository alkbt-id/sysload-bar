import Foundation

/// Degrees Celsius; nil when the Mac has no such sensor (e.g. Intel Macs have no "PMU tdie").
struct Temperatures {
    var cpuMax: Double?     // hottest CPU die sensor, shown in the menu bar
    var cpuAvg: Double?
    var ssd: Double?
    var battery: Double?
}

/// Reads Apple Silicon temperature sensors through the IOHIDEventSystem.
/// The API is private, so it is looked up with dlsym: if Apple removes it, temperatures just become nil.
final class Thermal {
    private typealias ClientCreate = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloat = @convention(c) (AnyObject, Int32) -> Double

    private static let temperatureEvent: Int64 = 15                       // kIOHIDEventTypeTemperature
    private static let temperatureField = Int32(temperatureEvent << 16)   // IOHIDEventFieldBase(type)

    private let copyEvent: CopyEvent?
    private let getFloat: GetFloat?
    private var sensors: [(name: String, service: AnyObject)] = []
    private var client: AnyObject?

    init() {
        let lib = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
        func sym<T>(_ name: String) -> T? { dlsym(lib, name).map { unsafeBitCast($0, to: T.self) } }
        copyEvent = sym("IOHIDServiceClientCopyEvent")
        getFloat = sym("IOHIDEventGetFloatValue")
        guard let create: ClientCreate = sym("IOHIDEventSystemClientCreate"),
              let setMatching: SetMatching = sym("IOHIDEventSystemClientSetMatching"),
              let copyServices: CopyServices = sym("IOHIDEventSystemClientCopyServices"),
              let copyProperty: CopyProperty = sym("IOHIDServiceClientCopyProperty"),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { return }
        self.client = client
        // Usage page 0xff00 / usage 5: Apple vendor temperature sensors.
        _ = setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        let services = (copyServices(client)?.takeRetainedValue() as? [AnyObject]) ?? []
        // Each read takes about a millisecond, so only the sensors shown are kept (20 of 46 on an M4 Max are CPU dies).
        sensors = services.compactMap { s in
            (copyProperty(s, "Product" as CFString)?.takeRetainedValue() as? String).map { ($0, s) }
        }.filter { s in Self.shown.contains { s.name.hasPrefix($0) } }
    }

    private static let cpuSensor = "PMU tdie"
    private static let shown = [cpuSensor, "NAND", "gas gauge battery"]

    /// `cpuOnly`: just the CPU dies, for the menu bar while the panel is closed.
    func read(cpuOnly: Bool = false) -> Temperatures {
        guard let copyEvent, let getFloat else { return Temperatures() }
        var cpu: [Double] = [], ssd: [Double] = [], battery: [Double] = []
        for (name, service) in sensors where !cpuOnly || name.hasPrefix(Self.cpuSensor) {
            guard let event = copyEvent(service, Self.temperatureEvent, 0, 0)?.takeRetainedValue() else { continue }
            let t = getFloat(event, Self.temperatureField)
            guard t > 0, t < 150 else { continue }    // disconnected sensors report 0 or garbage
            if name.hasPrefix(Self.cpuSensor) { cpu.append(t) }
            else if name.hasPrefix("NAND") { ssd.append(t) }
            else if name.hasPrefix("gas gauge battery") { battery.append(t) }
        }
        return Temperatures(cpuMax: cpu.max(),
                            cpuAvg: cpu.isEmpty ? nil : cpu.reduce(0, +) / Double(cpu.count),
                            ssd: ssd.max(),
                            battery: battery.max())
    }
}
