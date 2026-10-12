import Foundation

/// A machine folder with a live control socket.
struct Machine: Identifiable, Hashable {
    let name: String
    let socketPath: String
    var id: String { socketPath }

    /// Machines under `library` that answer on `vphone.sock`.
    static func running(in library: URL) -> [Machine] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: library, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return folders
            .map { Machine(name: $0.lastPathComponent, socketPath: $0.appendingPathComponent("vphone.sock").path) }
            .filter { FileManager.default.fileExists(atPath: $0.socketPath) && VPhoneSocket(path: $0.socketPath).ping() }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// What the guest offers for Camera Control.
enum CameraControlSupport: Equatable {
    case unknown
    case ready(jbroot: String)
    case missing
}

/// Button presses sent to one machine.
struct Guest {
    let socket: VPhoneSocket

    init(_ machine: Machine) { socket = VPhoneSocket(path: machine.socketPath) }

    // MARK: Buttons vphoned already knows

    func hid(page: Int, usage: Int, down: Bool? = nil) throws {
        var params: [String: Any] = ["page": page, "usage": usage]
        if let down { params["down"] = down }
        try socket.rpc("input.hid", params)
    }

    func actionButton(_ kind: Press) throws {
        switch kind {
        case .single: try hid(page: 11, usage: 45)
        case .double:
            try hid(page: 11, usage: 45)
            Thread.sleep(forTimeInterval: 0.12)
            try hid(page: 11, usage: 45)
        case .long:
            try hid(page: 11, usage: 45, down: true)
            Thread.sleep(forTimeInterval: 1.2)
            try hid(page: 11, usage: 45, down: false)
        }
    }

    func home() throws { try socket.rpc("input.button", ["name": "home"]) }

    /// Full-resolution screenshot written by the VM process on the Mac.
    func screenshot(to folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime])
        let file = folder.appendingPathComponent("vphone-\(stamp).png")
        _ = try socket.send(["t": "screenshot", "path": file.path, "screen": false])
        return file
    }

    // MARK: Camera Control through ccevent

    func cameraControlSupport() -> CameraControlSupport {
        guard let state = try? socket.rpc("bootstrap.inspect"),
              state["installed"] as? Bool == true,
              let jbroot = state["jbroot"] as? String
        else { return .missing }
        guard let list = try? socket.rpc("files.list", ["path": jbroot + "/usr/local/bin"]),
              let entries = list["entries"] as? [[String: Any]],
              entries.contains(where: { $0["name"] as? String == "ccevent" })
        else { return .missing }
        return .ready(jbroot: jbroot)
    }

    /// Runs `ccevent <arguments>` in the guest as a one-shot launchd job and
    /// waits for it to exit. vphoned has no exec call; a job is how a host
    /// runs a program there.
    func ccevent(_ arguments: [String], jbroot: String) throws {
        let label = "com.muratkurt.vphonebuttons.\(UUID().uuidString.prefix(8).lowercased())"
        let plistPath = "\(jbroot)/Library/LaunchDaemons/\(label).plist"
        let job: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["\(jbroot)/usr/local/bin/ccevent"] + arguments,
            "RunAtLoad": true,
            "KeepAlive": false,
        ]
        let xml = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
        try socket.rpc("files.write", ["path": plistPath, "content": String(decoding: xml, as: UTF8.self)])
        // A job left behind would run again at every boot, so it always goes.
        defer {
            _ = try? socket.rpc("services.unload", ["paths": [plistPath], "force": true])
            _ = try? socket.rpc("files.remove", ["path": plistPath])
        }
        try socket.rpc("services.load", ["paths": [plistPath]])
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            let status = try socket.rpc("services.status", ["label": label])
            let pid = status["pid"] as? Int ?? 0
            if status["running"] as? Bool != true && pid == 0 {
                let code = (status["last_exit_status"] as? Int ?? 0) / 256
                if code != 0 { throw VPhoneSocket.Failure(message: "ccevent exit \(code)") }
                return
            }
        }
        throw VPhoneSocket.Failure(message: "ccevent did not finish")
    }
}

enum Press { case single, double, long }
