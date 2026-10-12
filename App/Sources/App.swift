import AppKit
import SwiftUI

struct Scenario: Identifiable {
    enum Kind { case plain, cameraControl }
    let id: String
    let title: String
    let symbol: String
    let kind: Kind
    let run: (Guest, String?) throws -> String?
}

private func cc(_ id: String, _ title: String, _ symbol: String, _ arguments: [String]) -> Scenario {
    Scenario(id: id, title: title, symbol: symbol, kind: .cameraControl) { guest, jbroot in
        try guest.ccevent(arguments, jbroot: jbroot ?? "")
        return nil
    }
}

private func plain(_ id: String, _ title: String, _ symbol: String, _ body: @escaping (Guest) throws -> Void) -> Scenario {
    Scenario(id: id, title: title, symbol: symbol, kind: .plain) { guest, _ in try body(guest); return nil }
}

let sections: [(LocalizedStringKey, [Scenario])] = [
    ("Action Button", [
        plain("action-single", "Press", "1.circle") { try $0.actionButton(.single) },
        plain("action-double", "Double press", "2.circle") { try $0.actionButton(.double) },
        plain("action-long", "Long press", "hand.tap") { try $0.actionButton(.long) },
    ]),
    ("Camera Control — full press", [
        cc("cc-click", "Click", "camera", ["click"]),
        cc("cc-double", "Double click", "camera.on.rectangle", ["double"]),
        cc("cc-hold", "Press and hold", "hand.point.up", ["hold"]),
    ]),
    ("Camera Control — light press", [
        cc("cc-light", "Light press", "circle.dotted", ["light"]),
        cc("cc-light-hold", "Light press and hold", "timer", ["light", "3000"]),
        cc("cc-slide-up", "Slide up", "arrow.up", ["slide", "25", "-0.012"]),
        cc("cc-slide-down", "Slide down", "arrow.down", ["slide", "25", "0.012"]),
        cc("cc-menu", "Menu", "list.bullet", ["menu"]),
        cc("cc-menu-up", "Menu, slide up", "chevron.up", ["menu-slide", "6", "-0.05"]),
        cc("cc-menu-down", "Menu, slide down", "chevron.down", ["menu-slide", "6", "0.05"]),
        cc("cc-touch", "Touch only", "hand.raised", ["touch"]),
        cc("cc-swipe", "Swipe without pressing", "arrow.left.and.right", ["swipe"]),
    ]),
    ("System", [
        plain("volume-up", "Volume up", "speaker.plus") { try $0.hid(page: 12, usage: 233) },
        plain("volume-down", "Volume down", "speaker.minus") { try $0.hid(page: 12, usage: 234) },
        plain("play-pause", "Play / Pause", "playpause") { try $0.hid(page: 12, usage: 205) },
        plain("home", "Home", "house") { try $0.home() },
        Scenario(id: "screenshot", title: "Screenshot", symbol: "camera.viewfinder", kind: .plain) { guest, _ in
            let file = try guest.screenshot(to: AppSettings.screenshotFolder)
            return String(format: String(localized: "Saved %@"), file.lastPathComponent)
        },
    ]),
]

enum AppSettings {
    static let libraryKey = "libraryFolder"
    static let screenshotKey = "screenshotFolder"
    static var defaultLibrary: String { NSString(string: "~/.vphone/machines").expandingTildeInPath }
    static var defaultScreenshots: String {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory()
    }
    static var library: URL {
        URL(fileURLWithPath: UserDefaults.standard.string(forKey: libraryKey) ?? defaultLibrary)
    }
    static var screenshotFolder: URL {
        URL(fileURLWithPath: UserDefaults.standard.string(forKey: screenshotKey) ?? defaultScreenshots)
    }
}

@MainActor
final class Controller: ObservableObject {
    @Published var machines: [Machine] = []
    @Published var selected: Machine?
    @Published var cameraControl: CameraControlSupport = .unknown
    @Published var running: Set<String> = []
    @Published var log: [String] = []

    private let queue = DispatchQueue(label: "vphonebuttons.guest")

    func refresh() {
        let library = AppSettings.library
        queue.async {
            let found = Machine.running(in: library)
            DispatchQueue.main.async {
                self.machines = found
                if self.selected == nil || !found.contains(self.selected!) { self.selected = found.first }
                self.checkCameraControl()
            }
        }
    }

    func checkCameraControl() {
        guard let machine = selected else { cameraControl = .unknown; return }
        cameraControl = .unknown
        queue.async {
            let support = Guest(machine).cameraControlSupport()
            DispatchQueue.main.async { if self.selected == machine { self.cameraControl = support } }
        }
    }

    func run(_ scenario: Scenario) {
        guard let machine = selected else { return }
        var jbroot: String?
        if scenario.kind == .cameraControl {
            guard case let .ready(root) = cameraControl else { return }
            jbroot = root
        }
        running.insert(scenario.id)
        let started = Date()
        queue.async {
            let line: String
            do {
                let note = try scenario.run(Guest(machine), jbroot)
                let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
                line = note ?? String(format: String(localized: "%@ — done (%@ s)"), NSLocalizedString(scenario.title, comment: ""), seconds)
            } catch {
                line = String(format: String(localized: "%@ — failed: %@"), NSLocalizedString(scenario.title, comment: ""), error.localizedDescription)
            }
            DispatchQueue.main.async {
                self.running.remove(scenario.id)
                let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                self.log.insert("\(time)  \(line)", at: 0)
                if self.log.count > 50 { self.log.removeLast() }
            }
        }
    }
}

struct MainView: View {
    @StateObject private var controller = Controller()
    private let columns = [GridItem(.adaptive(minimum: 170), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ForEach(sections, id: \.1.first!.id) { title, scenarios in
                Text(title).font(.headline).foregroundStyle(.secondary)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(scenarios) { scenario in
                        Button { controller.run(scenario) } label: {
                            HStack {
                                if controller.running.contains(scenario.id) {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: scenario.symbol)
                                }
                                Text(LocalizedStringKey(scenario.title))
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, minHeight: 26)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(!enabled(scenario))
                    }
                }
                if scenarios.first?.kind == .cameraControl, controller.cameraControl == .missing {
                    Text("Camera Control needs a jailbroken guest with ccevent installed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(controller.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 100)
        }
        .padding(18)
        .frame(minWidth: 600, minHeight: 640)
        .onAppear { controller.refresh() }
    }

    private var header: some View {
        HStack {
            Picker("Machine", selection: $controller.selected) {
                if controller.machines.isEmpty { Text("No running machine").tag(Machine?.none) }
                ForEach(controller.machines) { Text($0.name).tag(Machine?.some($0)) }
            }
            .frame(maxWidth: 320)
            .onChange(of: controller.selected) { controller.checkCameraControl() }
            Button { controller.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            Spacer()
        }
    }

    private func enabled(_ scenario: Scenario) -> Bool {
        guard controller.selected != nil, !controller.running.contains(scenario.id) else { return false }
        if scenario.kind == .cameraControl, case .ready = controller.cameraControl { return true }
        return scenario.kind == .plain
    }
}

struct SettingsView: View {
    @AppStorage(AppSettings.libraryKey) private var library = AppSettings.defaultLibrary
    @AppStorage(AppSettings.screenshotKey) private var screenshots = AppSettings.defaultScreenshots

    var body: some View {
        Form {
            folderRow("Machine library", path: $library)
            folderRow("Screenshots folder", path: $screenshots)
        }
        .padding(20)
        .frame(width: 520)
    }

    private func folderRow(_ title: LocalizedStringKey, path: Binding<String>) -> some View {
        LabeledContent(title) {
            HStack {
                Text(path.wrappedValue).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.directoryURL = URL(fileURLWithPath: path.wrappedValue)
                    if panel.runModal() == .OK, let url = panel.url { path.wrappedValue = url.path }
                }
            }
        }
    }
}

@main
struct VPhoneButtonsApp: App {
    var body: some Scene {
        WindowGroup { MainView() }.windowResizability(.contentSize)
        Settings { SettingsView() }
    }
}
