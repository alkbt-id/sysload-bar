import Foundation
import SystemConfiguration

/// Cable and Wi-Fi: each is off, up, or up with the VPN or a proxy going over it.
struct NetStatus: Equatable {
    enum Link: Equatable {
        case off, up, vpn, proxy
        /// The VPN or the proxy goes over this link.
        var carries: Bool { self == .vpn || self == .proxy }
    }
    var cable = Link.off
    var wifi = Link.off
    var cableName: String?    // the service's name in System Settings → Network: "USB 10/100/1000 LAN"
    var tunnel: String?       // the VPN's interface ("utun5") while the default route goes into one
    var proxy: String?        // the system proxy that's on: "127.0.0.1:7890", or "PAC" for an auto-config file

    /// Traffic goes through a VPN or a proxy, so the links aren't red.
    var secured: Bool { tunnel != nil || proxy != nil }
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
              let all = SCDynamicStoreCopyMultiple(store, ["State:/Network/Global/IPv4", "Setup:/Network/Global/IPv4", "State:/Network/Global/Proxies"] as CFArray,
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
        out.proxy = Self.proxy(dict("State:/Network/Global/Proxies"))
        // A VPN takes every program's traffic, a proxy only that of programs that use it, so the VPN wins when both are on.
        let carried: NetStatus.Link = out.tunnel != nil ? .vpn : out.proxy != nil ? .proxy : .up
        for (device, link) in links {
            let state = device == carrier ? carried : .up
            if link.wifi {
                if !out.wifi.carries { out.wifi = state }
            } else if !out.cable.carries {
                out.cable = state
                out.cableName = link.name
            }
        }
        return out
    }

    /// The proxy the Mac uses now (its main connection's settings): "127.0.0.1:7890" for HTTPS, HTTP or SOCKS,
    /// "PAC" for an auto-config file, nil when none is on. Proxy apps (Happ, Shadowrocket, Clash) turn it on in
    /// proxy mode instead of sending everything into a tunnel, and turn it off when they disconnect.
    nonisolated static func proxy(_ settings: [String: Any]?) -> String? {
        guard let s = settings else { return nil }
        func on(_ kind: String) -> Bool { (s[kind + "Enable"] as? Int ?? 0) != 0 }
        for kind in ["HTTPS", "HTTP", "SOCKS"] where on(kind) {
            if let host = s[kind + "Proxy"] as? String, !host.isEmpty {
                return host + ((s[kind + "Port"] as? Int).map { ":\($0)" } ?? "")
            }
        }
        if on("ProxyAutoConfig"), let url = s["ProxyAutoConfigURLString"] as? String, !url.isEmpty { return "PAC" }
        return nil
    }
}
