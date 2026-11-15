import Foundation

/// How an app goes into the guest.
enum InstallMode: String, CaseIterable, Identifiable {
    /// .tipa → TrollStore, anything else → App
    case automatic
    /// A normal user app in its own container (sandboxed)
    case app
    /// TrollStore-style: unsandboxed, its entitlements honoured
    case trollStore
    /// Into the jailbreak's Applications folder, registered as a system app
    case jailbreak

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .app: "App"
        case .trollStore: "TrollStore"
        case .jailbreak: "Jailbreak"
        }
    }
}

struct InstallOptions {
    var mode: InstallMode = .automatic
    /// Adds application-identifier and a keychain access group when the app has none
    /// (unsigned Xcode builds), so the keychain works in the guest.
    var keychain = true
    /// Written to the app's preferences before it starts; `key=value`, one per line.
    var preferences = ""
    var launch = true
    var screenshot = false
}

/// Installs an .ipa, .tipa or .app into a running machine through its control socket.
///
/// The socket carries at most about 512 KB per request and cannot append to a file, so a package
/// goes up in parts and a small helper (vpbhelper, shipped in the app) joins them in the guest as a
/// one-shot launchd job. The package is signed ad hoc on the Mac first: the guest's installer
/// accepts ad hoc and other-team signatures, and keeps the entitlements given here.
struct Installer {
    let guest: Guest
    let progress: (String) -> Void

    private var socket: VPhoneSocket { guest.socket }
    private let home = "/var/mobile/Library/VPhoneButtons"
    private static let part = 384 * 1024
    /// Team prefix for apps that come without one (unsigned builds).
    private static let placeholderTeam = "VPHONEBTNS"

    struct Result {
        let bundleID: String
        let mode: InstallMode
        let screenshot: URL?
    }

    func install(_ file: URL, _ options: InstallOptions) throws -> Result {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("vphonebuttons-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // 1. The .app, unpacked
        let payload = work.appendingPathComponent("Payload")
        let ext = file.pathExtension.lowercased()
        switch ext {
        case "app":
            try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
            try run("/usr/bin/ditto", [file.path, payload.appendingPathComponent(file.lastPathComponent).path])
        case "ipa", "tipa":
            try run("/usr/bin/ditto", ["-x", "-k", file.path, work.path])
        default:
            throw Failure("Choose an .ipa, .tipa or .app")
        }
        let apps = (try? FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "app" } ?? []
        guard apps.count == 1, let app = apps.first else { throw Failure("The package must contain exactly one Payload/*.app") }
        let infoURL = app.appendingPathComponent("Info.plist")
        guard var info = NSDictionary(contentsOf: infoURL) as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String
        else { throw Failure("The app has no readable Info.plist") }

        // 2. Mode
        var mode = options.mode
        if mode == .automatic { mode = ext == "tipa" ? .trollStore : .app }
        var jailbreak: (layout: String, jbroot: String)?
        if mode == .jailbreak {
            guard let state = try? socket.rpc("bootstrap.inspect"), state["installed"] as? Bool == true,
                  let jbroot = state["jbroot"] as? String
            else { throw Failure("Jailbreak install needs a jailbroken guest") }
            jailbreak = (state["layout"] as? String ?? "rootless", jbroot)
            // Apps outside a container keep notification permission only with this key.
            if info["SBAppUsesLocalNotifications"] == nil {
                info["SBAppUsesLocalNotifications"] = true
                try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: infoURL)
            }
        }
        progress(String(format: String(localized: "Installing %@ as %@…"), bundleID, String(localized: String.LocalizationValue(mode.title))))

        // 3. Sign ad hoc
        try sign(app, bundleID: bundleID, mode: mode, keychain: options.keychain, work: work)

        // 4. Package and send
        try prepareHelper()
        let package: String
        if let jb = jailbreak {
            let tar = work.appendingPathComponent("app.tar")
            try run("/usr/bin/tar", ["-cf", tar.path, "-C", payload.path, app.lastPathComponent], environment: ["COPYFILE_DISABLE": "1"])
            package = "\(home)/\(UUID().uuidString.prefix(8)).tar"
            try upload(tar, to: package)
            defer { _ = try? socket.rpc("files.remove", ["path": package]) }
            try removeEarlier(bundleID, keeping: .jailbreak)
            let destination = "\(jb.jbroot)/Applications/\(app.lastPathComponent)"
            if (try? socket.rpc("files.list", ["path": destination])) != nil {
                _ = try? socket.rpc("apps.unregister", ["path": destination, "force": true])
                try socket.rpc("files.remove", ["path": destination, "recursive": true])
            }
            // RootHide: programs in the jbroot see the jbroot as / and the real root under /rootfs.
            let roothide = jb.layout == "roothide"
            try job(["\(jb.jbroot)/usr/bin/tar", "-xf", roothide ? "/rootfs" + package : package,
                     "-C", roothide ? "/Applications" : "\(jb.jbroot)/Applications"], name: "tar")
            try socket.rpc("apps.register", ["path": destination], timeout: 120)
        } else {
            let ipa = work.appendingPathComponent(mode == .trollStore ? "app.tipa" : "app.ipa")
            try run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--keepParent", payload.path, ipa.path])
            package = "\(home)/\(UUID().uuidString.prefix(8)).\(ipa.pathExtension)"
            try upload(ipa, to: package)
            defer { _ = try? socket.rpc("files.remove", ["path": package]) }
            try removeEarlier(bundleID, keeping: mode)
            try socket.rpc("apps.install", ["path": package], timeout: 300)
        }

        // 5. Preferences, launch, screenshot
        let preferences = Self.parse(options.preferences)
        if !preferences.isEmpty { try writePreferences(preferences, bundleID: bundleID, sandboxed: mode == .app) }
        var shot: URL?
        if options.launch || options.screenshot {
            try launch(bundleID)
            if options.screenshot {
                Thread.sleep(forTimeInterval: 3)
                shot = try guest.screenshot(to: AppSettings.screenshotFolder)
            }
        }
        return Result(bundleID: bundleID, mode: mode, screenshot: shot)
    }

    // MARK: Signing

    private func sign(_ app: URL, bundleID: String, mode: InstallMode, keychain: Bool, work: URL) throws {
        try run("/usr/bin/xattr", ["-cr", app.path])
        try? FileManager.default.removeItem(at: app.appendingPathComponent("embedded.mobileprovision"))

        var entitlements: [String: Any] = [:]
        if let xml = try? output("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", app.path]), !xml.isEmpty,
           let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any] {
            entitlements = plist
        }
        if keychain {
            let appID = entitlements["application-identifier"] as? String ?? "\(Self.placeholderTeam).\(bundleID)"
            entitlements["application-identifier"] = appID
            let team = String(appID.prefix { $0 != "." })
            var groups = entitlements["keychain-access-groups"] as? [String] ?? []
            if groups.isEmpty { groups = ["\(team).\(bundleID)"] }
            entitlements["keychain-access-groups"] = groups
            if entitlements["com.apple.developer.team-identifier"] == nil { entitlements["com.apple.developer.team-identifier"] = team }
        }
        if mode == .trollStore || mode == .jailbreak {
            entitlements["com.apple.private.security.no-sandbox"] = true
            entitlements["com.apple.private.security.container-required"] = false
        }

        // Nested code first (frameworks, dylibs, extensions), keeping what each declares.
        let nested = (FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { ["framework", "dylib", "appex"].contains($0.pathExtension) }
            .sorted { $0.pathComponents.count > $1.pathComponents.count }
        for item in nested {
            try run("/usr/bin/codesign", ["-f", "-s", "-", "--preserve-metadata=entitlements", item.path])
        }
        let file = work.appendingPathComponent("entitlements.plist")
        try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0).write(to: file)
        try run("/usr/bin/codesign", ["-f", "-s", "-", "--entitlements", file.path, app.path])
    }

    // MARK: Transfer

    /// The helper, sent each time (about 70 KB) so the guest never runs a stale copy.
    private func prepareHelper() throws {
        let beside = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("vpbhelper")
        guard let helper = Bundle.main.url(forResource: "vpbhelper", withExtension: nil)
                ?? beside.flatMap({ FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }) else {
            throw Failure("vpbhelper is missing from the app bundle")
        }
        try socket.rpc("files.mkdir", ["path": home])
        try write(Data(contentsOf: helper), to: "\(home)/vpbhelper")
        try socket.rpc("files.chmod", ["path": "\(home)/vpbhelper", "mode": "755"])
    }

    private func upload(_ file: URL, to path: String) throws {
        let data = try Data(contentsOf: file)
        let total = (data.count + Self.part - 1) / Self.part
        if total <= 1 { try write(data, to: path); return }
        var parts: [String] = []
        for index in 0..<total {
            let start = index * Self.part
            let piece = String(format: "%@.part%05d", path, index)
            try write(data.subdata(in: start..<min(start + Self.part, data.count)), to: piece)
            parts.append(piece)
            if index % 8 == 7 || index == total - 1 {
                progress(String(format: String(localized: "Sending %d%%"), (index + 1) * 100 / total))
            }
        }
        try job(["\(home)/vpbhelper", "join", path] + parts, name: "vpbhelper join")
    }

    private func write(_ data: Data, to path: String) throws {
        try socket.rpc("files.write", ["path": path, "content": data.base64EncodedString(), "encoding": "base64"], timeout: 60)
    }

    /// Runs a program in the guest as a one-shot launchd job and waits for it.
    private func job(_ arguments: [String], name: String, timeout: TimeInterval = 180) throws {
        let label = "com.muratkurt.vphonebuttons.\(UUID().uuidString.prefix(8).lowercased())"
        let plistPath = "\(home)/\(label).plist"
        let xml = try PropertyListSerialization.data(
            fromPropertyList: ["Label": label, "ProgramArguments": arguments, "RunAtLoad": true, "KeepAlive": false],
            format: .xml, options: 0)
        try write(xml, to: plistPath)
        defer {
            _ = try? socket.rpc("services.unload", ["paths": [plistPath], "force": true])
            _ = try? socket.rpc("files.remove", ["path": plistPath])
        }
        try socket.rpc("services.load", ["paths": [plistPath]])
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.3)
            let status = try socket.rpc("services.status", ["label": label])
            if status["running"] as? Bool != true && (status["pid"] as? Int ?? 0) == 0 {
                let code = (status["last_exit_status"] as? Int ?? 0) / 256
                if code != 0 { throw Failure("\(name) exit \(code)") }
                return
            }
        }
        throw Failure("\(name) did not finish")
    }

    // MARK: Guest state

    private func installed(_ bundleID: String) -> [String: Any]? {
        let apps = (try? socket.rpc("apps.list", timeout: 60))?["apps"] as? [[String: Any]] ?? []
        return apps.first { $0["bundle_id"] as? String == bundleID }
    }

    /// The same bundle ID installed the other way (container app vs jailbreak app) is removed first.
    private func removeEarlier(_ bundleID: String, keeping mode: InstallMode) throws {
        guard let app = installed(bundleID) else { return }
        let path = app["bundle_path"] as? String ?? ""
        let isJailbreakApp = path.contains("/.jbroot-") || path.hasPrefix("/var/jb/") || path.hasPrefix("/private/preboot/")
        if (mode == .jailbreak) == isJailbreakApp { return }
        if isJailbreakApp {
            _ = try? socket.rpc("apps.unregister", ["path": path, "force": true])
            _ = try? socket.rpc("files.remove", ["path": path, "recursive": true])
        } else if app["type"] as? String == "user" {
            try socket.rpc("apps.uninstall", ["bundle_id": bundleID, "force": true], timeout: 120)
        }
        progress(String(format: String(localized: "Removed the earlier install of %@"), bundleID))
    }

    /// A sandboxed app reads its container's Library/Preferences; an unsandboxed one (TrollStore, jailbreak) the shared one.
    private func writePreferences(_ values: [String: Any], bundleID: String, sandboxed: Bool) throws {
        _ = try? socket.rpc("apps.terminate", ["bundle_id": bundleID])
        // cfprefsd keeps the app's preferences in memory and would hand out the old values (or write
        // them back over ours): stopped first, it saves what it holds; launchd starts it again on demand.
        try job(["\(home)/vpbhelper", "kill", "cfprefsd"], name: "vpbhelper kill")
        let container = sandboxed ? installed(bundleID)?["data_path"] as? String : nil
        let data = container.map { "\($0)/Library/Preferences" } ?? "/var/mobile/Library/Preferences"
        let path = "\(data)/\(bundleID).plist"
        var plist: [String: Any] = [:]
        if let read = try? socket.rpc("files.read", ["path": path, "encoding": "base64", "limit": 4_000_000]),
           let text = read["content"] as? String, let raw = Data(base64Encoded: text),
           let old = try? PropertyListSerialization.propertyList(from: raw, format: nil) as? [String: Any] {
            plist = old
        }
        plist.merge(values) { $1 }
        try socket.rpc("files.mkdir", ["path": data])
        try write(PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0), to: path)
        if container != nil {
            try socket.rpc("files.chown", ["path": data, "owner": "501:501", "recursive": true])
        } else {
            try socket.rpc("files.chown", ["path": path, "owner": "501:501"])
        }
    }

    private func launch(_ bundleID: String) throws {
        do {
            try socket.rpc("apps.launch", ["bundle_id": bundleID, "terminate_existing": true])
        } catch {
            guard error.localizedDescription.contains("locked") else { throw error }
            try guest.unlock()
            try socket.rpc("apps.launch", ["bundle_id": bundleID, "terminate_existing": true])
        }
    }

    /// `key=value` lines; true / false become booleans, whole numbers integers, the rest strings.
    static func parse(_ text: String) -> [String: Any] {
        var values: [String: Any] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty else { continue }
            let value = parts[1]
            if value == "true" || value == "false" { values[parts[0]] = value == "true" }
            else if let number = Int(value) { values[parts[0]] = number }
            else { values[parts[0]] = value }
        }
        return values
    }

    // MARK: Mac processes

    @discardableResult
    private func run(_ tool: String, _ arguments: [String], environment: [String: String] = [:]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if !environment.isEmpty { process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 } }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let message = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure("\((tool as NSString).lastPathComponent): \(text.isEmpty ? "exit \(process.terminationStatus)" : text)")
        }
        return data
    }

    private func output(_ tool: String, _ arguments: [String]) throws -> Data { try run(tool, arguments) }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { NSLocalizedString(message, comment: "") }
    }
}
