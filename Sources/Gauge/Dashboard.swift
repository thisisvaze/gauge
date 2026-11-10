import SwiftUI

// MARK: - Native neutrals, with separate colors for each resource

func tone(_ light: UInt32, _ dark: UInt32) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        return NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    })
}

enum Palette {
    static let surface = tone(0xfcfcfb, 0x1a1a19), hover = tone(0xf3f2ef, 0x262624)
    static let ink = tone(0x252522, 0xf0efec), ink2 = tone(0x52514e, 0xc3c2b7), ink3 = tone(0x73716b, 0xaaa69f)
    static let track = tone(0xe8e7e2, 0x353530)
    static let apps = tone(0x087d6b, 0x75d0b1), wired = tone(0x9460bf, 0xc5a2e5)
    static let compressed = tone(0xb08329, 0xe4bb62), storage = tone(0xba6038, 0xe5a57b)
    static let good = tone(0x237548, 0x74cda4), warning = tone(0x916300, 0xe4bb62), critical = tone(0xb53030, 0xf08080)
}

struct Dashboard: View {
    enum Resource { case memory, storage }
    let model: Model
    @State private var resource: Resource = .memory

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button { resource = .memory } label: { MemoryPanel(model: model) }
                    .buttonStyle(.plain)
                    .background(RoundedRectangle(cornerRadius: 10).fill(resource == .memory ? Palette.hover : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(resource == .memory ? Palette.track : .clear))
                    .accessibilityAddTraits(resource == .memory ? .isSelected : [])
                    .accessibilityHint("Show top apps")
                Button { resource = .storage } label: { DiskPanel(model: model) }
                    .buttonStyle(.plain)
                    .background(RoundedRectangle(cornerRadius: 10).fill(resource == .storage ? Palette.hover : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(resource == .storage ? Palette.track : .clear))
                    .accessibilityAddTraits(resource == .storage ? .isSelected : [])
                    .accessibilityHint("Show largest items")
            }
            .padding(6)
            .onKeyPress(.leftArrow) { resource = .memory; return .handled }
            .onKeyPress(.rightArrow) { resource = .storage; return .handled }
            Divider()
            SwiftUI.Group {
                switch resource {
                case .memory:
                    VStack(spacing: 0) {
                        HStack {
                            Text("Top apps").fontWeight(.medium)
                            Spacer()
                            if model.mem.swap > 500_000_000 { Text("\(bytes(model.mem.swap, .memory)) swap") }
                        }
                        .font(.system(size: 11)).foregroundStyle(Palette.ink2)
                        .padding(.horizontal, 8).frame(height: 28)
                        ForEach(model.rows) { AppRowView(row: $0, model: model) }
                    }
                case .storage:
                    Explorer(model: model)
                }
            }
            .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 10)
            .frame(minHeight: 354, alignment: .top)
        }
        .frame(width: 400)
        .foregroundStyle(Palette.ink)
        .tint(Palette.ink)
        .background(Palette.surface)
    }
}

struct MemoryPanel: View {
    let model: Model

    var body: some View {
        let m = model.mem
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Memory").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink2)
                Spacer(minLength: 4)
                Pressure(level: m.pressure)
            }
            Figure(value: bytes(m.used, .memory), caption: "used")
            Text("of \(bytes(m.total, .memory))").font(.system(size: 10)).foregroundStyle(Palette.ink3)
            StackedBar(parts: [(m.app, Palette.apps), (m.wired, Palette.wired), (m.compressed, Palette.compressed)], total: m.total, track: Palette.track)
                .padding(.top, 4)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .help("Apps \(bytes(m.app, .memory)) · Wired \(bytes(m.wired, .memory)) · Compressed \(bytes(m.compressed, .memory))")
        .accessibilityElement(children: .combine)
    }
}

struct DiskPanel: View {
    let model: Model

    var body: some View {
        let s = model.space, used = max(0, s.total - s.free)
        VStack(alignment: .leading, spacing: 8) {
            Text("Storage").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink2)
                .frame(height: 14)
            Figure(value: bytes(s.free), caption: "free")
            Text("of \(bytes(s.total))").font(.system(size: 10)).foregroundStyle(Palette.ink3)
            StackedBar(parts: [(used, Double(used) / Double(max(s.total, 1)) > 0.9 ? Palette.critical : Palette.storage)], total: s.total, track: Palette.track)
                .padding(.top, 4)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .help("\(bytes(used)) used · \(bytes(s.free)) available")
        .accessibilityElement(children: .combine)
    }
}

struct Pressure: View {
    let level: Int32

    var body: some View {
        let (label, icon, color) = level >= 4 ? ("Critical", "exclamationmark.octagon.fill", Palette.critical)
            : level >= 2 ? ("Elevated", "exclamationmark.triangle.fill", Palette.warning)
            : ("Normal", "checkmark.circle.fill", Palette.good)
        Label(label, systemImage: icon).font(.system(size: 10)).foregroundStyle(color)
            .accessibilityLabel("\(label) memory pressure")
    }
}

struct Figure: View {
    let value: String, caption: String

    var body: some View {
        let parts = value.split(separator: " ", maxSplits: 1)
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(parts.first ?? "0").font(.system(size: 28, weight: .semibold)).tracking(-1)
            if parts.count == 2 { Text(parts[1]).font(.system(size: 15, weight: .medium)) }
            Text(caption).font(.system(size: 11)).foregroundStyle(Palette.ink2)
        }
        .monospacedDigit().fixedSize()
    }
}

struct StackedBar: View {
    let parts: [(Int64, Color)], total: Int64, track: Color

    var body: some View {
        GeometryReader { g in
            let room = max(0, g.size.width - 2 * CGFloat(parts.count))
            HStack(spacing: 2) {
                ForEach(parts.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1).fill(parts[i].1)
                        .frame(width: max(0, room * CGFloat(parts[i].0) / CGFloat(max(total, 1))))
                }
                RoundedRectangle(cornerRadius: 1).fill(track)
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

struct ConfirmButton: View {
    let title: String, confirm: String, action: () -> Void
    @State private var armed = false

    var body: some View {
        Button(armed ? confirm : title) {
            if armed { action(); armed = false } else { armed = true }
        }
        .buttonStyle(.bordered).controlSize(.small).tint(armed ? .red : nil)
        .task(id: armed) {
            guard armed else { return }
            do { try await Task.sleep(for: .seconds(3)); armed = false } catch { }
        }
    }
}

struct AppRowView: View {
    let row: AppRow, model: Model
    @State private var hover = false
    @FocusState private var focused: Bool

    var body: some View {
        let quitting = model.quitting.contains(row.id)
        HStack(spacing: 9) {
            if let icon = row.icon {
                Image(nsImage: icon).resizable().frame(width: 23, height: 23)
            } else {
                Image(systemName: row.quit == nil ? "lock.fill" : "terminal")
                    .font(.system(size: 14)).foregroundStyle(Palette.ink2)
                    .frame(width: 23, height: 23).background(Palette.track, in: RoundedRectangle(cornerRadius: 5))
            }
            Text(row.name).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(row.quit == nil || quitting ? Palette.ink3 : Palette.ink)
            Spacer(minLength: 6)
            ZStack(alignment: .trailing) {
                if quitting {
                    Text("Quitting…").foregroundStyle(Palette.ink3)
                } else {
                    Text(bytes(row.bytes, .memory)).monospacedDigit().foregroundStyle(Palette.ink2)
                        .opacity((hover || focused) && row.quit != nil ? 0 : 1)
                    if hover || focused, row.quit != nil {
                        Button("Quit") { model.quit(row, force: false) }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
            .frame(width: 62, alignment: .trailing)
        }
        .font(.system(size: 12)).frame(height: 36).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(hover || focused ? Palette.hover : .clear))
        .contentShape(Rectangle()).focusable(interactions: .activate).focused($focused)  // keyboard focus only: a click shouldn't select the row
        .onTapGesture { row.open?() }
        .onHover { hover = $0 }.help(row.detail)
        .contextMenu {
            if let open = row.open { Button("Switch to \(row.name)") { open() } }
            if row.quit != nil {
                Button("Quit") { model.quit(row, force: false) }
                Button("Force Quit") { model.quit(row, force: true) }
            }
            if row.open != nil || row.quit != nil { Divider() }
            Button("Open Activity Monitor") { NSWorkspace.shared.open(activityMonitor) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.name), \(quitting ? "quitting" : bytes(row.bytes, .memory))")
        .accessibilityActions {
            if let open = row.open { Button("Switch to \(row.name)") { open() } }
            if row.quit != nil {
                Button("Quit") { model.quit(row, force: false) }
                Button("Force Quit") { model.quit(row, force: true) }
            }
        }
    }
}

struct Explorer: View {
    let model: Model
    @State private var filter = "All"

    var body: some View {
        let shown = model.big.filter { filter == "All" || $0.kind.rawValue == filter }.prefix(7)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Largest items").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.ink2)
                Spacer(minLength: 4)
                Picker("Show", selection: $filter) {
                    Text("All items").tag("All")
                    ForEach(Big.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                }
                .labelsHidden().pickerStyle(.menu).controlSize(.small).frame(width: 105)
                if let start = model.scanStart {
                    TimelineView(.periodic(from: start, by: 1)) { t in
                        Text("\(Int(t.date.timeIntervalSince(start)))s").font(.system(size: 10)).foregroundStyle(Palette.ink3)
                    }
                    .help("Scanning storage")
                } else {
                    Button("Rescan storage", systemImage: "arrow.clockwise") { model.scan() }
                        .labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.small)
                        .help(model.scannedAt.map { "Scanned \($0.formatted(.relative(presentation: .named))). Rescan takes about a minute." } ?? "Scan storage")
                }
            }
            .padding(.horizontal, 8).frame(height: 32)
            if model.tree != nil {
                ForEach(shown) { BigRow(item: $0, model: model) }
                if shown.isEmpty { Text("Nothing over 500 MB").font(.system(size: 12)).foregroundStyle(Palette.ink3).padding(24) }
            } else if model.scanStart != nil {
                ProgressView("Scanning storage…").controlSize(.small).frame(maxWidth: .infinity).frame(height: 200)
            } else {
                Button("Find what’s using space", systemImage: "magnifyingglass") { model.scan() }
                    .buttonStyle(.borderless).frame(maxWidth: .infinity).frame(height: 200)
            }
            if !model.fullDiskAccess {
                Button("Allow Full Disk Access for a complete scan…") { NSWorkspace.shared.open(fullDiskAccessSettings) }
                    .buttonStyle(.link).font(.system(size: 11)).padding(.top, 8)
            }
        }
    }
}

struct BigRow: View {
    let item: Big, model: Model
    @State private var hover = false
    @FocusState private var focused: Bool
    @State private var confirmingTrash = false

    var body: some View {
        let name = (item.path as NSString).lastPathComponent
        let place = ((String(item.path.dropFirst(dataRoot.count)) as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
        let age = item.date.map { $0.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)) } ?? ""
        let stale = item.date.map { $0 < Date.now.addingTimeInterval(-180 * 86_400) } ?? false
        HStack(spacing: 9) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: userPath(item.path))).resizable().frame(width: 23, height: 23)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.kind == .app ? String(name.dropLast(4)) : name).lineLimit(1).truncationMode(.middle)
                Text(place).font(.system(size: 10)).foregroundStyle(Palette.ink3).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            ZStack(alignment: .trailing) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(bytes(item.bytes)).monospacedDigit().foregroundStyle(Palette.ink2)
                    Text(age).font(.system(size: 9)).fontWeight(stale ? .semibold : .regular).foregroundStyle(stale ? Palette.ink2 : Palette.ink3)
                }
                .opacity((hover || focused || confirmingTrash) && trashable(item.path) ? 0 : 1)
                if (hover || focused || confirmingTrash) && trashable(item.path) {
                    HStack(spacing: 4) {
                        Button("Show") { reveal(item.path) }.buttonStyle(.bordered).controlSize(.small)
                        ConfirmButton(title: "Trash", confirm: "Sure?") { moveToTrash() }
                    }
                }
            }
            .frame(width: 98, alignment: .trailing)
        }
        .font(.system(size: 12)).frame(height: 44).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(hover || focused || confirmingTrash ? Palette.hover : .clear))
        .contentShape(Rectangle()).focusable(interactions: .activate).focused($focused)  // keyboard focus only: a click shouldn't select the row
        .onHover { hover = $0 }
        .help((String(item.path.dropFirst(dataRoot.count)) as NSString).abbreviatingWithTildeInPath
              + (item.date.map { "\n" + (item.opened ? "Last opened " : "Last changed ") + $0.formatted(date: .abbreviated, time: .omitted) } ?? ""))
        .contextMenu {
            Button("Show in Finder") { reveal(item.path) }
            if trashable(item.path) { Button("Move to Trash") { confirmingTrash = true } }
        }
        .confirmationDialog("Move \(name) to Trash?", isPresented: $confirmingTrash) {
            Button("Move to Trash", role: .destructive) { moveToTrash() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name), \(bytes(item.bytes)), \(age)")
        .accessibilityActions {
            Button("Show in Finder") { reveal(item.path) }
            if trashable(item.path) { Button("Move to Trash") { confirmingTrash = true } }
        }
    }

    func moveToTrash() { if trashable(item.path), !model.trash(item.path) { reveal(item.path) } }
}
