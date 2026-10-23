import SwiftUI
import Charts
import AppKit
import UniformTypeIdentifiers

struct PopoverView: View {
    @EnvironmentObject var model: AppModel
    /// Room for every section; on a smaller screen the panel is shorter and scrolls.
    static let fullHeight: CGFloat = 1100
    var height = min(fullHeight, (NSScreen.main?.visibleFrame.height ?? fullHeight) - 20)

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    rings
                    Divider()
                    CPUSection()
                    Divider()
                    if model.ollama != nil || Ollama.isInstalled {
                        OllamaSection()
                        Divider()
                    }
                    MemorySection()
                    Divider()
                    NetworkSection()
                    Divider()
                    ProcessesSection()
                }
                .padding(16)
            }
            Divider()
            Footer().padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 380, height: height)
    }

    private var rings: some View {
        HStack(spacing: 0) {
            Ring(title: "ЦП", value: model.cpu.total)
            Ring(title: "Темп.", value: model.temps.cpuMax.map { Fmt.heat($0) }, text: Fmt.degrees(model.temps.cpuMax))
                .help("Самый горячий датчик кристалла процессора")
            Ring(title: "Память", value: model.memory.fraction)
            Ring(title: "GPU", value: model.gpu?.utilization)
                .help(model.gpu.map { "Память GPU: \(Fmt.bytes($0.memoryUsed, binary: true)) из \(Fmt.bytes($0.memoryAllocated, binary: true))" } ?? "")
            Ring(title: "Диск", value: model.disk?.fraction)
                .help(model.disk.map { "Свободно \(Fmt.bytes(UInt64($0.free))) из \(Fmt.bytes(UInt64($0.total)))" } ?? "")
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Building blocks

private struct Ring: View {
    let title: String
    let value: Double?
    var text: String?

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.18), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: min(max(value ?? 0, 0.005), 1))
                    .stroke(Palette.color(value ?? 0), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: value)
                Text(text ?? value.map(Fmt.percent) ?? "—")
                    .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
            }
            .frame(width: 58, height: 58)
            Text(title).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct Header: View {
    let title: String
    var trailing: String = ""
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            Spacer()
            Text(trailing).font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

/// "key ........ value" row with an optional color swatch matching the chart.
private struct KV: View {
    let key: String
    let value: String
    var swatch: Color?
    var valueColor: Color?

    var body: some View {
        HStack(spacing: 6) {
            if let swatch { RoundedRectangle(cornerRadius: 2).fill(swatch).frame(width: 8, height: 8) }
            Text(key).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(value).monospacedDigit().foregroundStyle(valueColor ?? .primary)
        }
        .font(.callout)
    }
}

private struct Columns<L: View, R: View>: View {
    @ViewBuilder let left: L
    @ViewBuilder let right: R
    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(spacing: 4) { left }.frame(maxWidth: .infinity)
            VStack(spacing: 4) { right }.frame(maxWidth: .infinity)
        }
    }
}

/// Time axis for all charts: the last `historyLength` samples, newest at the right edge.
@MainActor private func timeDomain(_ model: AppModel) -> ClosedRange<Date> {
    let end = model.history.last?.t ?? model.now
    return end.addingTimeInterval(-AppModel.interval * Double(AppModel.historyLength - 1))...end
}

// MARK: - CPU

private struct CPUSection: View {
    @EnvironmentObject var model: AppModel

    private struct Point: Identifiable {
        let t: Date, v: Double, kind: String
        var id: String { kind + "\(t.timeIntervalSince1970)" }
    }

    var body: some View {
        let points = model.history.flatMap {
            [Point(t: $0.t, v: $0.cpuSystem * 100, kind: "система"), Point(t: $0.t, v: $0.cpuUser * 100, kind: "пользователь")]
        }
        VStack(alignment: .leading, spacing: 8) {
            Header(title: "Процессор", trailing: "\(Sampler.chipName) · \(ProcessInfo.processInfo.activeProcessorCount) ядер")
            Chart {
                ForEach(points) { p in
                    AreaMark(x: .value("Время", p.t), y: .value("%", p.v), stacking: .standard)
                        .foregroundStyle(by: .value("Тип", p.kind))
                        .interpolationMethod(.monotone)
                }
                // Temperature in °C shares the 0...100 axis with load in %.
                ForEach(model.history.filter { $0.cpuTemp != nil }) { s in
                    LineMark(x: .value("Время", s.t), y: .value("°C", s.cpuTemp!), series: .value("Ряд", "темп"))
                        .foregroundStyle(Palette.temperature)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                        .interpolationMethod(.monotone)
                }
            }
            .chartForegroundStyleScale(["система": Palette.system, "пользователь": Palette.user])
            .chartLegend(.hidden)
            .chartXAxis(.hidden)
            .chartXScale(domain: timeDomain(model))
            .chartYScale(domain: 0...100)
            .chartYAxis { AxisMarks(position: .trailing, values: [0, 50, 100]) { v in AxisGridLine(); AxisValueLabel("\(v.as(Int.self) ?? 0)%") } }
            .frame(height: 64)
            Columns {
                KV(key: "Пользователь", value: Fmt.percent(model.cpu.user), swatch: Palette.user)
                KV(key: "Система", value: Fmt.percent(model.cpu.system), swatch: Palette.system)
                KV(key: "Простой", value: Fmt.percent(model.cpu.idle), swatch: .secondary.opacity(0.4))
            } right: {
                KV(key: "Нагрузка 1 мин", value: String(format: "%.2f", model.load[0]))
                KV(key: "5 мин", value: String(format: "%.2f", model.load[1]))
                KV(key: "15 мин", value: String(format: "%.2f", model.load[2]))
            }
            Columns {
                KV(key: "Темп. макс", value: Fmt.degrees(model.temps.cpuMax), swatch: Palette.temperature, valueColor: Palette.color(Fmt.heat(model.temps.cpuMax)))
                KV(key: "Темп. средн.", value: Fmt.degrees(model.temps.cpuAvg))
            } right: {
                KV(key: "SSD", value: Fmt.degrees(model.temps.ssd))
                KV(key: "Батарея", value: Fmt.degrees(model.temps.battery))
            }
        }
    }
}

// MARK: - Memory

private struct MemorySection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let m = model.memory
        VStack(alignment: .leading, spacing: 8) {
            Header(title: "Память", trailing: "\(Fmt.bytes(m.used, binary: true)) из \(Fmt.bytes(m.total, binary: true))")
            Chart(model.history) { s in
                AreaMark(x: .value("Время", s.t), y: .value("%", s.memory * 100))
                    .foregroundStyle(Palette.memory.opacity(0.6))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Время", s.t), y: .value("%", s.memory * 100))
                    .foregroundStyle(Palette.memory)
                    .interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden)
            .chartXScale(domain: timeDomain(model))
            .chartYScale(domain: 0...100)
            .chartYAxis { AxisMarks(position: .trailing, values: [0, 50, 100]) { v in AxisGridLine(); AxisValueLabel("\(v.as(Int.self) ?? 0)%") } }
            .frame(height: 56)
            Columns {
                KV(key: "Приложения", value: Fmt.bytes(m.app, binary: true))
                KV(key: "Связанная", value: Fmt.bytes(m.wired, binary: true))
                KV(key: "Сжатая", value: Fmt.bytes(m.compressed, binary: true))
            } right: {
                KV(key: "Кэш", value: Fmt.bytes(m.cached, binary: true))
                KV(key: "Своп", value: Fmt.bytes(m.swapUsed, binary: true))
                KV(key: "Давление", value: pressure.0, valueColor: pressure.1)
            }
        }
    }

    private var pressure: (String, Color) {
        switch model.memory.pressure {
        case 4: return ("критическое", Palette.color(1))
        case 2: return ("повышенное", Palette.color(0.8))
        default: return ("норма", Palette.color(0))
        }
    }
}

// MARK: - Network

private struct NetworkSection: View {
    @EnvironmentObject var model: AppModel

    private struct Point: Identifiable {
        let t: Date, v: Double, kind: String
        var id: String { kind + "\(t.timeIntervalSince1970)" }
    }

    var body: some View {
        // Download above the axis, upload mirrored below it.
        let points = model.history.flatMap {
            [Point(t: $0.t, v: $0.rx, kind: "входящий"), Point(t: $0.t, v: -$0.tx, kind: "исходящий")]
        }
        let peak = max(model.history.map { max($0.rx, $0.tx) }.max() ?? 0, 10_000)
        VStack(alignment: .leading, spacing: 8) {
            Header(title: "Сеть", trailing: model.interface.map { [$0.name, $0.ip].compactMap { $0 }.joined(separator: " · ") } ?? "нет подключения")
            Chart(points) { p in
                AreaMark(x: .value("Время", p.t), y: .value("Б/с", p.v), stacking: .unstacked)
                    .foregroundStyle(by: .value("Направление", p.kind))
                    .interpolationMethod(.monotone)
            }
            .chartForegroundStyleScale(["входящий": Palette.download, "исходящий": Palette.upload])
            .chartLegend(.hidden)
            .chartXAxis(.hidden)
            .chartXScale(domain: timeDomain(model))
            .chartYScale(domain: -peak...peak)
            .chartYAxis {
                AxisMarks(position: .trailing, values: [-peak, 0, peak]) { v in
                    AxisGridLine()
                    AxisValueLabel { if let d = v.as(Double.self), d != 0 { Text(Fmt.rate(abs(d))) } }
                }
            }
            .frame(height: 72)
            Columns {
                KV(key: "↓ Входящий", value: Fmt.rate(model.net.rx), swatch: Palette.download)
                KV(key: "↑ Исходящий", value: Fmt.rate(model.net.tx), swatch: Palette.upload)
            } right: {
                KV(key: "↓ С загрузки", value: Fmt.bytes(model.netTotals.rx))
                KV(key: "↑ С загрузки", value: Fmt.bytes(model.netTotals.tx))
            }
        }
    }
}

// MARK: - Ollama

private struct OllamaSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Header(title: "Ollama", trailing: model.ollama.map { $0.version.isEmpty ? "" : "v\($0.version)" } ?? "не запущена")
            if let o = model.ollama {
                if o.loaded.isEmpty {
                    Text("Ни одна модель не загружена в память").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(o.loaded) { ModelRow(m: $0, now: model.now) }
                let disk = KV(key: "На диске", value: "\(o.installed) · \(Fmt.bytes(o.installedSize))")
                    .help("Скачанных моделей: \(o.installed), занимают \(Fmt.bytes(o.installedSize))")
                if let a = o.activity {
                    Columns {
                        KV(key: "Запросов за 5 мин", value: "\(a.requests)")
                        KV(key: "Последний", value: a.lastRequest.map { Fmt.duration(model.now.timeIntervalSince($0)) + " назад" } ?? "—")
                        KV(key: "Время ответа", value: a.latency.map(Fmt.seconds) ?? "—")
                            .help("Среднее за 5 минут; у потоковых ответов — вместе со всей генерацией")
                    } right: {
                        KV(key: "Генерация", value: Fmt.speed(a.generation))
                        KV(key: "Промпт", value: Fmt.speed(a.prompt))
                            .help("Скорость чтения промпта")
                        disk
                    }
                } else {
                    disk
                }
            }
        }
    }
}

private struct ModelRow: View {
    let m: OllamaModel
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(m.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(Fmt.bytes(m.size, binary: true)).monospacedDigit()
            }
            .font(.callout)
            HStack(spacing: 8) {
                Text(details).lineLimit(1)
                Spacer(minLength: 8)
                Text(Fmt.unload(m.expiresAt, now: now)).monospacedDigit()
                    .help("Ollama выгрузит модель из памяти, если до этого не придёт запрос")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var details: String {
        // Like the PROCESSOR column of `ollama ps`.
        let processor = m.gpuShare > 0.995 ? "GPU" : m.gpuShare < 0.005 ? "ЦП" : "GPU \(Fmt.percent(m.gpuShare))"
        return [m.parameters, m.quantization, m.context.map { "контекст \(Fmt.tokens($0))" }, processor]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// MARK: - Processes

private struct ProcessesSection: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("processSort") private var sort = Sort.cpu

    enum Sort: String, CaseIterable, Identifiable {
        case cpu, memory
        var id: String { rawValue }
        var title: String { self == .cpu ? "ЦП" : "Память" }
    }

    var body: some View {
        let top = model.processes
            .sorted { sort == .cpu ? $0.cpu > $1.cpu : $0.memory > $1.memory }
            .prefix(6)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Процессы").font(.headline)
                Spacer()
                Picker("", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) } label: {
                    Image(systemName: "waveform.path.ecg.rectangle")
                }
                .buttonStyle(.borderless)
                .help("Открыть Мониторинг системы")
            }
            if top.isEmpty {
                Text("Собираю список…").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(top)) { p in
                HStack(spacing: 8) {
                    Image(nsImage: Icons.icon(for: p.id)).resizable().frame(width: 18, height: 18)
                    Text(p.name).lineLimit(1).truncationMode(.middle)
                        .help(p.count > 1 ? "\(p.name): \(p.count) процессов" : p.name)
                    Spacer(minLength: 8)
                    Text(sort == .cpu ? String(format: "%.1f%%", p.cpu) : Fmt.bytes(p.memory, binary: true))
                        .monospacedDigit()
                        .foregroundStyle(sort == .cpu ? Palette.color(p.cpu / Double(ProcessInfo.processInfo.activeProcessorCount * 100) * 4) : .primary)
                }
                .font(.callout)
            }
        }
    }
}

@MainActor
enum Icons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for path: String) -> NSImage {
        if let i = cache[path] { return i }
        // Apps get their own icon; bare executables (and kernel_task, which has no file) a terminal one.
        let i = path.hasSuffix(".app") ? NSWorkspace.shared.icon(forFile: path) : NSWorkspace.shared.icon(for: .unixExecutable)
        cache[path] = i
        return i
    }
}

// MARK: - Footer

private struct Footer: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack {
            Toggle("Запускать при входе", isOn: $model.launchAtLogin)
                .toggleStyle(.checkbox)
            Spacer()
            Text("работает \(Fmt.uptime(since: model.bootTime, now: model.now))")
                .font(.caption).foregroundStyle(.secondary)
                .help("Время с момента загрузки macOS")
            Button("Выход") { NSApp.terminate(nil) }
        }
    }
}
