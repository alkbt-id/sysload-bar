import AppKit
import SwiftUI

enum Palette {
    // Load colors: green while comfortable, yellow from ~70%, red near the top.
    private static let stops: [(Double, (Double, Double, Double))] = [
        (0.0, (0.20, 0.72, 0.33)),
        (0.55, (0.20, 0.72, 0.33)),
        (0.8, (0.96, 0.74, 0.10)),
        (1.0, (0.90, 0.22, 0.20)),
    ]

    // Even steps from green through yellow to red, for amounts where every step matters (Ollama's share of GPU memory).
    private static let gradientStops: [(Double, (Double, Double, Double))] = [
        (0.0, (0.20, 0.72, 0.33)),
        (0.5, (0.96, 0.74, 0.10)),
        (1.0, (0.90, 0.22, 0.20)),
    ]

    static func rgb(_ fraction: Double) -> (Double, Double, Double) { interpolate(fraction, stops) }

    static func gradient(_ fraction: Double) -> NSColor {
        let c = interpolate(fraction, gradientStops)
        return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
    }

    private static func interpolate(_ fraction: Double, _ stops: [(Double, (Double, Double, Double))]) -> (Double, Double, Double) {
        let f = min(max(fraction, 0), 1)
        for i in 1..<stops.count where f <= stops[i].0 {
            let (f0, a) = stops[i - 1], (f1, b) = stops[i]
            let t = (f - f0) / (f1 - f0)
            return (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
        }
        return stops.last!.1
    }

    static func nsColor(_ fraction: Double) -> NSColor {
        let c = rgb(fraction)
        return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
    }

    static func color(_ fraction: Double) -> Color {
        let c = rgb(fraction)
        return Color(.sRGB, red: c.0, green: c.1, blue: c.2)
    }

    /// Menu bar text stays the normal label color until the load gets high, so the bar is calm most of the time.
    static func barColor(_ fraction: Double) -> NSColor {
        fraction < 0.7 ? .labelColor : nsColor(fraction)
    }

    static let user = Color(.sRGB, red: 0.27, green: 0.55, blue: 0.95)
    static let system = Color(.sRGB, red: 0.92, green: 0.35, blue: 0.30)
    static let temperature = Color(.sRGB, red: 0.98, green: 0.70, blue: 0.15)
    static let memory = Color(.sRGB, red: 0.62, green: 0.42, blue: 0.95)
    static let download = Color(.sRGB, red: 0.27, green: 0.55, blue: 0.95)
    static let upload = Color(.sRGB, red: 0.95, green: 0.55, blue: 0.20)
}

enum Fmt {
    static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

    static func degrees(_ t: Double?) -> String { t.map { "\(Int($0.rounded()))°" } ?? "—" }

    /// Temperature as a 0...1 load for coloring: yellow from ~80°, red near 100° (Apple Silicon throttles ~105°).
    static func heat(_ t: Double?) -> Double { (t ?? 0) / 100 }

    /// "1,2", "12", "123": one decimal only below 10.
    private static func number(_ v: Double) -> String {
        v < 9.95 ? String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",") : String(Int(v.rounded()))
    }

    /// Network rate in decimal units: "0 КБ/с", "12 КБ/с", "1,2 МБ/с".
    static func rate(_ bytesPerSecond: Double) -> String {
        let kb = bytesPerSecond / 1000
        if kb < 999.5 { return "\(Int(kb.rounded())) КБ/с" }
        let mb = kb / 1000
        if mb < 999.5 { return "\(number(mb)) МБ/с" }
        return "\(number(mb / 1000)) ГБ/с"
    }

    /// Byte size; memory uses binary units (as Activity Monitor), disk and traffic decimal.
    static func bytes(_ b: UInt64, binary: Bool = false) -> String {
        let base: Double = binary ? 1024 : 1000
        let units = ["Б", "КБ", "МБ", "ГБ", "ТБ"]
        var v = Double(b), i = 0
        while v >= base * 0.9995, i < units.count - 1 { v /= base; i += 1 }
        return i == 0 ? "\(b) Б" : "\(number(v)) \(units[i])"
    }

    /// "45 с", "26 мин", "2 ч 5 мин", "3 д 4 ч".
    static func duration(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d) д \(h) ч" }
        if h > 0 { return "\(h) ч \(m) мин" }
        if m > 0 { return "\(m) мин" }
        return "\(s) с"
    }

    static func uptime(since boot: Date?, now: Date) -> String {
        guard let boot else { return "—" }
        return duration(now.timeIntervalSince(boot))
    }

    /// Response time: "390 мс", "1,2 с".
    static func seconds(_ s: Double) -> String {
        s < 0.9995 ? "\(Int((s * 1000).rounded())) мс" : "\(number(s)) с"
    }

    /// Context size in tokens: 8192 → "8K".
    static func tokens(_ n: Int) -> String {
        n >= 1024 ? "\(Int((Double(n) / 1024).rounded()))K" : "\(n)"
    }

    static func speed(_ tokensPerSecond: Double?) -> String {
        tokensPerSecond.map { "\(number($0)) ток/с" } ?? "—"
    }

    /// Ollama's keep_alive countdown: "ещё 26 мин". A negative keep_alive means "never" and comes as a date centuries ahead.
    static func unload(_ at: Date?, now: Date) -> String {
        guard let at else { return "" }
        let left = at.timeIntervalSince(now)
        if left > 365 * 86400 { return "без выгрузки" }
        return left > 0 ? "ещё \(duration(left))" : "выгружается"
    }
}
