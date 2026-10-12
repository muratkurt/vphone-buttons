import Foundation

/// A running vphone machine's control socket, `<machine>/vphone.sock`.
/// One JSON request per line, one JSON reply per line. Needs no API token and
/// works for machines started from vphone-launchpad or `vphone-cli vm launch`.
struct VPhoneSocket {
    let path: String

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func send(_ request: [String: Any], timeout: TimeInterval = 30) throws -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(message: "socket: \(String(cString: strerror(errno)))") }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { throw Failure(message: "socket path too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw Failure(message: "connect: \(String(cString: strerror(errno)))") }

        var wait = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(0x0A)
        try data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = write(fd, raw.baseAddress! + sent, raw.count - sent)
                if n <= 0 { throw Failure(message: "write: \(String(cString: strerror(errno)))") }
                sent += n
            }
        }

        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while !reply.contains(0x0A) {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { throw Failure(message: "no reply from the machine") }
            reply.append(chunk, count: n)
        }
        let line = reply.prefix(upTo: reply.firstIndex(of: 0x0A)!)
        guard let json = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw Failure(message: "reply is not JSON")
        }
        if json["ok"] as? Bool == false {
            throw Failure(message: json["error"] as? String ?? "request failed")
        }
        return json
    }

    /// A vphoned method; returns its `result`.
    @discardableResult
    func rpc(_ method: String, _ params: [String: Any] = [:], timeout: TimeInterval = 30) throws -> [String: Any] {
        let reply = try send(["t": "rpc", "method": method, "params": params, "screen": false], timeout: timeout)
        return reply["result"] as? [String: Any] ?? [:]
    }

    func ping() -> Bool {
        (try? send(["t": "ping", "screen": false], timeout: 3))?["ok"] as? Bool == true
    }
}
