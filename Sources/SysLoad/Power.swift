import Foundation
import IOKit

/// Power drawn by the whole Mac, from the SMC key PSTR ("system total"). Needs no root, unlike `powermetrics`.
/// Battery telemetry in the IORegistry has about the same number, but it stays unchanged for tens of seconds.
/// The interface is private: on a Mac without this key the power just becomes nil.
final class PowerMeter {
    /// The driver's SMCParamStruct, 80 bytes. KeyInfo is flattened into it: as a nested struct Swift would place
    /// `result` in that struct's tail padding, where the driver doesn't expect it.
    private struct Message {
        var key: UInt32 = 0
        var version: (UInt8, UInt8, UInt8, UInt8, UInt16) = (0, 0, 0, 0, 0)
        var limits: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
        var size: UInt32 = 0
        var type: UInt32 = 0
        var attributes: UInt32 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var command: UInt8 = 0
        var data: UInt32 = 0
        var bytes: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0, 0, 0, 0)
    }

    private static let handleEvent: UInt32 = 2      // kSMCHandleYPCEvent
    private static let readKey: UInt8 = 5           // kSMCReadKey
    private static let getKeyInfo: UInt8 = 9        // kSMCGetKeyInfo
    private static let key = fourCC("PSTR")
    private static let float = fourCC("flt ")

    private static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    private var connection: io_connect_t = 0
    private var request: Message?                   // nil: no such key on this Mac

    init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        defer { IOObjectRelease(service) }
        guard service != 0, IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS,
              let info = call(Message(key: Self.key, command: Self.getKeyInfo)),
              info.size == 4, info.type == Self.float else { return }
        // Key info doesn't change, so each read is one call instead of two.
        request = Message(key: Self.key, size: info.size, type: info.type, command: Self.readKey)
    }

    deinit { IOServiceClose(connection) }

    func watts() -> Double? {
        guard let request, let reply = call(request) else { return nil }
        let w = Double(Float(bitPattern: reply.bytes.0))
        return (0..<1000).contains(w) ? w : nil     // also rules out NaN
    }

    private func call(_ message: Message) -> Message? {
        var input = message, output = Message()
        var size = MemoryLayout<Message>.stride
        let kr = IOConnectCallStructMethod(connection, Self.handleEvent, &input, size, &output, &size)
        return kr == KERN_SUCCESS && output.result == 0 ? output : nil
    }
}
