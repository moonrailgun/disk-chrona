import AppKit
import Charts
import ServiceManagement
import SwiftUI

func bytes(_ n: Int64) -> String { n == 0 ? "0" : ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }   // the formatter says "Zero KB"
func signed(_ n: Int64) -> String { n > 0 ? "+" + bytes(n) : n < 0 ? "−" + bytes(-n) : "0" }
func timeText(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .standard) }
func fileName(_ p: String) -> String { (p as NSString).lastPathComponent }

@MainActor func pickFolder(start: String? = nil, message: String = "Choose a local folder to monitor") -> String? {
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
        case .added: "Added"
        case .deleted: "Deleted"
        case .grew, .shrank:
            if newSize == oldSize { "Allocated \(signed(newAlloc - oldAlloc))" }
            else if kind == .grew { "Grew \(bytes(newSize - oldSize))" }
            else { "Shrank \(bytes(oldSize - newSize))" }
        case .moveIn: "Moved from \(otherPath ?? "?")"
        case .moveOut: "Moved to \(otherPath ?? "?")"
        case .scopeIn: "Entered monitored scope (scope change)"
        case .scopeOut: "Left monitored scope (scope change)"
        case .firstSeen: "First seen (previous size unknown)"
        }
    }
}

enum Span: String, CaseIterable, Identifiable {
    case hour = "Last hour", today = "Today", week = "Last 7 days", custom = "Custom"
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
                                Text("Loading data…")
                            } else {
                                Image(systemName: "exclamationmark.triangle").font(.title2)
                                Text("Couldn't read data. Try choosing the time range again.")
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
                    .tabItem { Text("Overview") }.tag(0)
                RankingView(range: range, focus: $focusDir) { detail = DetailTarget(path: $0) }.tabItem { Text("Ranking") }.tag(1)
                ChangeLogView(range: range) { detail = DetailTarget(path: $0) }.tabItem { Text("Raw Log") }.tag(2)
                SettingsView().tabItem { Text("Settings") }.tag(3)
            }
        }
        .padding()
        .frame(minWidth: 960, minHeight: 600)
        .sheet(item: $detail) { FileDetailView(path: $0.path) }
        .toolbar {
            Button(copyResult ?? "Copy AI Analysis Prompt", systemImage: "doc.on.clipboard") {
                do {
                    let prompt = try analysisPrompt(databasePath: engine.databasePath, interval: range.interval(), ignoreSwap: engine.ignoreSwap)
                    NSPasteboard.general.clearContents()
                    copyResult = NSPasteboard.general.setString(prompt, forType: .string) ? "Copied" : "Copy failed, try again"
                } catch { copyResult = "Copy failed, try again" }
            }
            .labelStyle(.titleAndIcon)
            .help("Paste into a local AI agent to analyze the disk records read-only, using the current time range and swap setting. The prompt includes this Mac's database path.")
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
            Text("Monitoring entire disk").foregroundStyle(.secondary)
            if let t = s.confirmedAt { Text("Data through \(t.formatted(date: .omitted, time: .standard))").foregroundStyle(.secondary) }
            Text("Volume free space: \(s.volumeFree.map(bytes) ?? "unavailable")").foregroundStyle(.secondary).help("Excludes purgeable space, so it may be lower than Finder shows")
            Spacer()
            if range.span == .custom {
                DatePicker("From", selection: $range.from).labelsHidden()
                Text("to")
                DatePicker("to", selection: $range.to).labelsHidden()
            }
            Picker("Time range", selection: $range.span) { ForEach(Span.allCases) { Text($0.rawValue).tag($0) } }
                .labelsHidden().fixedSize()
            Button(s.paused ? "Resume Monitoring" : "Pause Monitoring") { engine.setPaused(!s.paused) }
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
            out.append("Updating monitoring coverage…")
        } else if !gaps.isEmpty {
            let total = Duration.seconds(gaps.map(\.duration).reduce(0, +))
            out.append("Partial coverage: the selected range has \(gaps.count) unmonitored periods (paused, quit, asleep, or before monitoring started), about \(total.formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))) in total. Changes during them can only be recorded when detected after monitoring resumes.")
        }
        out += s.roots.compactMap { r in s.states[r.id]?.problem.map { "\(r.path): \($0). Existing history is kept and not treated as deleted." } }
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
                Picker("View", selection: $byDir) { Text("Files").tag(false); Text("Folders").tag(true) }.pickerStyle(.segmented).fixedSize()
                Picker("Measure", selection: $metric) { ForEach(Metric.allCases, id: \.self) { Text($0.rawValue) } }.fixedSize()
                Picker("Sort", selection: $sort) { ForEach(RankSort.allCases, id: \.self) { Text($0.rawValue) } }.fixedSize()
                Spacer()
                TextField("Search name or path", text: $search).textFieldStyle(.roundedBorder).frame(width: 240)
            }
            if byDir { breadcrumb }
            Table(rows, selection: $selection) {
                TableColumn("Name") { r in
                    HStack(spacing: 6) {
                        Label(r.name, systemImage: r.isDir ? "folder" : "doc").lineLimit(1)
                        if let tag = locationTag(r.path) { TagView(text: tag) }
                    }
                }
                TableColumn("Path") { r in Text(r.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(r.path) }
                TableColumn("Net change") { r in Text(signed(r.net)).monospacedDigit() }.width(100)
                TableColumn("Observed total growth") { r in Text(signed(r.growth)).monospacedDigit() }.width(120)
                TableColumn("Last detected") { r in Text(timeText(r.last)) }.width(160)
            }
            .contextMenu(forSelectionType: RankRow.ID.self) { _ in } primaryAction: { ids in
                guard let r = rows.first(where: { ids.contains($0.id) }) else { return }
                if r.isDir { dir = r.path } else { open(r.path) }
            }
            .overlay { if rows.isEmpty { ContentUnavailableView("No changes recorded in the selected period", systemImage: "chart.bar") } }
            Text("Double-click a folder to drill down, or a file to see its details. Total growth is the sum of observed increases, not the total bytes written; moves count as transfers between folders, not as new growth overall.")
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
            Button("Disk") { dir = "/" }.buttonStyle(.link)
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
                Text(rows.count >= limit ? "Showing the latest \(limit) only" : "\(rows.count) records").foregroundStyle(.secondary)
                Spacer()
                TextField("Search name or path", text: $search).textFieldStyle(.roundedBorder).frame(width: 240)
            }
            Table(rows, selection: $selection) {
                TableColumn("Detected") { c in Text(timeText(c.ts)).help("Observed interval: \(c.interval)") }.width(160)
                TableColumn("File") { c in
                    VStack(alignment: .leading) {
                        HStack(spacing: 6) {
                            Text(fileName(c.path))
                            if let tag = locationTag(c.path) { TagView(text: tag) }
                        }
                        Text(c.path).font(.caption).foregroundStyle(.secondary).truncationMode(.middle)
                    }
                    .lineLimit(1).help(c.path)
                }
                TableColumn("Size change") { c in Text(c.sizeText).monospacedDigit() }.width(180)
                TableColumn("Allocated space") { c in Text(c.allocText).monospacedDigit().foregroundStyle(.secondary) }.width(180)
                TableColumn("Event") { c in Text(c.summary).lineLimit(1).help(c.summary) }
            }
            .contextMenu(forSelectionType: Change.ID.self) { _ in } primaryAction: { ids in
                if let c = rows.first(where: { ids.contains($0.id) }) { open(c.path) }
            }
            .overlay { if rows.isEmpty { ContentUnavailableView("No changes recorded in the selected period", systemImage: "clock") } }
            Text("Changes are saved once a minute, and multiple changes to the same file within a minute are merged into one record. The detected time is when a change was observed, not the exact write time. The disk is not scanned up front: a file is recorded as \"first seen\" the first time it is written, and size increases and decreases are recorded after that; writes that don't change the size are not recorded.")
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
                GridRow { Text("Last known size").foregroundStyle(.secondary); Text(file.map { bytes($0.size) } ?? "Unavailable") }
                GridRow { Text("Allocated space").foregroundStyle(.secondary); Text(file.map { bytes($0.alloc) } ?? "Unavailable") }
                GridRow { Text("Last seen").foregroundStyle(.secondary); Text(file.map { timeText(Date(timeIntervalSince1970: $0.seenAt)) } ?? "—") }
                GridRow { Text("Modified (for reference only)").foregroundStyle(.secondary); Text(file.map { timeText(Date(timeIntervalSince1970: $0.mtime)) } ?? "—") }
                if let f = file, f.nlink > 1 {
                    GridRow { Text("Hard links").foregroundStyle(.secondary); Text("\(f.nlink) paths share the same data; counted once in totals") }
                }
                GridRow { Text("Status").foregroundStyle(.secondary); Text(exists ? "Exists" : "Missing or inaccessible right now; history is kept") }
            }
            chart.frame(height: 180)
            Table(history.reversed()) {
                TableColumn("Detected") { c in Text(timeText(c.ts)) }.width(160)
                TableColumn("Observed interval") { c in Text(c.interval).foregroundStyle(.secondary) }.width(300)
                TableColumn("Size change") { c in Text(c.sizeText).monospacedDigit() }.width(170)
                TableColumn("Event") { c in Text(c.summary).lineLimit(1).help(c.summary) }
            }
            HStack {
                if !exists { Text("The file doesn't exist right now, so it can't be shown in Finder.").foregroundStyle(.secondary) }
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }.disabled(!exists)
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
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
                RectangleMark(xStart: .value("Start", g.start), xEnd: .value("End", g.end)).foregroundStyle(.gray.opacity(0.2))
            }
            ForEach(points) { p in
                LineMark(x: .value("Time", p.t), y: .value("Size", p.v)).interpolationMethod(.stepEnd)
                PointMark(x: .value("Time", p.t), y: .value("Size", p.v)).symbolSize(20)
            }
        }
        .chartYAxis {
            AxisMarks { v in
                AxisGridLine()
                AxisValueLabel { if let d = v.as(Double.self) { Text(bytes(Int64(d))) } }
            }
        }
        .overlay(alignment: .topTrailing) {
            if !gaps.isEmpty { Text("Gray areas are unmonitored periods").font(.caption).foregroundStyle(.secondary) }
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
            Section("Monitored scope: entire disk") {
                ForEach(s.roots) { RootRow(root: $0) }
                HStack {
                    Text("Protected folders (Mail, Messages, etc.) need Full Disk Access; changes in locations without access are not shown.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Full Disk Access Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                }
            }
            Section("Statistics") {
                Toggle("Ignore swap", isOn: $engine.ignoreSwap)
                Text("Overview, Ranking, and menu bar stats leave out changes to system swap files (swapfile). The raw log still keeps them, and free disk space still shows the actual value.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Data") {
                Stepper("Keep history for \(retention) days", value: $retention, in: 1...30)
                Stepper("Size budget: \(budget) MiB", value: $budget, in: 100...10_000, step: 100)
                LabeledContent("App data usage (database and logs)", value: bytes(s.dataBytes))
                LabeledContent("Earliest available", value: s.earliest.map(timeText) ?? "No history yet")
                Button("Clear App History…", role: .destructive) { confirmClear = true }
            }
            Section("Background") {
                Toggle("Launch at login", isOn: Binding(get: { loginEnabled }, set: setLogin))
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Text("Monitoring continues from the menu bar after the window is closed. Quitting the app stops monitoring, and the stopped period shows as a gap in history.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: retention) { engine.maintainNow() }
        .onChange(of: budget) { engine.maintainNow() }
        .confirmationDialog("Clear all change history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { engine.clearHistory() }
        } message: {
            Text("This deletes all change history and coverage periods recorded by the app, and can't be undone. The current baseline, monitoring settings, and the monitored files themselves are not affected.")
        }
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't change launch at login: \(error.localizedDescription) (the app must run as a .app bundle)"
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
                    Text("Excluded: \(ex)").font(.caption)
                    Button { engine.setExcludes(root.id, root.excludes.filter { $0 != ex }) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            Button("Add Excluded Folder (e.g. caches and other high-churn locations)…") {
                if let p = pickFolder(start: root.path, message: "Choose a subfolder to exclude"), p != root.path, isUnder(p, root.path) {
                    engine.setExcludes(root.id, root.excludes + [p])
                }
            }
            .buttonStyle(.link).font(.caption)
            if !state.unreadable.isEmpty {
                DisclosureGroup("Unreadable locations, changes not counted (\(state.unreadable.count)\(state.unreadable.count >= 200 ? "+" : ""))") {
                    ForEach(state.unreadable, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}
