import Charts
import SwiftUI

@main
struct DiskChronaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("DiskChrona", id: "main") {
            MainView().environmentObject(Engine.shared)
        }
        .defaultSize(width: 1180, height: 860)
        .defaultLaunchBehavior(.suppressed)   // menu bar only; the menu opens the window
        MenuBarExtra {
            MenuContent().environmentObject(Engine.shared)
        } label: {
            MenuLabel().environmentObject(Engine.shared)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { Engine.shared.start() }
    func applicationWillTerminate(_ notification: Notification) { Engine.shared.shutdown() }
}

struct MenuLabel: View {
    @EnvironmentObject private var engine: Engine
    var body: some View {
        if let image = MenuRateLabel(rate: engine.rate).image {
            Image(nsImage: image).renderingMode(.template)
                .accessibilityLabel("DiskChrona，\(engine.status.summary)，\(signed(engine.rate))/分钟")
        }
    }
}

struct MenuRateLabel: View {
    let rate: Int64

    var body: some View {
        let parts = parts
        VStack(spacing: 0) {
            Text(parts.number).font(.system(size: 9, weight: .bold, design: .monospaced))
            Text(parts.unit + "/m").font(.system(size: 8, weight: .semibold))
        }
        .foregroundStyle(.black)
        .fixedSize()
        .frame(height: 22)
    }

    var image: NSImage? {
        // MenuBarExtra flattens text labels; a template image preserves the compact two-line layout.
        let renderer = ImageRenderer(content: self)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true
        // Tighten the status button's padding without scaling or cropping the text.
        image.alignmentRect = image.alignmentRect.insetBy(dx: 4, dy: 0)
        return image
    }

    private var parts: (number: String, unit: String) {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.allowsNonnumericFormatting = false
        formatter.includesUnit = false
        let number = (rate > 0 ? "+" : "") + formatter.string(fromByteCount: rate)
        formatter.includesUnit = true
        formatter.includesCount = false
        return (number, formatter.string(fromByteCount: rate))
    }
}

struct MenuContent: View {
    @EnvironmentObject private var engine: Engine
    @Environment(\.openWindow) private var openWindow
    @State private var data: Overview?
    @State private var gaps: [DateInterval] = []
    @State private var failed = false
    @State private var lastLoad = Date.distantPast

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("DiskChrona").font(.headline)
                Spacer()
                Text(engine.status.summary).font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(signed(engine.rate)).font(.title2.weight(.semibold)).monospacedDigit()
                Text("/ 分钟").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let free = engine.status.volumeFree {
                    Text("可用 \(bytes(free))").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let data {
                MenuTrend(data: data, gaps: gaps)
                Divider()
                MenuTopFiles(files: data.files)
            } else {
                Text(failed ? "暂时无法读取历史数据" : "正在读取历史数据…")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 180)
            }
            Divider()
            HStack {
                Button("打开主窗口") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Spacer()
                Button(engine.status.paused ? "恢复监控" : "暂停监控") { engine.setPaused(!engine.status.paused) }
                Button("退出") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { engine.menuVisible = true }
        .onDisappear { engine.menuVisible = false }
        .task(id: [AnyHashable(engine.status.revision), engine.ignoreSwap]) {
            let ignoreSwap = engine.ignoreSwap
            let wait = 1 - Date().timeIntervalSince(lastLoad)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            lastLoad = .now
            let iv = TimeRange().interval()
            let result = await engine.read { try $0.overview(iv, ignoreSwap: ignoreSwap) }
            let coverage = await engine.gaps(in: iv, live: engine.status.sessionStart)
            guard !Task.isCancelled else { return }
            data = result
            failed = result == nil
            gaps = coverage
        }
    }
}

struct MenuTopFiles: View {
    let files: [Overview.TopFile]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("净增长最多的文件 · Top 3").font(.caption).foregroundStyle(.secondary)
            if files.isEmpty {
                Text("最近 1 小时没有文件变大").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(files.prefix(3)) { file in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(readable(fileName(file.path))).font(.caption.weight(.medium))
                            if let tag = locationTag(file.path) { TagView(text: tag) }
                        }
                        Text(placeParent(file.path)).font(.caption2).foregroundStyle(.secondary)
                    }
                    .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text(signed(file.net)).font(.caption).monospacedDigit()
                        .foregroundStyle(Palette.series[0]).fixedSize()
                }
                .help(file.path)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MenuBucket {
    let interval: DateInterval
    let growth: Int64
    let release: Int64
    let hasGap: Bool
    var net: Int64 { growth - release }

    init?(data: Overview, date: Date, gaps: [DateInterval]) {
        guard date >= data.interval.start, date < data.interval.end,
              let minute = Calendar.current.dateInterval(of: .minute, for: date) else { return nil }
        interval = minute
        let bars = data.bars.filter { $0.start == minute.start }
        growth = Int64(bars.reduce(0) { $0 + max($1.value, 0) })
        release = Int64(bars.reduce(0) { $0 - min($1.value, 0) })
        hasGap = gaps.contains {
            $0.start < min(minute.end, data.interval.end) && $0.end > max(minute.start, data.interval.start)
        }
    }
}

struct MenuTrend: View {
    let data: Overview
    let gaps: [DateInterval]
    @State var hover: Date?

    private var selection: MenuBucket? { hover.flatMap { MenuBucket(data: data, date: $0, gaps: gaps) } }

    var body: some View {
        let selected = selection
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("最近 1 小时 · 文件变化")
                Spacer()
                Text("净增长 \(signed(data.net))")
            }
            .font(.caption).foregroundStyle(.secondary)
            Chart {
                ForEach(gaps, id: \.start) { gap in
                    RectangleMark(xStart: .value("开始", gap.start), xEnd: .value("结束", gap.end))
                        .foregroundStyle(Palette.gap)
                }
                ForEach(data.bars) { bar in
                    BarMark(x: .value("时间", bar.start, unit: .minute), y: .value("变化", bar.value))
                        .foregroundStyle(bar.value >= 0 ? Palette.series[0] : Palette.series[2])
                        .opacity(selected == nil || bar.start == selected?.interval.start ? 1 : 0.35)
                }
                RuleMark(y: .value("零", 0)).foregroundStyle(Color.secondary.opacity(0.4))
                if let selected {
                    RectangleMark(x: .value("时间", selected.interval.start, unit: .minute))
                        .foregroundStyle(Color.primary.opacity(0.12))
                }
            }
            .chartXScale(domain: data.interval.start...data.interval.end)
            .chartXSelection(value: $hover)
            .onHover { if !$0 { hover = nil } }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisValueLabel(format: .dateTime.hour().minute()) } }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel { if let n = value.as(Double.self) { Text(signed(Int64(n))) } }
                }
            }
            .frame(height: 150)
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    if let selected { tooltip(selected) }
                }
                .alignmentGuide(.top) { $0[.bottom] + 8 }
                .allowsHitTesting(false)
            }
            .overlay {
                if data.bars.isEmpty && selected == nil {
                    Text("暂无文件大小变化").font(.caption).foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }
            HStack(spacing: 12) {
                Label("增长 \(bytes(data.growth))", systemImage: "arrow.up").foregroundStyle(Palette.series[0])
                Label("释放 \(bytes(-data.release))", systemImage: "arrow.down").foregroundStyle(Palette.series[2])
            }
            .font(.caption)
            if !gaps.isEmpty {
                Text("灰色区域为未监控时段").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func tooltip(_ bucket: MenuBucket) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(bucket.interval.start.formatted(date: .omitted, time: .shortened)) – \(bucket.interval.end.formatted(date: .omitted, time: .shortened))")
                    .fontWeight(.semibold)
                Spacer()
                if bucket.hasGap {
                    Text("含未监控时段").foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("增长\n\(bytes(bucket.growth))").foregroundStyle(Palette.series[0])
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("释放\n\(bytes(bucket.release))").foregroundStyle(Palette.series[2])
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("净变化\n\(signed(bucket.net))")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.caption).monospacedDigit()
        .padding(8)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
        .fixedSize(horizontal: false, vertical: true)
    }
}
