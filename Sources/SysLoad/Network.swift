import Foundation
import SystemConfiguration

/// Cable and Wi-Fi: each is off, up, or up with the VPN going over it.
struct NetStatus: Equatable {
    enum Link: Equatable { case off, up, vpn }
    var cable = Link.off
    var wifi = Link.off
    var cableName: String?    // the service's name in System Settings → Network: "USB 10/100/1000 LAN"
    var tunnel: String?       // the VPN's interface ("utun5") while the default route goes into one
}

/// Finds which connections are up and which one a VPN goes over. With a cable and Wi-Fi both up the system's
/// service order says which one the Mac prefers, but a VPN keeps going over the one it started on, so the traffic decides.
@MainActor
final class NetLinkMonitor {
    private let store = SCDynamicStoreCreate(nil, "SysLoad" as CFString, nil, nil)
    private var lastBytes: [String: UInt64] = [:]
    /// Recent bytes per interface; each tick keeps 90% of the old sum, so it halves in ~13 s.
    private var traffic: [String: Double] = [:]
    private var current: String?

    /// Per-interface byte counters, every tick.
    func record(_ bytes: [String: UInt64]) {
        for (name, b) in bytes {
            let delta = lastBytes[name].map { b >= $0 ? Double(b - $0) : 0 } ?? 0
            traffic[name] = (traffic[name] ?? 0) * 0.9 + delta
        }
        lastBytes = bytes
    }

    func read() -> NetStatus {
        var out = NetStatus()
        guard let store,
              let all = SCDynamicStoreCopyMultiple(store, ["State:/Network/Global/IPv4", "Setup:/Network/Global/IPv4"] as CFArray,
                                                   ["State:/Network/Service/[^/]+/IPv4", "Setup:/Network/Service/[^/]+(/Interface)?"] as CFArray)
                as? [String: Any] else { return out }
        func dict(_ key: String) -> [String: Any]? { all[key] as? [String: Any] }

        // Services that are up, have a router and sit on a device; VPNs have no device of their own.
        var links: [String: (service: String, wifi: Bool, name: String)] = [:]
        for key in all.keys where key.hasPrefix("State:/Network/Service/") && key.hasSuffix("/IPv4") {
            let id = String(key.dropFirst("State:/Network/Service/".count).dropLast("/IPv4".count))
            guard let state = dict(key), state["Router"] != nil, let device = state["InterfaceName"] as? String,
                  let hw = dict("Setup:/Network/Service/\(id)/Interface"), hw["DeviceName"] as? String == device else { continue }
            links[device] = (id, hw["Hardware"] as? String == "AirPort", dict("Setup:/Network/Service/\(id)")?["UserDefinedName"] as? String ?? device)
        }

        // The Mac's preference: the primary interface, or under a VPN the first service in the order that is up.
        let primary = dict("State:/Network/Global/IPv4")?["PrimaryInterface"] as? String
        let order = dict("Setup:/Network/Global/IPv4")?["ServiceOrder"] as? [String] ?? []
        let preferred = primary.flatMap { links[$0] != nil ? $0 : nil }
            ?? order.lazy.compactMap { id in links.first { $0.value.service == id }?.key }.first
        let busiest = links.keys.max { (traffic[$0] ?? 0) < (traffic[$1] ?? 0) }
        // Stays put while the network is quiet, so the item doesn't flip back and forth.
        var carrier = current.flatMap { links[$0] != nil ? $0 : nil } ?? preferred ?? busiest
        if let b = busiest, let c = carrier, (traffic[b] ?? 0) > 2 * (traffic[c] ?? 0) + 100_000 { carrier = b }
        current = carrier

        // The default route goes into a VPN when its interface isn't one of the devices.
        out.tunnel = primary.flatMap { links[$0] == nil ? $0 : nil }
        for (device, link) in links {
            let state: NetStatus.Link = out.tunnel != nil && device == carrier ? .vpn : .up
            if link.wifi {
                if out.wifi != .vpn { out.wifi = state }
            } else if out.cable != .vpn {
                out.cable = state
                out.cableName = link.name
            }
        }
        return out
    }
}
