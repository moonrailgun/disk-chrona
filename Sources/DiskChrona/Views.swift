import AppKit
import Charts
import ServiceManagement
import SwiftUI

func bytes(_ n: Int64) -> String { n == 0 ? "0" : ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }   // the formatter says "Zero KB"
func signed(_ n: Int64) -> String { n > 0 ? "+" + bytes(n) : n < 0 ? "−" + bytes(-n) : "0" }
func timeText(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .standard) }
func fileName(_ p: String) -> String { (p as NSString).lastPathComponent }

@MainActor func pickFolder(start: String? = nil, message: String = "选择要监控的本地目录") -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.message = message
    panel.directoryURL = start.map { URL(fileURLWithPath: $0) }
    return panel.runModal() == .OK ? panel.url.map { canonical($0.path) } : nil
}

extension Change {
    private var sizeOnly: Bool { kind == .moveIn || kind == .firstSeen }
    var sizeText: String { sizeOnly ? bytes(newSize) : "\(bytes(oldSize)) → \(bytes(newSize))" }
    var allocText: String { sizeOnly ? bytes(newAlloc) : "\(bytes(oldAlloc)) → \(bytes(newAlloc))" }
    var interval: String { "\(timeText(tsPrev)) — \(timeText(ts))" }
    var summary: String {
        switch kind {
        case .added: "新增"
        case .deleted: "删除"
        case .grew, .shrank:
            if newSize == oldSize { "分配空间 \(signed(newAlloc - oldAlloc))" }
            else if kind == .grew { "增长 \(bytes(newSize - oldSize))" }
            else { "缩小 \(bytes(oldSize - newSize))" }
        case .moveIn: "移动自 \(otherPath ?? "?")"
        case .moveOut: "移动至 \(otherPath ?? "?")"
        case .scopeIn: "移入监控范围（范围变化）"
        case .scopeOut: "移出监控范围（范围变化）"
        case .firstSeen: "首次观察（此前大小未知）"
        }
    }
}

enum Span: String, CaseIterable, Identifiable {
    case hour = "最近一小时", today = "今天", week = "最近七天", custom = "自定义"
    var id: Self { self }
}

struct TimeRange: Hashable {
    var span = Span.hour
    var from = Date().addingTimeInterval(-86400)
    var to = Date()

    func interval(_ now: Date = .now) -> DateInterval {
        switch span {
        case .hour: DateInterval(start: now - 3600, end: now)
        case .today: DateInterval(start: Calendar.current.startOfDay(for: now), end: now)
        case .week: DateInterval(start: now - 7 * 86400, end: now)
        case .custom: DateInterval(start: min(from, to), end: max(from, to))
        }
    }
}

@MainActor
final class RangeQuery<Value>: ObservableObject {
    @Published private(set) var value: Value
    @Published private(set) var completedKey: AnyHashable?
    @Published private(set) var failed = false
    private var lastLoad = Date.distantPast

    init(_ value: Value) { self.value = value }

    func isLoading(_ key: AnyHashable) -> Bool { completedKey != key }

    func load(_ key: AnyHashable, throttle: TimeInterval = 0, fetch: () async -> Value?) async {
        // Only background refreshes wait; a new range or directory loads immediately.
        let wait = completedKey == key ? throttle - Date().timeIntervalSince(lastLoad) : 0
        if wait > 0 {
            do { try await Task.sleep(for: .seconds(wait)) } catch { return }
        }
        guard !Task.isCancelled else { return }
        lastLoad = .now
        let result = await fetch()
        guard !Task.isCancelled else { return }
        if let result { value = result }
        failed = result == nil
        completedKey = key
    }
}

struct QueryOverlay: ViewModifier {
    let loading: Bool
    let failed: Bool

    func body(content: Content) -> some View {
        content
            .disabled(loading || failed)
            .accessibilityHidden(loading || failed)
            .overlay {
                if loading || failed {
                    ZStack {
                        Rectangle().fill(.regularMaterial)
                        VStack(spacing: 12) {
                            if loading {
                                ProgressView().controlSize(.large)
                                Text("正在加载数据…")
                            } else {
                                Image(systemName: "exclamationmark.triangle").font(.title2)
                                Text("暂时无法读取数据，请重新选择时间范围")
                            }
                        }
                        .font(.callout)
                        .padding(24)
                        .background(.background, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
    }
}

struct DetailTarget: Identifiable { let path: String; var id: String { path } }

// MARK: - Main window

struct MainView: View {
    @EnvironmentObject private var engine: Engine
    @State private var range = TimeRange()
    @State private var detail: DetailTarget?
    @State private var tab = 0
    @State private var focusDir: String?
    @State private var copyResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HeaderView(range: $range)
            CoverageBanner(range: range)
            TabView(selection: $tab) {
                OverviewView(range: range, openFile: { detail = DetailTarget(path: $0) }, browse: { focusDir = $0; tab = 1 })
                    .tabItem { Text("概览") }.tag(0)
                RankingView(range: range, focus: $focusDir) { detail = DetailTarget(path: $0) }.tabItem { Text("排行") }.tag(1)
                ChangeLogView(range: range) { detail = DetailTarget(path: $0) }.tabItem { Text("原始记录") }.tag(2)
                SettingsView().tabItem { Text("设置") }.tag(3)
            }
        }
        .padding()
        .frame(minWidth: 960, minHeight: 600)
        .sheet(item: $detail) { FileDetailView(path: $0.path) }
        .toolbar {
            Button(copyResult ?? "复制 AI 分析提示词", systemImage: "doc.on.clipboard") {
                do {
                    let prompt = try analysisPrompt(databasePath: engine.databasePath, interval: range.interval(), ignoreSwap: engine.ignoreSwap)
                    NSPasteboard.general.clearContents()
                    copyResult = NSPasteboard.general.setString(prompt, forType: .string) ? "已复制" : "复制失败，请重试"
                } catch { copyResult = "复制失败，请重试" }
            }
            .labelStyle(.titleAndIcon)
            .help("复制后粘贴给本地 AI agent，按当前时间范围和 Swap 设置只读分析磁盘记录。提示词包含本机数据库路径。")
            .task(id: copyResult) {
                guard copyResult != nil else { return }
                do {
                    try await Task.sleep(for: .seconds(3))
                    copyResult = nil
                } catch {}
            }
        }
        // A window that opens on another Space never posts an occlusion change, so read the state directly too.
        .onAppear { DispatchQueue.main.async { engine.windowVisible = mainWindow?.occlusionState.contains(.visible) ?? false } }
        .onDisappear { engine.windowVisible = false }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
            guard let w = note.object as? NSWindow, w == mainWindow else { return }
            engine.windowVisible = w.occlusionState.contains(.visible)
        }
    }
}

private var mainWindow: NSWindow? { NSApp.windows.first { $0.title == "DiskChrona" } }

struct HeaderView: View {
    @EnvironmentObject private var engine: Engine
    @Binding var range: TimeRange

    var body: some View {
        let s = engine.status
        HStack(spacing: 14) {
            Label(s.summary, systemImage: s.symbol).font(.headline).foregroundStyle(s.isHealthy ? .green : .orange)
            Text("监控整个磁盘").foregroundStyle(.secondary)
            if let t = s.confirmedAt { Text("数据更新至 \(t.formatted(date: .omitted, time: .standard))").foregroundStyle(.secondary) }
            Text("卷可用空间 \(s.volumeFree.map(bytes) ?? "不可用")").foregroundStyle(.secondary).help("不含系统可清除空间，可能小于 Finder 显示的数值")
            Spacer()
            if range.span == .custom {
                DatePicker("从", selection: $range.from).labelsHidden()
                Text("至")
                DatePicker("至", selection: $range.to).labelsHidden()
            }
            Picker("时间范围", selection: $range.span) { ForEach(Span.allCases) { Text($0.rawValue).tag($0) } }
                .labelsHidden().fixedSize()
            Button(s.paused ? "恢复监控" : "暂停监控") { engine.setPaused(!s.paused) }
        }
    }
}

struct CoverageBanner: View {
    let range: TimeRange
    @EnvironmentObject private var engine: Engine
    @StateObject private var query = RangeQuery<[DateInterval]>([])

    var body: some View {
        let lines = notes
        VStack(alignment: .leading, spacing: 4) {
            ForEach(lines, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").font(.callout) }
        }
        .padding(lines.isEmpty ? 0 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(lines.isEmpty ? .clear : .orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .task(id: [AnyHashable(range), engine.status.revision, engine.status.sessionStart]) {
            await query.load(range) {
                await engine.gaps(in: range.interval(), live: engine.status.sessionStart)
            }
        }
    }

    private var notes: [String] {
        let s = engine.status
        var out = [s.limited, s.warning].compactMap { $0 }
        let gaps = query.value
        if query.isLoading(range) {
            out.append("正在更新监控覆盖情况…")
        } else if !gaps.isEmpty {
            let total = Duration.seconds(gaps.map(\.duration).reduce(0, +))
            out.append("部分区间：所选范围内有 \(gaps.count) 段未监控（暂停、退出、休眠或开始监控前），共约 \(total.formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)))。其间的变化只能在恢复后按检测时间记录。")
        }
        out += s.roots.compactMap { r in s.states[r.id]?.problem.map { "\(r.path)：\($0)，已有历史保留，不视为删除。" } }
        return out
    }
}

// MARK: - Ranking

struct RankingView: View {
    let range: TimeRange
    @Binding var focus: String?
    let open: (String) -> Void
    @EnvironmentObject private var engine: Engine
    @State private var byDir = false
    @State private var metric = Metric.size
    @State private var sort = RankSort.growth
    @State private var search = ""
    @State private var dir = "/"
    @StateObject private var query = RangeQuery<[RankRow]>([])
    @State private var selection = Set<RankRow.ID>()
    private var rows: [RankRow] { query.value }
    private var queryKey: [AnyHashable] { [range, byDir, dir] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("视图", selection: $byDir) { Text("文件").tag(false); Text("目录").tag(true) }.pickerStyle(.segmented).fixedSize()
                Picker("口径", selection: $metric) { ForEach(Metric.allCases, id: \.self) { Text($0.rawValue) } }.fixedSize()
                Picker("排序", selection: $sort) { ForEach(RankSort.allCases, id: \.self) { Text($0.rawValue) } }.fixedSize()
                Spacer()
                TextField("搜索名称或路径", text: $search).textFieldStyle(.roundedBorder).frame(width: 240)
            }
            if byDir { breadcrumb }
            Table(rows, selection: $selection) {
                TableColumn("名称") { r in
                    HStack(spacing: 6) {
                        Label(r.name, systemImage: r.isDir ? "folder" : "doc").lineLimit(1)
                        if let tag = locationTag(r.path) { TagView(text: tag) }
                    }
                }
                TableColumn("路径") { r in Text(r.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(r.path) }
                TableColumn("净变化") { r in Text(signed(r.net)).monospacedDigit() }.width(100)
                TableColumn("观察到的累计增长") { r in Text(signed(r.growth)).monospacedDigit() }.width(120)
                TableColumn("最近检测") { r in Text(timeText(r.last)) }.width(160)
            }
            .contextMenu(forSelectionType: RankRow.ID.self) { _ in } primaryAction: { ids in
                guard let r = rows.first(where: { ids.contains($0.id) }) else { return }
                if r.isDir { dir = r.path } else { open(r.path) }
            }
            .overlay { if rows.isEmpty { ContentUnavailableView("所选时间段内没有记录到变化", systemImage: "chart.bar") } }
            Text("双击目录逐级展开，双击文件查看详情。累计增长是观察到的正向变化之和，不等于写入字节总量；移动计为目录间转移，不计入全局新增。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(8)
        .modifier(QueryOverlay(loading: query.isLoading(queryKey), failed: query.failed))
        .onChange(of: focus, initial: true) {   // opened from a hotspot on the overview
            guard let f = focus else { return }
            byDir = true
            dir = f
            focus = nil
        }
        .task(id: queryKey + [metric, sort, search, engine.status.revision, engine.ignoreSwap]) {
            let ignoreSwap = engine.ignoreSwap
            await query.load(queryKey) {
                if !search.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
                guard !Task.isCancelled else { return nil }
                let (iv, metric, sort, search, byDir, dir) = (range.interval(), metric, sort, search, byDir, dir)
                return await engine.read { try $0.ranking(iv, metric: metric, sort: sort, search: search, byDir: byDir, dir: dir, ignoreSwap: ignoreSwap) }
            }
        }
    }

    private var breadcrumb: some View {
        let parts = dir.split(separator: "/").reduce(into: [(String, String)]()) { acc, c in
            acc.append((String(c), (acc.last?.1 ?? "") + "/" + c))
        }
        return HStack(spacing: 4) {
            Button("磁盘") { dir = "/" }.buttonStyle(.link)
            ForEach(parts, id: \.1) { name, path in
                Text("›").foregroundStyle(.secondary)
                Button(name) { dir = path }.buttonStyle(.link)
            }
        }
        .font(.callout)
    }
}

// MARK: - Timeline

struct ChangeLogView: View {
    let range: TimeRange
    let open: (String) -> Void
    @EnvironmentObject private var engine: Engine
    @State private var search = ""
    @StateObject private var query = RangeQuery<[Change]>([])
    @State private var selection = Set<Change.ID>()
    private let limit = 2000
    private var rows: [Change] { query.value }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(rows.count >= limit ? "仅显示最近 \(limit) 条" : "共 \(rows.count) 条").foregroundStyle(.secondary)
                Spacer()
                TextField("搜索名称或路径", text: $search).textFieldStyle(.roundedBorder).frame(width: 240)
            }
            Table(rows, selection: $selection) {
                TableColumn("检测时间") { c in Text(timeText(c.ts)).help("观察区间：\(c.interval)") }.width(160)
                TableColumn("文件") { c in
                    VStack(alignment: .leading) {
                        HStack(spacing: 6) {
                            Text(fileName(c.path))
                            if let tag = locationTag(c.path) { TagView(text: tag) }
                        }
                        Text(c.path).font(.caption).foregroundStyle(.secondary).truncationMode(.middle)
                    }
                    .lineLimit(1).help(c.path)
                }
                TableColumn("大小变化") { c in Text(c.sizeText).monospacedDigit() }.width(180)
                TableColumn("分配空间") { c in Text(c.allocText).monospacedDigit().foregroundStyle(.secondary) }.width(180)
                TableColumn("事件") { c in Text(c.summary).lineLimit(1).help(c.summary) }
            }
            .contextMenu(forSelectionType: Change.ID.self) { _ in } primaryAction: { ids in
                if let c = rows.first(where: { ids.contains($0.id) }) { open(c.path) }
            }
            .overlay { if rows.isEmpty { ContentUnavailableView("所选时间段内没有记录到变化", systemImage: "clock") } }
            Text("每分钟汇总落盘一次，同一文件一分钟内的多次变化合并为一条；检测时间是观察到变化的时间，不是写入的准确时间。不预先扫描磁盘：文件第一次被写到时记为「首次观察」，之后记录大小增减；大小不变的写入不记录。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(8)
        .modifier(QueryOverlay(loading: query.isLoading(range), failed: query.failed))
        .task(id: [AnyHashable(range), search, engine.status.revision]) {
            await query.load(range) {
                if !search.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
                guard !Task.isCancelled else { return nil }
                let (iv, search, limit) = (range.interval(), search, limit)
                return await engine.read { try $0.timeline(iv, search: search, limit: limit) }
            }
        }
    }
}

// MARK: - File detail

struct FileDetailView: View {
    let path: String
    @EnvironmentObject private var engine: Engine
    @Environment(\.dismiss) private var dismiss
    @State private var file: FileRow?
    @State private var history: [Change] = []
    @State private var gaps: [DateInterval] = []
    @State private var exists = false

    private struct Point: Identifiable { let id: Int; let t: Date; let v: Double }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(fileName(path)).font(.title2.bold())
                if let tag = locationTag(path) { TagView(text: tag) }
            }
            Text(path).textSelection(.enabled).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow { Text("最近已知大小").foregroundStyle(.secondary); Text(file.map { bytes($0.size) } ?? "不可用") }
                GridRow { Text("分配空间").foregroundStyle(.secondary); Text(file.map { bytes($0.alloc) } ?? "不可用") }
                GridRow { Text("最近观察").foregroundStyle(.secondary); Text(file.map { timeText(Date(timeIntervalSince1970: $0.seenAt)) } ?? "—") }
                GridRow { Text("修改时间（仅供参考）").foregroundStyle(.secondary); Text(file.map { timeText(Date(timeIntervalSince1970: $0.mtime)) } ?? "—") }
                if let f = file, f.nlink > 1 {
                    GridRow { Text("硬链接").foregroundStyle(.secondary); Text("\(f.nlink) 个路径共享同一份数据，汇总中只计一次") }
                }
                GridRow { Text("状态").foregroundStyle(.secondary); Text(exists ? "存在" : "当前不存在或不可访问，历史记录保留") }
            }
            chart.frame(height: 180)
            Table(history.reversed()) {
                TableColumn("检测时间") { c in Text(timeText(c.ts)) }.width(160)
                TableColumn("观察区间") { c in Text(c.interval).foregroundStyle(.secondary) }.width(300)
                TableColumn("大小变化") { c in Text(c.sizeText).monospacedDigit() }.width(170)
                TableColumn("事件") { c in Text(c.summary).lineLimit(1).help(c.summary) }
            }
            HStack {
                if !exists { Text("文件当前不存在，无法在 Finder 中显示。").foregroundStyle(.secondary) }
                Spacer()
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }.disabled(!exists)
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 820, height: 660)
        .task(id: engine.status.revision) {
            let path = path
            exists = FileManager.default.fileExists(atPath: path)
            file = await engine.read { try $0.file(path) } ?? nil
            history = await engine.read { try $0.history(path) } ?? []
            let start = history.first?.tsPrev ?? file.map { Date(timeIntervalSince1970: $0.seenAt) } ?? .now
            gaps = await engine.gaps(in: DateInterval(start: min(start, .now), end: .now), live: engine.status.sessionStart)
        }
    }

    private var points: [Point] {
        var out: [(Date, Int64)] = []
        if let first = history.first, [.grew, .shrank, .deleted].contains(first.kind) { out.append((first.tsPrev, first.oldSize)) }
        out += history.map { ($0.ts, $0.newSize) }
        if let f = file, exists {
            if out.isEmpty { out.append((Date(timeIntervalSince1970: f.seenAt), f.size)) }
            out.append((.now, f.size))
        }
        return out.enumerated().map { Point(id: $0.offset, t: $0.element.0, v: Double($0.element.1)) }
    }

    private var chart: some View {
        Chart {
            ForEach(gaps, id: \.start) { g in
                RectangleMark(xStart: .value("开始", g.start), xEnd: .value("结束", g.end)).foregroundStyle(.gray.opacity(0.2))
            }
            ForEach(points) { p in
                LineMark(x: .value("时间", p.t), y: .value("大小", p.v)).interpolationMethod(.stepEnd)
                PointMark(x: .value("时间", p.t), y: .value("大小", p.v)).symbolSize(20)
            }
        }
        .chartYAxis {
            AxisMarks { v in
                AxisGridLine()
                AxisValueLabel { if let d = v.as(Double.self) { Text(bytes(Int64(d))) } }
            }
        }
        .overlay(alignment: .topTrailing) {
            if !gaps.isEmpty { Text("灰色区域为未监控时段").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject private var engine: Engine
    @AppStorage("retentionDays") private var retention = 30
    @AppStorage("budgetMiB") private var budget = 500
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var confirmClear = false

    var body: some View {
        let s = engine.status
        Form {
            Section("监控范围：整个磁盘") {
                ForEach(s.roots) { RootRow(root: $0) }
                HStack {
                    Text("受保护目录（邮件、信息等）需要授予完整磁盘访问权限，未授权的位置不会显示变化。").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("打开完整磁盘访问权限设置") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                }
            }
            Section("统计") {
                Toggle("忽略虚拟内存交换", isOn: $engine.ignoreSwap)
                Text("概览、排行和菜单栏统计不计入系统交换文件（swapfile）的变化；原始记录仍保留，磁盘可用空间仍显示实际值。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("数据") {
                Stepper("历史保留期限：\(retention) 天", value: $retention, in: 1...30)
                Stepper("容量预算：\(budget) MiB", value: $budget, in: 100...10_000, step: 100)
                LabeledContent("本 App 数据占用（数据库及日志）", value: bytes(s.dataBytes))
                LabeledContent("最早可查询时间", value: s.earliest.map(timeText) ?? "暂无历史")
                Button("清除本 App 历史…", role: .destructive) { confirmClear = true }
            }
            Section("后台") {
                Toggle("登录时启动", isOn: Binding(get: { loginEnabled }, set: setLogin))
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Text("关闭窗口后继续在菜单栏后台监控；退出应用即停止监控，停止期间在历史中显示为缺口。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: retention) { engine.maintainNow() }
        .onChange(of: budget) { engine.maintainNow() }
        .confirmationDialog("清除全部变化历史？", isPresented: $confirmClear) {
            Button("清除历史", role: .destructive) { engine.clearHistory() }
        } message: {
            Text("将删除本 App 记录的全部变化历史与覆盖区间，无法恢复。当前基线、监控设置以及被监控的文件本身都不受影响。")
        }
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "无法更改登录启动：\(error.localizedDescription)（需以 .app 形式运行）"
        }
        loginEnabled = SMAppService.mainApp.status == .enabled
    }
}

struct RootRow: View {
    let root: Root
    @EnvironmentObject private var engine: Engine

    var body: some View {
        let state = engine.status.states[root.id] ?? RootState()
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "internaldrive")
                Text(root.path).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(engine.status.rootStatus(root)).foregroundStyle(.secondary)
            }
            ForEach(root.excludes, id: \.self) { ex in
                HStack {
                    Text("排除：\(ex)").font(.caption)
                    Button { engine.setExcludes(root.id, root.excludes.filter { $0 != ex }) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            Button("添加排除目录（如缓存等高频写入位置）…") {
                if let p = pickFolder(start: root.path, message: "选择要排除的子目录"), p != root.path, isUnder(p, root.path) {
                    engine.setExcludes(root.id, root.excludes + [p])
                }
            }
            .buttonStyle(.link).font(.caption)
            if !state.unreadable.isEmpty {
                DisclosureGroup("因权限无法读取、变化未计入的位置（\(state.unreadable.count)\(state.unreadable.count >= 200 ? "+" : "")）") {
                    ForEach(state.unreadable, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}
