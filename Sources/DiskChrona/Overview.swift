import AppKit
import Charts
import SwiftUI

// MARK: - Palette (dataviz reference palette; validated for CVD in light and dark)

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        })
    }
}

enum Palette {
    /// Fixed order; assigned by hotspot rank and never cycled (more than five places fold into "Other locations").
    static let series = [
        Color(light: 0x2a78d6, dark: 0x3987e5), Color(light: 0xeb6834, dark: 0xd95926), Color(light: 0x1baf7a, dark: 0x199e70),
        Color(light: 0xeda100, dark: 0xc98500), Color(light: 0xe87ba4, dark: 0xd55181),
    ]
    static let other = Color(light: 0x898781, dark: 0x898781)
    static let release = Color(light: 0xc3c2b7, dark: 0x4a4945)
    static let gap = Color.gray.opacity(0.14)
}

// MARK: - Places

func displayPath(_ p: String) -> String {
    let home = NSHomeDirectory()
    return isUnder(p, home) ? "~" + p.dropFirst(home.count) : p
}

/// The last two components, enough to recognize a place in a sentence.
func shortPath(_ p: String) -> String {
    let parts = displayPath(p).split(separator: "/", omittingEmptySubsequences: false)
    return parts.count > 3 ? "…/" + parts.suffix(2).joined(separator: "/") : displayPath(p)
}

func placeName(_ p: String) -> String { p == "/" ? "Entire disk" : fileName(p) }

/// Where a path sits, as "owner › rest": "Dao › extensions_crx_cache", "kindle-dashboard › …/kolinux/lib".
func placeParent(_ p: String) -> String { context(of: (p as NSString).deletingLastPathComponent) }

/// Folders whose next component names an owner (an app, a project, a volume). Most specific first.
private let ownerPatterns: [[String]] = [
    "~/Library/Application Support/*", "~/Library/Caches/*", "~/Library/Containers/*", "~/Library/Group Containers/*",
    "~/Library/Logs/*", "~/Library/Developer/*", "~/Library/*", "/Library/Application Support/*", "/Library/Caches/*",
    "/Library/Logs/*", "/Library/*", "/private/var/folders/*/*/*/*", "/private/var/db/*", "/private/var/log/*", "/private/var/*",
    "/private/tmp/*", "/Volumes/*", "/Applications/*", "/System/*", "~/*/*",
].map { $0.split(separator: "/", omittingEmptySubsequences: false).map(String.init) }

/// The directory that says who or what a path belongs to, in display form ("~/Library/Application Support/Dao").
func owner(ofDir dir: String) -> String {
    let parts = displayPath(dir).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    for pat in ownerPatterns where parts.count >= pat.count - 1 {
        let n = min(pat.count, parts.count)
        if zip(parts.prefix(n), pat.prefix(n)).allSatisfy({ $1 == "*" || $0 == $1 }) { return parts.prefix(n).joined(separator: "/") }
    }
    return displayPath(dir)
}

func realPath(_ display: String) -> String { display.hasPrefix("~") ? NSHomeDirectory() + display.dropFirst() : display }

/// Undo URL-encoding that some apps use for folder names; an embedded path is quoted so it does not read as nesting.
func readable(_ name: String) -> String {
    guard name.contains("%"), let decoded = name.removingPercentEncoding else { return name }
    return decoded.contains("/") ? "“" + displayPath(decoded).replacingOccurrences(of: NSHomeDirectory(), with: "~") + "”" : decoded
}

func ownerName(_ own: String) -> String {
    if own == "~" { return "Home" }
    if own == "/" || own.isEmpty { return "Disk" }
    if own.hasPrefix("/private/var/folders/") && own.split(separator: "/").count <= 6 { return "System temp folder" }
    let parent = fileName((own as NSString).deletingLastPathComponent)
    // A tool's hidden folder names the owner better than its subfolder: ".claude/projects", not "projects".
    return parent.hasPrefix(".") ? parent + "/" + readable(fileName(own)) : readable(fileName(own))
}

func context(of dir: String) -> String {
    let own = owner(ofDir: dir)
    let rest = displayPath(dir).split(separator: "/", omittingEmptySubsequences: false)
        .dropFirst(own.split(separator: "/", omittingEmptySubsequences: false).count).map { readable(String($0)) }
    guard !rest.isEmpty else { return ownerName(own) }
    return ownerName(own) + " › " + (rest.count > 2 ? "…/" + rest.suffix(2).joined(separator: "/") : rest.joined(separator: "/"))
}

/// Display names that tell places apart: colliding names get one more parent component, up to four.
func distinctNames(_ paths: [String]) -> [String: String] {
    var depth = Dictionary(uniqueKeysWithValues: paths.map { ($0, 1) })
    func name(_ p: String) -> String { p == "/" ? placeName(p) : p.split(separator: "/").suffix(depth[p]!).joined(separator: "/") }
    for _ in 0..<3 {
        let clashes = Dictionary(grouping: paths, by: name).values.filter { $0.count > 1 }.joined()
        if clashes.isEmpty { break }
        for p in clashes { depth[p]! += 1 }
    }
    return Dictionary(uniqueKeysWithValues: paths.map { ($0, name($0)) })
}

/// A hint from well-known directory names. It describes the place; it never claims which app wrote there.
func locationTag(_ p: String) -> String? {
    let path = normalizedSystemPath(p)
    if let vm = ["/System/Volumes/VM", "/private/var/vm"].first(where: { isUnder(path, $0) }) {
        if (path as NSString).deletingLastPathComponent == vm {
            let name = fileName(path)
            if name == "sleepimage" { return "Sleep image" }
            if isSwapFile(path) { return "Swap" }
        }
        return "Virtual memory"
    }
    var volumePath = path
    let parts = path.split(separator: "/")
    if parts.first == "Volumes", parts.count >= 2 { volumePath = "/" + parts.dropFirst(2).joined(separator: "/") }
    if isUnder(volumePath, "/.Spotlight-V100") { return "Search index" }
    if isUnder(volumePath, "/.fseventsd") { return "FSEvents log" }
    let systemRules = [
        ("/private/var/db/diagnostics", "System logs"), ("/private/var/db/uuidtext", "System logs"),
        ("/Library/Logs/DiagnosticReports", "Diagnostic reports"),
        (NSHomeDirectory() + "/Library/Logs/DiagnosticReports", "Diagnostic reports"),
        ("/Library/Updates", "System updates"),
    ]
    if let rule = systemRules.first(where: { isUnder(path, $0.0) }) { return rule.1 }
    let d = displayPath(path) + "/"
    let rules: [(String, String)] = [
        ("~/.Trash/", "Trash"), ("~/Downloads/", "Downloads"), ("/Caches/", "Caches"), ("/private/var/folders/", "Temp files"),
        ("/private/tmp/", "Temp files"), ("/private/var/db/", "System data"), ("/Logs/", "Logs"), ("/private/var/log/", "Logs"), ("/DerivedData/", "Build output"),
        ("/node_modules/", "Dependencies"), ("/.build/", "Build output"), ("/CoreSimulator/", "Simulator"), ("/.git/", "Git"),
        ("~/Library/Containers/", "App data"), ("~/Library/Group Containers/", "App data"), ("~/Library/Application Support/", "App data"),
        ("~/Movies/", "Media"), ("~/Pictures/", "Media"), ("~/Music/", "Media"), ("~/Documents/", "Documents"), ("~/Desktop/", "Desktop"),
        ("/Applications/", "Applications"),
    ]
    return rules.first { $0.0.hasPrefix("~") ? d.hasPrefix($0.0) : d.contains($0.0) }?.1
}

struct Hotspot: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let net: Int64
    let files: Int
    /// The directory's own growth, without subdirectories that are listed separately.
    let rest: Bool
}

/// Where growth concentrates: directories holding at least 4% of all growth, each reported without the growth of
/// more specific listed subdirectories, so the values never overlap and add up with "Other locations" to the total.
func hotspots(_ perFile: [String: Int64], limit: Int = 5) -> (spots: [Hotspot], total: Int64) {
    var dirs: [String: (net: Int64, files: Int)] = [:]
    var total: Int64 = 0
    for (p, n) in perFile where n > 0 {
        total += n
        var d = p
        repeat {
            d = (d as NSString).deletingLastPathComponent
            dirs[d, default: (0, 0)].net += n
            dirs[d]!.files += 1
        } while d != "/" && !d.isEmpty
    }
    guard total > 0 else { return ([], 0) }
    let threshold = max(total / 25, 1)
    let cands = dirs.filter { $0.value.net >= threshold }.map(\.key)
    var spots: [Hotspot] = []
    for c in cands where c != "/" {
        let below = cands.filter { $0 != c && isUnder($0, c) }
        let nearest = below.filter { d in !below.contains { $0 != d && isUnder(d, $0) } }
        let net = dirs[c]!.net - nearest.reduce(0) { $0 + dirs[$1]!.net }
        let files = dirs[c]!.files - nearest.reduce(0) { $0 + dirs[$1]!.files }
        if net >= threshold { spots.append(Hotspot(path: c, net: net, files: files, rest: !nearest.isEmpty)) }
    }
    return (Array(spots.sorted { $0.net > $1.net }.prefix(limit)), total)
}

// MARK: - Data

struct Overview {
    static let otherKey = "Other locations", releaseKey = "Freed"

    struct Bar: Identifiable { let id: Int; let start: Date; let series: String; let value: Double }
    struct TopFile: Identifiable { var id: String { path }; let path: String; let net: Int64; let size: Int64? }
    struct FreePoint: Identifiable { var id: Date { t }; let t: Date; let free: Double }

    var interval = DateInterval()
    var unit = Calendar.Component.minute
    var net: Int64 = 0, growth: Int64 = 0, release: Int64 = 0
    var active = 0, added = 0, deleted = 0
    var spots: [Hotspot] = []
    var total: Int64 = 0
    var bars: [Bar] = []
    var files: [TopFile] = []
    var free: [FreePoint] = []
    var freeDelta: Int64?
    var freeSince: Date?
    /// Samples span (nearly) the whole range, so the change in free space is comparable with file growth.
    var freeCovers = false
    /// Net growth on this Mac's own volume; other volumes do not change its free space.
    var localNet: Int64 = 0
    var names: [String: String] = [:]

    var other: Int64 { total - spots.reduce(0) { $0 + $1.net } }

    func freePoint(near date: Date) -> FreePoint? {
        free.min { abs($0.t.timeIntervalSince(date)) < abs($1.t.timeIntervalSince(date)) }
    }

    /// Series present in the chart, in fixed order: hotspots by rank, then other, then release.
    var keys: [String] {
        let present = Set(bars.map(\.series))
        return spots.map(\.path) + [Overview.otherKey, Overview.releaseKey].filter(present.contains)
    }

    func color(_ key: String) -> Color {
        if let i = spots.firstIndex(where: { $0.path == key }) { return Palette.series[i] }
        return key == Overview.releaseKey ? Palette.release : Palette.other
    }
}

/// Recent writes grouped by owner (an app's folder, a project), so a dozen `output.log`s read as one place.
struct Live {
    struct Group: Identifiable {
        var id: String { owner }
        let owner: String   // real path
        var net: Int64 = 0, growth: Int64 = 0, files = 0
        var latest = "", last = Date.distantPast
    }
    var rate: Int64 = 0
    var groups: [Group] = []
    var more = 0
}

extension DB {
    /// Moves are transfers inside the disk, so they are left out: this is about where space went.
    func overview(_ iv: DateInterval, ignoreSwap: Bool = false) throws -> Overview {
        var o = Overview()
        o.interval = iv
        o.unit = iv.duration <= 3 * 3600 ? .minute : iv.duration <= 8 * 86400 ? .hour : .day
        let size: Double = o.unit == .minute ? 60 : o.unit == .hour ? 3600 : 86400
        let tz = Double(TimeZone.current.secondsFromGMT(for: iv.end))   // buckets align to local hours and days
        let args: [Any?] = [tz, size, iv.start.timeIntervalSince1970, iv.end.timeIntervalSince1970]

        struct Cell { let path: String; let b: Int64; let net, growth, release: Int64; let added, deleted: Bool }
        let cells = try rows("""
            SELECT path, CAST((ts + ?) / ? AS INTEGER), SUM(new_size - old_size), SUM(MAX(new_size - old_size, 0)),
                   SUM(MIN(new_size - old_size, 0)), MAX(kind = 0), MAX(kind = 3)
            FROM changes WHERE ts >= ? AND ts <= ? AND kind NOT IN (4, 5) \(ignoreSwap ? "AND NOT is_swap(path)" : "") GROUP BY 1, 2
            """, args) { r in
            Cell(path: r.string(0) ?? "", b: r.int(1), net: r.int(2), growth: r.int(3), release: r.int(4), added: r.int(5) != 0, deleted: r.int(6) != 0)
        }
        var perFile: [String: Int64] = [:]
        var added = Set<String>(), deleted = Set<String>()
        for c in cells {
            perFile[c.path, default: 0] += c.net
            o.growth += c.growth
            o.release += c.release
            if c.added { added.insert(c.path) }
            if c.deleted { deleted.insert(c.path) }
        }
        o.net = o.growth + o.release
        (o.active, o.added, o.deleted) = (perFile.count, added.count, deleted.count)
        (o.spots, o.total) = hotspots(perFile)
        o.names = distinctNames(o.spots.map(\.path))
        o.localNet = perFile.reduce(0) { $1.key.hasPrefix("/Volumes/") ? $0 : $0 + $1.value }

        let deepestFirst = o.spots.sorted { $0.path.count > $1.path.count }
        var sums: [String: [Int64: Int64]] = [:]
        for c in cells {
            if c.growth > 0 {
                let key = deepestFirst.first { isUnder(c.path, $0.path) }?.path ?? Overview.otherKey
                sums[key, default: [:]][c.b, default: 0] += c.growth
            }
            if c.release < 0 { sums[Overview.releaseKey, default: [:]][c.b, default: 0] += c.release }
        }
        for key in o.spots.map(\.path) + [Overview.otherKey, Overview.releaseKey] {   // stacking follows legend order
            for (b, v) in (sums[key] ?? [:]).sorted(by: { $0.key < $1.key }) {
                o.bars.append(.init(id: o.bars.count, start: Date(timeIntervalSince1970: Double(b) * size - tz), series: key, value: Double(v)))
            }
        }

        o.files = perFile.filter { $0.value > 0 }.sorted { $0.value > $1.value }.prefix(6).map {
            Overview.TopFile(path: $0.key, net: $0.value, size: try? file($0.key)?.size)
        }
        o.free = try rows("SELECT CAST((ts + ?) / ? AS INTEGER) AS b, AVG(free) FROM volume WHERE ts >= ? AND ts <= ? GROUP BY b ORDER BY b", args) { r in
            Overview.FreePoint(t: Date(timeIntervalSince1970: Double(r.int(0)) * size - tz), free: r.double(1))
        }
        let sample = "SELECT ts, free FROM volume WHERE ts >= ? AND ts <= ? ORDER BY ts"
        let first = try rows(sample + " LIMIT 1", [iv.start.timeIntervalSince1970, iv.end.timeIntervalSince1970]) { ($0.double(0), $0.int(1)) }.first
        let last = try rows(sample.replacingOccurrences(of: "ORDER BY ts", with: "ORDER BY ts DESC") + " LIMIT 1",
                            [iv.start.timeIntervalSince1970, iv.end.timeIntervalSince1970]) { ($0.double(0), $0.int(1)) }.first
        if let first, let last, last.0 - first.0 >= 60 {   // one sample says nothing about change
            o.freeDelta = last.1 - first.1
            o.freeSince = Date(timeIntervalSince1970: first.0)
            o.freeCovers = first.0 - iv.start.timeIntervalSince1970 <= max(120, iv.duration * 0.05)
        }
        return o
    }

    func live(_ now: Date, ignoreSwap: Bool = false) throws -> Live {
        let t = now.timeIntervalSince1970
        let filter = ignoreSwap ? " AND NOT is_swap(path)" : ""
        var l = Live()
        var groups: [String: Live.Group] = [:]
        _ = try rows("""
            SELECT path, SUM(new_size - old_size), SUM(MAX(new_size - old_size, 0)), MAX(ts) FROM changes
            WHERE ts >= ? AND kind NOT IN (4, 5)\(filter) GROUP BY path ORDER BY MAX(ts) DESC LIMIT 2000
            """, [t - 120]) { r in
            let path = r.string(0) ?? ""
            let own = realPath(owner(ofDir: (path as NSString).deletingLastPathComponent))
            var g = groups[own] ?? Live.Group(owner: own)
            g.net += r.int(1)
            g.growth += r.int(2)
            g.files += 1
            if r.date(3) > g.last { (g.last, g.latest) = (r.date(3), path) }
            groups[own] = g
        }
        let sorted = groups.values.sorted { ($0.growth, $0.last) > ($1.growth, $1.last) }
        l.groups = Array(sorted.prefix(6))
        l.more = max(0, sorted.count - 6)
        l.rate = Int64(try double("SELECT SUM(MAX(new_size - old_size, 0)) FROM changes WHERE ts >= ? AND kind NOT IN (4, 5)\(filter)", [t - 60]) ?? 0)
        return l
    }
}

// MARK: - View

struct FreeSpaceChart: View {
    let data: Overview
    let gaps: [DateInterval]
    @State var hover: Date?

    var body: some View {
        let domain = data.interval.start...max(data.interval.end, data.interval.start + 60)
        let selected = hover.flatMap { data.freePoint(near: $0) }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Volume free space")
                Spacer(minLength: 8)
                if let selected {
                    Text("\(selected.t.formatted(.dateTime.month().day().hour().minute())) · avg \(bytes(Int64(selected.free)))")
                        .foregroundStyle(.primary).monospacedDigit()
                }
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Chart {
                ForEach(gaps, id: \.start) { g in
                    RectangleMark(xStart: .value("Start", max(g.start, domain.lowerBound)), xEnd: .value("End", min(g.end, domain.upperBound)))
                        .foregroundStyle(Palette.gap)
                }
                ForEach(data.free) { p in
                    LineMark(x: .value("Time", p.t), y: .value("Free space", p.free))
                        .foregroundStyle(Palette.series[0]).lineStyle(StrokeStyle(lineWidth: 2))
                }
                if let selected {
                    RuleMark(x: .value("Time", selected.t))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    PointMark(x: .value("Time", selected.t), y: .value("Free space", selected.free))
                        .foregroundStyle(Palette.series[0]).symbolSize(40)
                }
            }
            .chartXScale(domain: domain)
            .chartXSelection(value: $hover)
            .onHover { if !$0 { hover = nil } }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(bytes(Int64(d))) } } } }
            .frame(height: 74)
            .overlay {
                if data.free.count < 2 && selected == nil {
                    Text("Sampled once a minute; the trend appears shortly").font(.caption).foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

struct OverviewView: View {
    let range: TimeRange
    let openFile: (String) -> Void
    let browse: (String) -> Void
    @EnvironmentObject private var engine: Engine
    @StateObject private var query = RangeQuery((data: Overview(), live: Live(), gaps: [DateInterval]()))
    @State private var hover: Date?
    private var data: Overview { query.value.data }
    private var live: Live { query.value.live }
    private var gaps: [DateInterval] { query.value.gaps }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(headline).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    StatTile(label: "Volume free space", value: engine.status.volumeFree.map(bytes) ?? "Unavailable",
                             caption: data.freeDelta.map { "\(signed($0)) in selected range" } ?? "Not enough samples to compare yet")
                        .help("Excludes purgeable space, so it may be lower than Finder shows")
                    StatTile(label: "Net file growth", value: signed(data.net), caption: "Grew \(bytes(data.growth)) · Freed \(bytes(-data.release))")
                    StatTile(label: "Current write rate", value: "\(bytes(live.rate))/min", caption: "Growth observed in the last minute")
                    StatTile(label: "Active files", value: data.active.formatted(), caption: "\(data.added) added · \(data.deleted) deleted")
                }
                // The hotspot list sits beside the chart: it is the chart's legend and its table view.
                HStack(alignment: .top, spacing: 12) {
                    Card(title: "Space changes", note: range.span.rawValue) { trend }
                    Card(title: "Where it grew", note: "Click to browse") { spotList }.frame(width: 340)
                }
                .zIndex(1)
                HStack(alignment: .top, spacing: 12) {
                    Card(title: "Being written", note: "Last 2 minutes · by location") { liveList }
                    Card(title: "Top growing files", note: "Click for history") { fileList }
                }
            }
            .padding(8)
        }
        .modifier(QueryOverlay(loading: query.isLoading(range), failed: query.failed))
        .task(id: [AnyHashable(range), engine.status.revision, engine.ignoreSwap]) {
            let ignoreSwap = engine.ignoreSwap
            await query.load(range, throttle: range.span == .hour ? 1 : 5) {
                let now = Date()
                let iv = range.interval(now)
                let sessionStart = engine.status.sessionStart
                return await engine.read { db in
                    var sessions = try db.sessions(iv)
                    if let sessionStart { sessions.append(DateInterval(start: sessionStart, end: .distantFuture)) }
                    return (try db.overview(iv, ignoreSwap: ignoreSwap), try db.live(now, ignoreSwap: ignoreSwap), coverageGaps(iv, sessions))
                }
            }
        }
    }

    private var headline: String {
        var s = (range.span == .custom ? "In the selected period" : range.span.rawValue) + ", "
        if let d = data.freeDelta {
            let since = data.freeCovers ? "" : " since \(data.freeSince!.formatted(date: .omitted, time: .shortened))"
            s += "free space" + since + (d < 0 ? " dropped by \(bytes(-d)); " : d > 0 ? " grew by \(bytes(d)); " : " barely changed; ")
        }
        guard data.net != 0 else { return s + "no net file size change was observed." }
        if data.net < 0 { return s + "files shrank by \(bytes(-data.net)) net." }
        s += "files grew by \(bytes(data.net)) net"
        // Only compare like with like: the same time span, and growth on the volume whose free space we sample.
        if data.freeCovers, let d = data.freeDelta, d < 0, data.localNet > 0, data.localNet * 100 / -d < 100 {
            let share = data.localNet * 100 / -d
            s += " (growth on this volume accounts for about \(share)% of the drop" + (share < 50 ? "; the rest may come from snapshots, the system, or locations without access)" : ")")
        }
        if let top = data.spots.first {
            let share = top.net * 100 / max(data.total, 1)
            s += share >= 50 ? ", mostly in \(shortPath(top.path)) (\(signed(top.net)))"
                : ", spread out; the largest is \(shortPath(top.path)) (\(signed(top.net)), \(share)%)"
        }
        return s + "."
    }

    private var domain: ClosedRange<Date> { data.interval.start...max(data.interval.end, data.interval.start + 60) }

    private var hoverBucket: Date? { hover.flatMap { Calendar.current.dateInterval(of: data.unit, for: $0)?.start } }

    private var trend: some View {
        VStack(alignment: .leading, spacing: 6) {
            FreeSpaceChart(data: data, gaps: gaps)

            Text("File size changes: growth is stacked by location, freed space is drawn below zero").font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            Chart {
                ForEach(gaps, id: \.start) { g in
                    RectangleMark(xStart: .value("Start", max(g.start, domain.lowerBound)), xEnd: .value("End", min(g.end, domain.upperBound)))
                        .foregroundStyle(Palette.gap)
                }
                if let b = hoverBucket {
                    RectangleMark(x: .value("Time", b, unit: data.unit)).foregroundStyle(Color.primary.opacity(0.06))
                        .annotation(position: .top, spacing: 6, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            tooltip(b)
                        }
                }
                ForEach(data.bars) { bar in
                    BarMark(x: .value("Time", bar.start, unit: data.unit), y: .value("Change", bar.value))
                        .foregroundStyle(by: .value("Location", bar.series))
                        .cornerRadius(2)
                }
                RuleMark(y: .value("Zero", 0)).foregroundStyle(Color.secondary.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1))
            }
            .chartForegroundStyleScale(domain: data.keys, range: data.keys.map(data.color))
            .chartLegend(.hidden)
            .chartXScale(domain: domain)
            .chartXSelection(value: $hover)
            .onHover { if !$0 { hover = nil } }
            .chartYAxis { AxisMarks(values: .automatic(desiredCount: 4)) { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(signed(Int64(d))) } } } }
            .frame(height: 180)
            .overlay {
                if data.bars.isEmpty && hoverBucket == nil {
                    Text("No file size changes observed in the selected range").font(.callout).foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }
            .zIndex(1)

            if !data.keys.isEmpty {
                HStack(spacing: 14) {
                    ForEach(data.keys, id: \.self) { key in
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 2).fill(data.color(key)).frame(width: 9, height: 9)
                            Text(data.names[key] ?? key).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            if !gaps.isEmpty {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(Palette.gap).frame(width: 9, height: 9)
                    Text("Gray areas are unmonitored periods; changes during them can't be pinned to a specific time").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func tooltip(_ b: Date) -> some View {
        let inBucket = data.bars.filter { $0.start == b }
        let grew = inBucket.filter { $0.value > 0 }.reduce(0) { $0 + $1.value }
        let freed = inBucket.filter { $0.value < 0 }.reduce(0) { $0 + $1.value }
        let end = Calendar.current.date(byAdding: data.unit, value: 1, to: b) ?? b
        let hasGap = gaps.contains { $0.start < min(end, data.interval.end) && $0.end > max(b, data.interval.start) }
        let label = switch data.unit {
        case .minute: b.formatted(date: .omitted, time: .shortened)
        case .hour: b.formatted(.dateTime.month().day().hour())
        default: b.formatted(date: .abbreviated, time: .omitted)
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text(label).fontWeight(.semibold)
            if !inBucket.isEmpty || !hasGap {
                HStack(spacing: 12) {
                    Text("Grew \(bytes(Int64(grew)))")
                    Text("Freed \(bytes(Int64(-freed)))")
                }
                Text("Net change \(signed(Int64(grew + freed)))").foregroundStyle(.secondary)
            }
            if !inBucket.isEmpty {
                Divider()
                ForEach(inBucket) { bar in
                    HStack(alignment: .top, spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(data.color(bar.series)).frame(width: 9, height: 9).padding(.top, 2)
                        Text(displayPath(bar.series))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(signed(Int64(bar.value))).fixedSize()
                    }
                }
            } else {
                Text(hasGap ? "No records for this period, so changes can't be confirmed" : "No file size changes observed in this period")
                    .foregroundStyle(.secondary)
            }
            if hasGap {
                Text("Includes unmonitored time; changes are recorded when detected after monitoring resumed")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption).monospacedDigit()
        .padding(10)
        .frame(width: 320, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(.background, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
    }

    private var liveList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if live.groups.isEmpty {
                Text("No writes observed in the last 2 minutes").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
            }
            ForEach(live.groups) { g in
                Button { browse(g.owner) } label: {
                    HStack(spacing: 8) {
                        Circle().fill(Date().timeIntervalSince(g.last) < 15 ? Palette.series[0] : Color.clear)
                            .overlay(Circle().strokeBorder(Palette.series[0], lineWidth: 1))
                            .frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(ownerName(displayPath(g.owner))).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                                if let tag = locationTag(g.owner) { TagView(text: tag) }
                            }
                            Text("\(g.files) files · latest \(readable(fileName(g.latest)))").font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(g.growth > 0 ? "+" + bytes(g.growth) : g.net < 0 ? signed(g.net) : "Size unchanged").font(.callout.weight(.medium))
                                .foregroundStyle(g.growth > 0 ? .primary : .secondary)
                            Text(g.last.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(g.owner)\nLatest write: \(g.latest)")
            }
            if live.more > 0 {
                Text("\(live.more) more locations with writes").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            }
        }
    }

    private var spotList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if data.spots.isEmpty {
                Text("No growth observed in the selected range").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 100)
            }
            ForEach(Array(data.spots.enumerated()), id: \.element.id) { i, spot in
                Button { browse(spot.path) } label: {
                    PlaceRow(color: Palette.series[i], title: readable(placeName(spot.path)) + (spot.rest ? " (rest)" : ""),
                             subtitle: placeParent(spot.path), tag: locationTag(spot.path),
                             share: Double(spot.net) / Double(max(data.total, 1)),
                             value: signed(spot.net), detail: "\(spot.files) files")
                }
                .buttonStyle(.plain)
                .help(spot.rest ? "The part of \(spot.path) not listed separately" : spot.path)
            }
            if data.other > 0 && !data.spots.isEmpty {
                PlaceRow(color: Palette.other, title: Overview.otherKey, subtitle: "Other locations with scattered growth", tag: nil,
                         share: Double(data.other) / Double(max(data.total, 1)), value: signed(data.other), detail: "")
            }
        }
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if data.files.isEmpty {
                Text("No files grew in the selected range").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 100)
            }
            ForEach(data.files) { f in
                Button { openFile(f.path) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "doc").foregroundStyle(.secondary).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(readable(fileName(f.path))).lineLimit(1).truncationMode(.middle)
                                if let tag = locationTag(f.path) { TagView(text: tag) }
                            }
                            Text(placeParent(f.path)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(signed(f.net)).font(.callout.weight(.semibold))
                            Text(f.size.map { "now \(bytes($0))" } ?? "No longer exists").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(f.path)
            }
        }
    }
}

// MARK: - Building blocks

struct Card<Content: View>: View {
    let title: String
    var note: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }
}

struct StatTile: View {
    let label: String
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6)
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }
}

struct TagView: View {
    let text: String
    var body: some View {
        Text(text).font(.caption2).foregroundStyle(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .fixedSize()
            .help(explanation)
    }

    private var explanation: String {
        switch text {
        case "Swap": "macOS moves memory that isn't in use to disk; the system manages swap files as needed."
        case "Virtual memory": "Where macOS keeps swap files and hibernation data."
        case "Sleep image": "Holds memory contents during hibernation so the system can restore them."
        case "Search index": "Index data Spotlight maintains for fast file search."
        case "FSEvents log": "File system change records kept by FSEvents, used by the system and apps to track folder changes."
        case "System logs": "macOS unified logs and their supporting data, used to record and diagnose system and app activity."
        case "Diagnostic reports": "Crash, hang, and other diagnostic reports from the system or apps."
        case "System updates": "macOS software update downloads and data staged for installation."
        default: text
        }
    }
}

struct PlaceRow: View {
    let color: Color
    let title: String
    let subtitle: String
    let tag: String?
    let share: Double
    let value: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9).padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    if let tag { TagView(text: tag) }
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                GeometryReader { g in
                    Capsule().fill(color).frame(width: max(2, g.size.width * min(max(share, 0), 1)), height: 4)
                }
                .frame(height: 4)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(value).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
