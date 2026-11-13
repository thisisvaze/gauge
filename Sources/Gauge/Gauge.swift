import AppKit
import IOKit
import SwiftUI
import ServiceManagement

// MARK: - Memory

struct Memory { var used: Int64 = 0, total: Int64 = 0, app: Int64 = 0, wired: Int64 = 0, compressed: Int64 = 0, swap: Int64 = 0, pressure: Int32 = 1 }

let host = mach_host_self()

func memory() -> Memory {
    var s = vm_statistics64()
    var n = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    _ = withUnsafeMutablePointer(to: &s) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { host_statistics64(host, HOST_VM_INFO64, $0, &n) } }
    let page = Int64(getpagesize())
    var m = Memory(total: Int64(ProcessInfo.processInfo.physicalMemory))
    // Activity Monitor's "Memory Used" = App + Wired + Compressed
    m.app = (Int64(s.internal_page_count) - Int64(s.purgeable_count)) * page
    m.wired = Int64(s.wire_count) * page
    m.compressed = Int64(s.compressor_page_count) * page
    m.used = m.app + m.wired + m.compressed
    var swap = xsw_usage(), len = MemoryLayout<xsw_usage>.size
    sysctlbyname("vm.swapusage", &swap, &len, nil, 0)
    m.swap = Int64(swap.xsu_used)
    len = MemoryLayout<Int32>.size
    sysctlbyname("kern.memorystatus_vm_pressure_level", &m.pressure, &len, nil, 0)  // 1 normal, 2 warning, 4 critical
    return m
}

func pressureColor(_ p: Int32) -> NSColor? { p >= 4 ? .systemRed : p >= 2 ? .systemOrange : nil }

// MARK: - CPU & GPU

struct Ticks: Equatable { var user: UInt32 = 0, system: UInt32 = 0, idle: UInt32 = 0, nice: UInt32 = 0 }
struct CPU: Equatable { var used = 0.0, user = 0.0, system = 0.0 }

func cpuTicks() -> Ticks {
    var s = host_cpu_load_info()
    var n = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
    _ = withUnsafeMutablePointer(to: &s) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &n) } }
    return Ticks(user: s.cpu_ticks.0, system: s.cpu_ticks.1, idle: s.cpu_ticks.2, nice: s.cpu_ticks.3)
}

func cpuDelta(_ prev: Ticks, _ now: Ticks) -> CPU {
    let user = Double(now.user &- prev.user) + Double(now.nice &- prev.nice)
    let sys = Double(now.system &- prev.system), total = user + sys + Double(now.idle &- prev.idle)
    return total > 0 ? CPU(used: (user + sys) / total, user: user / total, system: sys / total) : CPU()
}

func gpu() -> Double {
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else { return 0 }
    defer { IOObjectRelease(iter) }
    var best = 0.0, entry = IOIteratorNext(iter)
    while entry != 0 {
        defer { IOObjectRelease(entry); entry = IOIteratorNext(iter) }
        if let s = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
           let n = (s["Device Utilization %"] ?? s["GPU Activity(%)"]) as? NSNumber {
            best = max(best, min(max(n.doubleValue / 100, 0), 1))
        }
    }
    return best
}

let timebase: mach_timebase_info_data_t = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t }()

func machNanoseconds(_ ticks: UInt64) -> UInt64 {
    let d = UInt64(max(timebase.denom, 1)), n = UInt64(timebase.numer)
    return (ticks / d) * n + (ticks % d) * n / d
}

// MARK: - Processes

struct Proc { var pid: pid_t, path: String, bytes: Int64, cpuTime: UInt64 = 0 }
struct Group { var name: String, owner: pid_t?, bytes: Int64 = 0, cpu = 0.0, members: [Proc] = [] }  // owner: set when not an app bundle

func myProcesses() -> [Proc] {
    var pids = [pid_t](repeating: 0, count: 8192)
    let n = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), &pids, Int32(pids.count * 4)) / 4
    return pids.prefix(Int(max(n, 0))).compactMap { pid in
        var ri = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &ri) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) } } == 0
        // phys_footprint is Activity Monitor's "Memory" column; user + system time share mach_absolute_time's units
        return ok && pid > 0 ? Proc(pid: pid, path: path(of: pid), bytes: Int64(ri.ri_phys_footprint), cpuTime: ri.ri_user_time &+ ri.ri_system_time) : nil
    }
}

/// Per-process CPU fraction (1.0 = one full core) between two Mach-time snapshots.
func cpuRates(_ procs: [Proc], since prev: [pid_t: UInt64], elapsed: UInt64) -> [pid_t: Double] {
    guard elapsed > 0 else { return [:] }
    var out: [pid_t: Double] = [:]
    for p in procs {
        if let t0 = prev[p.pid], p.cpuTime >= t0 { out[p.pid] = Double(p.cpuTime - t0) / Double(elapsed) }
    }
    return out
}

func path(of pid: pid_t) -> String {
    var buf = [UInt8](repeating: 0, count: 4096)
    let n = proc_pidpath(pid, &buf, 4096)
    return String(decoding: buf.prefix(Int(max(n, 0))), as: UTF8.self)
}

func arguments(_ pid: pid_t) -> [String] {
    var mib = [CTL_KERN, KERN_PROCARGS2, pid], size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return [] }
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
    // argc, the exec path, NUL padding, then argv
    let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
    return buf[4..<size].split(separator: 0).dropFirst().prefix(argc).map { String(decoding: $0, as: UTF8.self) }
}

/// When a process started (µs), 0 if it's gone: tells a pid apart from a newer process that reused the number.
func started(_ pid: pid_t) -> UInt64 {
    var info = proc_bsdinfo()
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return 0 }
    return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
}

/// A process's on-screen windows. Needs no permission (only window titles do).
func windows(_ pid: pid_t) -> Set<Int> {
    let all = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    return Set(all.filter { $0[kCGWindowOwnerPID as String] as? pid_t == pid }.compactMap { $0[kCGWindowNumber as String] as? Int })
}

/// Quit politely, then force quit whatever is still running `grace` later: stuck apps and processes that ignore SIGTERM.
/// An app that opened a window meanwhile is asking you something (Save changes?), so it's left to you.
func stop(_ app: NSRunningApplication?, _ pids: [pid_t], grace: Duration = .seconds(10)) {
    let starts = pids.map { ($0, started($0)) }
    let shown = app.map { windows($0.processIdentifier) } ?? []
    if let app { app.terminate() } else { pids.forEach { kill($0, SIGTERM) } }
    Task {
        try? await Task.sleep(for: grace)
        if let app {
            if !app.isTerminated && windows(app.processIdentifier).isSubset(of: shown) { app.forceTerminate() }
        } else {
            for (pid, t) in starts where t != 0 && started(pid) == t { kill(pid, SIGKILL) }
        }
    }
}

/// Working directory: tells two `claude` or `node` processes apart.
func cwd(_ pid: pid_t) -> String {
    var info = proc_vnodepathinfo()
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 else { return "" }
    return withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
}

/// The app an XPC service works for (Safari for its tabs, Docker for its VM). Private but stable libsystem call; nil if it ever goes away.
let responsible = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
    .map { unsafeBitCast($0, to: (@convention(c) (pid_t) -> pid_t).self) }

/// One row per app: helpers live inside the app bundle, XPC services count toward the client they run for, everything else stands alone.
func groups(_ procs: [Proc], cpu: [pid_t: Double] = [:], owner: (pid_t) -> pid_t?) -> [Group] {
    let paths = Dictionary(procs.map { ($0.pid, $0.path) }) { a, _ in a }
    var out: [String: Group] = [:]
    for p in procs {
        var who = (pid: p.pid, path: p.path)
        if p.path.contains(".xpc/"), let o = owner(p.pid), o != p.pid, let op = paths[o] { who = (o, op) }
        let bundle = who.path.range(of: ".app/").map { String(who.path[..<$0.lowerBound]) }
        let key = bundle ?? "\(who.pid)"
        out[key, default: Group(name: ((bundle ?? who.path) as NSString).lastPathComponent, owner: bundle == nil ? who.pid : nil)].members.append(p)
        out[key]!.bytes += p.bytes
        out[key]!.cpu += cpu[p.pid, default: 0]
    }
    return out.values.sorted { $0.bytes > $1.bytes }
}

/// macOS's own binaries (and the iOS Simulator's insides; quit Simulator instead): never offered for killing.
func isSystem(_ path: String) -> Bool {
    path.isEmpty || !path.hasPrefix("/usr/local/") && ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/", "/Library/Developer/PrivateFrameworks/", "/Library/Developer/CoreSimulator/"].contains { path.hasPrefix($0) }
}

let protected: Set = ["com.apple.finder", "com.apple.loginwindow"]

// MARK: - Disk

let dataRoot = "/System/Volumes/Data"  // the writable volume; "/" is the sealed system snapshot

func disk() -> (free: Int64, total: Int64) {
    let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
    return (v?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(v?.volumeTotalCapacity ?? 0))
}

struct Tree { var size: [String: Int64] = [:], kids: [String: [String]] = [:] }

/// `du -k` lines ("kilobytes<TAB>path") → sizes, plus each folder's children biggest first.
func parseDu(_ text: String) -> Tree {
    var t = Tree()
    for line in text.split(separator: "\n") {
        let f = line.split(separator: "\t", maxSplits: 1)
        guard f.count == 2, let kb = Int64(f[0]) else { continue }
        let path = String(f[1])
        t.size[path] = kb * 1024
        t.kids[(path as NSString).deletingLastPathComponent, default: []].append(path)
    }
    t.kids = t.kids.mapValues { $0.sorted { t.size[$0, default: 0] > t.size[$1, default: 0] } }
    return t
}

@concurrent func du(_ root: String) async -> String {
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/du")
    p.arguments = ["-axk", "-t", "100m", root]  // files and folders ≥ 100 MB only, so the output stays tiny
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    p.qualityOfService = .utility
    guard (try? p.run()) != nil else { return "" }
    let data = try? out.fileHandleForReading.readToEnd()
    p.waitUntilExit()
    return String(decoding: data ?? Data(), as: UTF8.self)
}

/// The system TCC database is world-readable on disk but opens only with Full Disk Access (and never prompts).
func hasFullDiskAccess() -> Bool {
    let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
    if fd >= 0 { close(fd) }
    return fd >= 0
}

/// /System/Volumes/Data/Users/… is firmlinked to /Users/…; prefer the short form wherever it exists.
func userPath(_ path: String) -> String {
    let short = String(path.dropFirst(dataRoot.count))
    return path.hasPrefix(dataRoot + "/") && FileManager.default.fileExists(atPath: short) ? short : path
}

func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: userPath(path))]) }

/// Move to Trash is offered for apps in /Applications (that's uninstalling) and inside your home,
/// never for a top-level home folder or a ~/Library folder itself (Application Support, Caches…).
func trashable(_ path: String) -> Bool {
    if path.hasPrefix(dataRoot + "/Applications/") { return true }
    guard path.hasPrefix(home) else { return false }
    let rel = path.dropFirst(home.count).split(separator: "/")
    return rel.first != ".Trash" && rel.count >= (rel.first == "Library" ? 3 : 2)
}

/// One-click clean-ups: things that come back on their own if they're ever needed again. `targets` picks the paths from the scan.
struct Cleanup { let name: String, note: String, targets: (Tree) -> [String] }

let home = dataRoot + NSHomeDirectory() + "/"
let deviceSupport = home + "Library/Developer/Xcode/iOS DeviceSupport"

let cleanups = [
    Cleanup(name: "Old iOS versions (Xcode)", note: "Debug files for iOS versions your devices no longer run") { staleVersions($0.kids[deviceSupport] ?? []) },
    Cleanup(name: "Xcode build data", note: "Rebuilt on your next build") { _ in [home + "Library/Developer/Xcode/DerivedData"] },
    Cleanup(name: "Simulator caches", note: "Rebuilt when a simulator runs") { _ in [home + "Library/Developer/CoreSimulator/Caches"] },
    Cleanup(name: "uv cache", note: "Python packages, re-downloaded when needed") { _ in [home + ".cache/uv"] },
    Cleanup(name: "npm cache", note: "Node packages, re-downloaded when needed") { _ in [home + ".npm/_cacache"] },
    Cleanup(name: "Homebrew downloads", note: "Installers for things already installed") { _ in [home + "Library/Caches/Homebrew"] },
]

/// Xcode keeps a 5–7 GB folder per device per iOS version ("iPad17,3 27.0.1 (24A446)"). Only the newest per device is still used.
func staleVersions(_ folders: [String]) -> [String] {
    func parts(_ p: String) -> [Substring] { (p as NSString).lastPathComponent.split(separator: " ") }
    return Dictionary(grouping: folders) { parts($0).first ?? "" }.values.flatMap { versions in
        versions.sorted { String(parts($0).dropFirst().first ?? "").compare(String(parts($1).dropFirst().first ?? ""), options: .numeric) == .orderedAscending }
            .dropLast()
    }
}

struct Big: Identifiable {
    enum Kind: String, CaseIterable { case app = "Apps", file = "Files", folder = "Folders" }
    let path: String, bytes: Int64, kind: Kind
    var date: Date? = nil, opened = false  // last opened (Spotlight) if known, else last changed
    var id: String { path }
}

/// The big things you'd actually decide about, never a folder and something inside it: apps and other packages whole,
/// files, and folders whose size is spread out (no child holds half). Walks /Applications and your home,
/// skipping ~/Library and dot-folders, which aren't yours to hand-delete (Quick clean-up covers their safe parts).
func candidates(_ tree: Tree, isDirectory: (String) -> Bool, isPackage: (String) -> Bool, min: Int64 = 500_000_000) -> [Big] {
    var out: [Big] = []
    func visit(_ p: String, depth: Int) {
        let size = tree.size[p] ?? 0
        guard size >= min, !(p as NSString).lastPathComponent.hasPrefix(".") else { return }
        if isPackage(p) { return out.append(Big(path: p, bytes: size, kind: p.hasSuffix(".app") ? .app : .file)) }
        guard isDirectory(p) else { return out.append(Big(path: p, bytes: size, kind: .file)) }
        let kids = tree.kids[p] ?? []
        let largest = kids.map { tree.size[$0] ?? 0 }.max() ?? 0
        if depth > 0 && largest * 2 < size { return out.append(Big(path: p, bytes: size, kind: .folder)) }
        kids.forEach { visit($0, depth: depth + 1) }  // Documents, Downloads… themselves are never candidates
    }
    for kid in tree.kids[String(home.dropLast())] ?? [] where (kid as NSString).lastPathComponent != "Library" { visit(kid, depth: 0) }
    for kid in tree.kids[dataRoot + "/Applications"] ?? [] { visit(kid, depth: 1) }
    return out.sorted { $0.bytes > $1.bytes }
}

extension Tree {
    /// Drop a path that went to the Trash, shrinking the folders above it.
    mutating func remove(_ path: String) {
        guard let gone = size.removeValue(forKey: path) else { return }
        var p = (path as NSString).deletingLastPathComponent
        kids[p]?.removeAll { $0 == path }
        while let s = size[p] {
            size[p] = s - gone
            p = (p as NSString).deletingLastPathComponent
        }
    }

    /// Count bytes that just arrived at `path` (the Trash), growing the folders above it.
    mutating func add(_ path: String, _ bytes: Int64) {
        let parent = (path as NSString).deletingLastPathComponent
        if size[path] == nil { kids[parent, default: []].append(path) }
        size[path, default: 0] += bytes
        var p = parent
        while let s = size[p] {
            size[p] = s + bytes
            p = (p as NSString).deletingLastPathComponent
        }
    }

    var duText: String { size.map { "\($0.value / 1024)\t\($0.key)" }.joined(separator: "\n") }
}

// MARK: - Updates

/// "v1.10" is newer than "1.9".
nonisolated func isNewer(_ tag: String, than version: String) -> Bool {
    tag.trimmingPrefix("v").compare(version, options: .numeric) == .orderedDescending
}

/// The latest GitHub release, unpacked next to this app, if it's newer and signed by the same developer.
/// Your own builds (Apple Development or ad hoc signature) never match a release's, so they never update.
@concurrent func newerRelease() async -> URL? {
    let me = Bundle.main.bundleURL
    guard let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
          let (json, _) = try? await URLSession.shared.data(from: URL(string: "https://api.github.com/repos/thisisvaze/gauge/releases/latest")!),
          let tag = (try? JSONSerialization.jsonObject(with: json) as? [String: Any])?["tag_name"] as? String,
          isNewer(tag, than: version),
          let (zip, _) = try? await URLSession.shared.download(from: URL(string: "https://github.com/thisisvaze/gauge/releases/download/\(tag)/gauge.zip")!),
          let dir = try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: me, create: true)
    else { return nil }
    defer { try? FileManager.default.removeItem(at: zip) }
    let unzip = Process()
    unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    unzip.arguments = ["-x", "-k", zip.path, dir.path]
    guard (try? unzip.run()) != nil else { return nil }
    unzip.waitUntilExit()
    let new = dir.appending(path: "gauge.app")
    var mine: SecStaticCode?, theirs: SecStaticCode?, req: SecRequirement?
    guard unzip.terminationStatus == 0,
          SecStaticCodeCreateWithPath(me as CFURL, [], &mine) == errSecSuccess, let mine,
          SecCodeCopyDesignatedRequirement(mine, [], &req) == errSecSuccess, let req,
          SecStaticCodeCreateWithPath(new as CFURL, [], &theirs) == errSecSuccess, let theirs,
          SecStaticCodeCheckValidity(theirs, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), req) == errSecSuccess
    else { return nil }
    return new
}

/// Swap in the new app and start it. Does nothing where gauge can't write itself (not an admin, or run from Downloads).
func install(_ new: URL) {
    guard (try? FileManager.default.replaceItemAt(Bundle.main.bundleURL, withItemAt: new)) != nil else { return }
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-n", Bundle.main.bundlePath]
    guard (try? open.run()) != nil else { return }
    NSApp.terminate(nil)
}

let activityMonitor = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
let storageSettings = URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!
let fullDiskAccessSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

// MARK: - Drawing

/// Compact sizes: "29 GB", "5.7 GB", "742 MB". Memory counts in 1024s like Activity Monitor; disk in 1000s like Finder.
func bytes(_ n: Int64, _ style: ByteCountFormatter.CountStyle = .file) -> String {
    let k: Double = style == .memory ? 1024 : 1000
    var v = Double(n), unit = 0
    while v >= k && unit < 4 { v /= k; unit += 1 }
    return String(format: v < 10 && unit > 0 ? "%.1f %@" : "%.0f %@", v, ["B", "KB", "MB", "GB", "TB"][unit])
}

func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

/// Share of the whole machine, same scale as the CPU total: tenths below 10%, whole numbers at 10% and up.
func cpuPct(_ share: Double) -> String {
    let p = share * 100
    return p >= 10 ? String(format: "%.0f%%", p) : String(format: "%.1f%%", p)
}

enum Bar: String, CaseIterable {
    case memory = "Memory", storage = "Storage", cpu = "CPU", gpu = "GPU"
    static let key = "menuBar"
    static func normalize(_ raw: [String]?) -> [Bar] {
        guard let raw else { return [.memory, .storage] }
        let set = Set(raw.compactMap(Bar.init(rawValue:)))
        return set.isEmpty ? [.memory, .storage] : allCases.filter(set.contains)
    }
    static var active: [Bar] {
        get { normalize(UserDefaults.standard.stringArray(forKey: key)) }
        set { UserDefaults.standard.set(normalize(newValue.map(\.rawValue)).map(\.rawValue), forKey: key) }
    }
}

/// Menu bar icon: one level bar per enabled resource (memory and disk by default). Template unless one is alerting.
func gauge(_ levels: [(Double, NSColor?)]) -> NSImage {
    let alert = levels.contains { $0.1 != nil }
    let img = NSImage(size: NSSize(width: CGFloat(max(levels.count, 1)) * 7 - 1, height: 16), flipped: false) { _ in
        for (i, (level, color)) in levels.enumerated() {
            let ink = color ?? (alert ? .labelColor : .black)
            let track = NSRect(x: 1 + CGFloat(i) * 7, y: 2, width: 4.5, height: 12)
            var fill = track
            fill.size.height = max(2, track.height * min(max(level, 0), 1))
            ink.withAlphaComponent(0.25).setFill(); NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
            ink.setFill(); NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5).fill()
        }
        return true
    }
    img.isTemplate = !alert
    return img
}

// MARK: - App

struct AppRow: Identifiable {
    let id: String, name: String, value: String, detail: String
    let quit: ((_ force: Bool) -> Void)?  // nil: part of macOS, never offered
    let icon: NSImage?
    var open: (() -> Void)? = nil  // nil: no app to switch to (command line tools, background processes)
}

/// macOS's own background processes go by bundle ID ("com.apple.CoreSimulator.CoreSimulatorService"): the last part reads fine on its own.
func display(_ name: String) -> String {
    name.hasPrefix("com.apple.") ? String(name.split(separator: ".").last ?? Substring(name)) : name
}

/// Like clicking its Dock icon: brings the app forward, with a window if it had none open.
func switchTo(_ app: NSRunningApplication) {
    if let url = app.bundleURL { NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil) } else { _ = app.activate() }
}

/// Dock apps quit gracefully (they can still ask to save); third-party background processes get SIGTERM; macOS's own get nothing.
/// Anything still running 10 s after Quit gets force quit (see `stop`).
func makeRow(_ g: Group, value: String, apps: [pid_t: NSRunningApplication]) -> AppRow {
    let app = g.members.compactMap { apps[$0.pid] }.filter { $0.activationPolicy != .prohibited }
        .min { $0.activationPolicy.rawValue < $1.activationPolicy.rawValue }  // the Dock app over its menu-bar helpers
    let pids = g.members.filter { !isSystem($0.path) }.map(\.pid)
    let safe = (app.map { $0.activationPolicy == .regular && !protected.contains($0.bundleIdentifier ?? "") } ?? false) || !pids.isEmpty
    let args = g.owner.map(arguments) ?? []  // argv[0] names it "claude", not its versioned binary "2.1.310"
    let name = display(args.first.map { ($0 as NSString).lastPathComponent } ?? g.name)
    let dock = app?.activationPolicy == .regular ? app : nil
    let detail = g.owner.map { args.joined(separator: " ") + "\nin " + (cwd($0) as NSString).abbreviatingWithTildeInPath }
        ?? ("\(g.members.count) processes" + (dock == nil ? "" : " · click to switch to it"))
    let quit: (Bool) -> Void = { force in
        guard force else { return stop(app, pids) }
        if let app { app.forceTerminate() } else { pids.forEach { kill($0, SIGKILL) } }
    }
    return AppRow(id: g.owner.map { "\($0)" } ?? g.name, name: name, value: value,
                  detail: safe ? detail : "Part of macOS, so gauge won’t quit it", quit: safe ? quit : nil, icon: app?.icon,
                  open: dock.map { a in { switchTo(a) } })
}

final class Model: ObservableObject {
    @Published var mem = memory()
    @Published var cpu = CPU()
    @Published var gpuUsed = 0.0
    @Published var space = disk()
    @Published var rows: [AppRow] = []
    @Published var cpuRows: [AppRow] = []
    @Published var quitting: Set<String> = []  // row ids that read "Quitting…"
    @Published var big: [Big] = []
    @Published var scannedAt: Date?
    @Published var scanStart: Date?
    @Published var fullDiskAccess = hasFullDiskAccess()
    var prevCPU: (at: ContinuousClock.Instant, ticks: Ticks)?
    var prevProcs: (at: UInt64, times: [pid_t: UInt64])?
    var rates: [pid_t: Double] = [:]
    let cache = URL.cachesDirectory.appending(path: "dev.vaze.Gauge/scan.txt")
    var trashPath: String { dataRoot + NSHomeDirectory() + "/.Trash" }

    init() {
        scannedAt = (try? cache.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// The last scan, read from disk only while it's needed: kept in memory it was a third of gauge's footprint.
    func load() -> Tree? { (try? String(contentsOf: cache, encoding: .utf8)).map(parseDu) }

    /// The "biggest things" list, with when each was last opened (Spotlight) or changed. Re-checks the disk so removed items drop out.
    func rebuild(_ tree: Tree? = nil) {
        let fm = FileManager.default
        let found = (tree ?? load()).map { candidates($0, isDirectory: { var d: ObjCBool = false; return fm.fileExists(atPath: $0, isDirectory: &d) && d.boolValue },
                                                     isPackage: { NSWorkspace.shared.isFilePackage(atPath: $0) }) } ?? []
        big = found.prefix(40).filter { fm.fileExists(atPath: $0.path) }.map { item in
            var item = item
            let url = URL(fileURLWithPath: userPath(item.path))
            let opened = NSMetadataItem(url: url)?.value(forAttribute: NSMetadataItemLastUsedDateKey) as? Date
            item.date = opened ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            item.opened = opened != nil
            return item
        }
    }

    @discardableResult func sampleCPU() -> Bool {
        let now = cpuTicks(), t = ContinuousClock.now
        guard let prev = prevCPU else { prevCPU = (t, now); return true }
        if t - prev.at < .milliseconds(150) { return false }
        let warm = t - prev.at < .seconds(10)
        if warm { cpu = cpuDelta(prev.ticks, now) }
        prevCPU = (t, now)
        return !warm
    }

    @discardableResult func refresh(limit: Int = 8) -> Bool {
        mem = memory()
        gpuUsed = gpu()
        let coldCPU = sampleCPU()
        let procs = myProcesses(), now = mach_absolute_time()
        var coldProcs = false
        if let prev = prevProcs, now >= prev.at {
            let ns = machNanoseconds(now - prev.at)
            if ns >= 150_000_000 {
                if ns < 10_000_000_000 { rates = cpuRates(procs, since: prev.times, elapsed: now - prev.at) } else { rates = [:]; coldProcs = true }
                prevProcs = (now, Dictionary(procs.map { ($0.pid, $0.cpuTime) }) { a, _ in a })
            }
        } else {
            prevProcs = (now, Dictionary(procs.map { ($0.pid, $0.cpuTime) }) { a, _ in a })
            coldProcs = true
        }
        let apps = Dictionary(NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) }) { a, _ in a }
        let grouped = groups(procs, cpu: rates, owner: { responsible?($0) })
        rows = grouped.prefix(limit).map { makeRow($0, value: bytes($0.bytes, .memory), apps: apps) }
        cpuRows = grouped.sorted { ($0.cpu, $0.bytes) > ($1.cpu, $1.bytes) }.prefix(limit).map { makeRow($0, value: cpuPct($0.cpu / Double(ProcessInfo.processInfo.activeProcessorCount)), apps: apps) }
        return coldCPU || coldProcs
    }

    /// The row reads "Quitting…" until it drops out. Past the force-quit grace (see `stop`) it's either gone or the app is asking you something.
    func quit(_ row: AppRow, force: Bool) {
        row.quit?(force)
        quitting.insert(row.id)
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            refresh()
            try? await Task.sleep(for: .seconds(10))
            quitting.remove(row.id)
            refresh()
        }
    }
    func refreshDisk() {
        space = disk()
        fullDiskAccess = hasFullDiskAccess()
        // First run with access, or access given since the last scan, which couldn't see the private folders
        if fullDiskAccess, !UserDefaults.standard.bool(forKey: "fullScan"), scanStart == nil { scan() }
    }

    func scan() {
        scanStart = .now
        let full = fullDiskAccess
        Task {
            let tree = parseDu(await du(dataRoot))
            save(tree)
            scannedAt = .now
            scanStart = nil
            UserDefaults.standard.set(full, forKey: "fullScan")
            rebuild(tree)
        }
    }

    func save(_ tree: Tree) {
        try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? tree.duText.write(to: cache, atomically: true, encoding: .utf8)
    }

    /// False when macOS refused (e.g. an app owned by the system): show it in Finder instead, which can ask for your password.
    @discardableResult func trash(_ path: String) -> Bool {
        guard (try? FileManager.default.trashItem(at: URL(fileURLWithPath: userPath(path)), resultingItemURL: nil)) != nil else { return false }
        if var tree = load() {
            let size = tree.size[path] ?? 0
            tree.remove(path)
            tree.add(trashPath, size)
            save(tree)
            rebuild(tree)
        }
        return true
    }
}

@main
final class Monitor: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    static func main() {
        let app = NSApplication.shared
        let monitor = Monitor()
        app.delegate = monitor
        withExtendedLifetime(monitor) { app.run() }
    }

    let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    let model = Model()
    var ticks = 0, bg: Timer?, live: Timer?, outside: Any?, shown: [Int] = []

    override init() {
        super.init()
        status.button?.target = self
        status.button?.action = #selector(toggle)
        status.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        popover.behavior = .transient
        popover.delegate = self
        tick()
        schedule()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appActivated), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        Task {
            try? await Task.sleep(for: .seconds(60))  // let login settle, then check once a day
            while true {
                if let new = await newerRelease(), !popover.isShown { install(new) }  // never restart under your pointer
                try? await Task.sleep(for: .seconds(86_400))
            }
        }
    }

    /// Stay on the 5 s coalesced timer unless CPU or GPU is shown in the menu bar.
    func schedule() {
        bg?.invalidate()
        let fast = Bar.active.contains(.cpu) || Bar.active.contains(.gpu)
        let t = Timer.scheduledTimer(timeInterval: fast ? 2 : 5, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        t.tolerance = fast ? 0.5 : 2
        bg = t
    }

    /// Switching to another app (from a row, ⌘Tab or the Dock) closes the window.
    /// Except System Settings: the window stays beside it so gauge's icon can be dragged into Full Disk Access.
    @objc func appActivated(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if app != .current && app?.bundleIdentifier != "com.apple.systempreferences" { popover.performClose(nil) }
    }

    @objc func tick() {
        let bars = Bar.active, fast = bars.contains(.cpu) || bars.contains(.gpu)
        if ticks % (fast ? 30 : 12) == 0 { model.refreshDisk() }  // the purgeable-aware query costs ~16 ms; once a minute is plenty
        ticks += 1
        model.mem = memory()
        if bars.contains(.cpu), model.sampleCPU() {
            Task { try? await Task.sleep(for: .milliseconds(250)); self.tick() }
        }
        if bars.contains(.gpu) { model.gpuUsed = gpu() }
        let m = model.mem, s = model.space, diskUsed = 1 - Double(s.free) / Double(max(s.total, 1))
        let levels: [(Double, NSColor?)] = bars.map {
            switch $0 {
            case .memory: (Double(m.used) / Double(max(m.total, 1)), pressureColor(m.pressure))
            case .storage: (diskUsed, diskUsed > 0.9 ? .systemRed : nil)
            case .cpu: (model.cpu.used, model.cpu.used > 0.9 ? .systemOrange : nil)
            case .gpu: (model.gpuUsed, model.gpuUsed > 0.9 ? .systemOrange : nil)
            }
        }
        // Redraw only when a bar moves a pixel or changes color: most ticks change nothing you could see
        let drawn = levels.flatMap { [Int(($0.0 * 24).rounded()), $0.1.map { $0 == .systemRed ? 2 : 1 } ?? 0] }
        if drawn != shown { status.button?.image = gauge(levels); shown = drawn }
        var tip = ["Memory \(bytes(m.used, .memory)) of \(bytes(m.total, .memory))", "\(bytes(s.free)) free on disk"]
        if bars.contains(.cpu) { tip.append("CPU \(pct(model.cpu.used))") }
        if bars.contains(.gpu) { tip.append("GPU \(pct(model.gpuUsed))") }
        let text = tip.joined(separator: " · ")
        if status.button?.toolTip != text { status.button?.toolTip = text }
    }

    @objc func toggle() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            popover.performClose(nil)
            let menu = NSMenu()
            let open = menu.addItem(withTitle: "Open gauge", action: #selector(showDashboard), keyEquivalent: "")
            open.target = self
            let barsMenu = NSMenu(), active = Bar.active
            for bar in Bar.allCases {
                let item = barsMenu.addItem(withTitle: bar.rawValue, action: #selector(toggleBar(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = bar.rawValue
                item.state = active.contains(bar) ? .on : .off
                item.isEnabled = !(active.count == 1 && active.contains(bar))
            }
            let barsItem = menu.addItem(withTitle: "Menu Bar", action: nil, keyEquivalent: "")
            barsItem.submenu = barsMenu
            for (title, action) in [("Activity Monitor", #selector(openActivityMonitor)),
                                    ("Storage Settings", #selector(openStorageSettings)), ("Open at Login", #selector(toggleLogin))] {
                let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
                item.target = self
                if action == #selector(toggleLogin) { item.state = SMAppService.mainApp.status == .enabled ? .on : .off }
            }
            menu.addItem(.separator())
            let quit = menu.addItem(withTitle: "Quit gauge", action: #selector(quitGauge), keyEquivalent: "q")
            quit.target = self
            status.menu = menu
            status.button?.performClick(nil)
            status.menu = nil
        } else {
            popover.isShown ? popover.performClose(nil) : show()
        }
    }

    @objc func toggleBar(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let bar = Bar(rawValue: raw) else { return }
        var bars = Bar.active
        if let i = bars.firstIndex(of: bar) { bars.remove(at: i) } else { bars.append(bar) }
        Bar.active = bars
        ticks = 1  // skip re-querying disk just for toggling a bar
        schedule()
        tick()
    }

    @objc func showDashboard() { show() }
    @objc func openActivityMonitor() { NSWorkspace.shared.open(activityMonitor) }
    @objc func openStorageSettings() { NSWorkspace.shared.open(storageSettings) }
    @objc func quitGauge() { NSApp.terminate(nil) }
    @objc func toggleLogin() {
        do {
            try SMAppService.mainApp.status == .enabled ? SMAppService.mainApp.unregister() : SMAppService.mainApp.register()
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    func show() {
        guard let button = status.button else { return }
        let cold = model.refresh()
        model.refreshDisk()
        let host = NSHostingController(rootView: Dashboard(model: model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.appearance = NSApp.effectiveAppearance  // your Light/Dark setting, not the wallpaper-tinted menu bar's
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if cold {
            Task { try? await Task.sleep(for: .milliseconds(250)); if self.popover.isShown { self.model.refresh() } }
        }
        live = Timer.scheduledTimer(timeInterval: 2, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        // .transient only closes on outside clicks while gauge is the active app, which macOS doesn't always grant a menu bar app.
        // A global monitor sees clicks in every other app and on the desktop (mouse monitors need no permission).
        outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.popover.performClose(nil) }
        }
    }

    @objc func refresh() { model.refresh() }

    func popoverDidClose(_ notification: Notification) {
        live?.invalidate()
        if let outside { NSEvent.removeMonitor(outside) }
        outside = nil
        popover.contentViewController = nil  // free the views while closed
    }

    /// Opening gauge again (Spotlight, Raycast, `open -a gauge`) shows the dashboard, even if the icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !popover.isShown { show() }
        return false
    }
}

