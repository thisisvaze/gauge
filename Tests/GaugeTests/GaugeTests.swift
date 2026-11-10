import Foundation
import Testing
@testable import Gauge

@Test func `helpers roll up into their app, XPC services into their client, CLI processes stay separate`() {
    let procs = [
        Proc(pid: 1, path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", bytes: 100),
        Proc(pid: 2, path: "/Applications/Google Chrome.app/Contents/Frameworks/X.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)", bytes: 300),
        Proc(pid: 3, path: "/System/Library/Frameworks/WebKit.framework/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent", bytes: 50),
        Proc(pid: 4, path: "/Applications/Raycast.app/Contents/MacOS/Raycast", bytes: 10),
        Proc(pid: 5, path: "/opt/homebrew/bin/node", bytes: 200),
        Proc(pid: 6, path: "/opt/homebrew/bin/node", bytes: 20),
        Proc(pid: 7, path: "/System/Library/Frameworks/QuickLook.framework/XPCServices/ThumbnailsAgent.xpc/Contents/MacOS/ThumbnailsAgent", bytes: 5),
    ]
    let g = groups(procs, owner: { [3: 4, 7: 999][$0] })  // 999 isn't ours, so 7 stays put
    #expect(g.map(\.name) == ["Google Chrome", "node", "Raycast", "node", "ThumbnailsAgent"])
    #expect(g.map(\.bytes) == [400, 200, 60, 20, 5])
    #expect(g.map(\.owner) == [nil, 5, nil, 6, 7])
}

@Test func `only macOS's own binaries count as system`() {
    #expect(isSystem("/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"))
    #expect(isSystem("/usr/libexec/trustd"))
    #expect(isSystem(""))
    #expect(!isSystem("/usr/local/bin/redis-server"))
    #expect(!isSystem("/opt/homebrew/bin/node"))
    #expect(!isSystem("/Applications/Slack.app/Contents/MacOS/Slack"))
    #expect(isSystem("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/XPCServices/SimulatorTrampoline.xpc/Contents/MacOS/SimulatorTrampoline"))
    #expect(!isSystem("/Library/Developer/CommandLineTools/usr/bin/python3"))
}

@Test func `du output becomes a tree sorted biggest first`() {
    let t = parseDu("1048576\t/D/Users/a/big.mov\n2097152\t/D/Users/a\n2097152\t/D/Users\n307200\t/D/Applications\n2404352\t/D\nnoise\n")
    #expect(t.kids["/D"] == ["/D/Users", "/D/Applications"])
    #expect(t.kids["/D/Users/a"] == ["/D/Users/a/big.mov"])
    #expect(t.size["/D/Users/a/big.mov"] == 1_073_741_824)
}

@Test func `command line comes back from the kernel`() {
    #expect(arguments(getpid()) == CommandLine.arguments)
    #expect(cwd(getpid()) == FileManager.default.currentDirectoryPath)
}

@Test func `move to trash is offered for apps and below your top-level folders`() {
    let home = dataRoot + NSHomeDirectory()
    #expect(trashable(home + "/Downloads/big.zip"))
    #expect(trashable(home + "/Library/Developer/Xcode"))
    #expect(!trashable(home + "/Downloads"))
    #expect(!trashable(home + "/Library/Application Support"))
    #expect(!trashable(home + "/.Trash/old.dmg"))
    #expect(trashable(dataRoot + "/Applications/Xcode.app"))  // uninstalling
    #expect(!trashable(dataRoot + "/Library/Application Support/Foo"))
}

@Test func `trashing a path shrinks every folder above it`() {
    var t = parseDu("1048576\t/D/Users/a/big.mov\n2097152\t/D/Users/a\n2097152\t/D/Users\n2404352\t/D\n")
    t.remove("/D/Users/a/big.mov")
    #expect(t.size["/D/Users/a/big.mov"] == nil)
    #expect(t.kids["/D/Users/a"] == [])
    #expect(t.size["/D"] == 1_388_314_624)  // (2404352 - 1048576) KB
    #expect(parseDu(t.duText).size == t.size)
    t.add("/D/Users/.Trash", 1_073_741_824)  // the file now sits in the Trash: same disk total, new Trash folder
    #expect(t.size["/D"] == 2_462_056_448)
    #expect(t.kids["/D/Users"]?.contains("/D/Users/.Trash") == true)
}

@Test func `only the newest iOS version per device is kept`() {
    let d = "/x/iOS DeviceSupport/"
    let stale = staleVersions([d + "iPad17,3 26.5 (23F77)", d + "iPad17,3 27.0.1 (24A446)", d + "iPad17,3 26.10 (23Z1)", d + "iPhone18,1 26.5.2 (23F84)"])
    #expect(Set(stale) == [d + "iPad17,3 26.5 (23F77)", d + "iPad17,3 26.10 (23Z1)"])
}

@Test func `biggest things: whole apps, files, spread-out folders, never a folder and its contents`() {
    let H = String(home.dropLast()), A = dataRoot + "/Applications", G: Int64 = 1_000_000_000
    var t = Tree()
    for (p, gb) in [(H, 200.0), (H + "/Movies", 30), (H + "/Movies/trip.mov", 20), (H + "/Movies/clips", 10), (H + "/Movies/clips/a", 4),
                    (H + "/Movies/clips/b", 3), (H + "/Movies/clips/c", 3), (H + "/Library", 100), (H + "/.cache", 15),
                    (H + "/Downloads", 6), (H + "/Downloads/x.dmg", 1), (A, 25), (A + "/Unity", 20), (A + "/Unity/Hub.app", 2),
                    (A + "/Unity/2022.3", 18), (A + "/Unity/2022.3/Unity.app", 18), (A + "/Xcode.app", 4)] {
        t.size[p] = Int64(gb * Double(G))
        if p != H && p != A { t.kids[(p as NSString).deletingLastPathComponent, default: []].append(p) }
    }
    let files: Set = [H + "/Movies/trip.mov", H + "/Downloads/x.dmg"]
    let big = candidates(t, isDirectory: { !files.contains($0) && !$0.hasSuffix(".app") }, isPackage: { $0.hasSuffix(".app") })
    #expect(big.map { ($0.path as NSString).lastPathComponent } == ["trip.mov", "Unity.app", "clips", "Xcode.app", "Hub.app", "x.dmg"])
    #expect(big.map(\.kind) == [.file, .app, .folder, .app, .app, .file])
}
