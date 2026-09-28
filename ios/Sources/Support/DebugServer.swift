import Foundation
import Network

/// Wireless debugging: a tiny HTTP server on the phone's Wi-Fi address.
///
/// Off by default (Settings > Wireless debug) because the log holds
/// scan details. Every request needs the per-phone token shown in the
/// Debug screen. Open http://<phone-ip>:8765/?t=<token> in a browser on the
/// same Wi-Fi, or run tools/phone_log.py wifi <phone-ip> <token>.
///   /            live log page (polls /tail)
///   /status      JSON snapshot: scan state and settings
///   /tail?after= JSON {last, lines} for live following
///   /logs        JSON list of log files
///   /log/<name>  a whole log file as text
final class DebugServer {
    static let shared = DebugServer()
    static let port: UInt16 = 8765

    private let queue = DispatchQueue(label: "DebugServer")
    private var listener: NWListener?
    private let lock = NSLock()
    private var snapshot: [String: Any] = [:]

    private(set) var isRunning = false

    var token: String {
        let d = UserDefaults.standard
        if let t = d.string(forKey: SettingsKey.debugToken), t.count >= 6 { return t }
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        let t = String((0..<8).map { _ in alphabet.randomElement()! })
        d.set(t, forKey: SettingsKey.debugToken)
        return t
    }

    var url: String? {
        guard let ip = DebugServer.wifiAddress() else { return nil }
        return "http://\(ip):\(DebugServer.port)/?t=\(token)"
    }

    func updateStatus(_ values: [String: Any]) {
        lock.lock()
        for (k, v) in values { snapshot[k] = v }
        lock.unlock()
    }

    func start() {
        queue.async {
            guard self.listener == nil else { return }
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: DebugServer.port)!)
                l.newConnectionHandler = { [weak self] c in self?.accept(c) }
                l.stateUpdateHandler = { state in
                    switch state {
                    case .ready: LogStore.shared.write("wireless debug listening on port \(DebugServer.port)", category: "debug")
                    case .failed(let e): LogStore.shared.write("wireless debug failed: \(e)", category: "debug")
                    default: break
                    }
                }
                l.start(queue: self.queue)
                self.listener = l
                self.isRunning = true
            } catch {
                LogStore.shared.write("wireless debug could not start: \(error)", category: "debug")
            }
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            self.isRunning = false
        }
    }

    // MARK: - HTTP

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
                self.respond(c, head: head)
            } else if done || error != nil || buf.count > 32_768 {
                c.cancel()
            } else {
                self.receive(c, buffer: buf)
            }
        }
    }

    private func respond(_ c: NWConnection, head: String) {
        let parts = (head.components(separatedBy: "\r\n").first ?? "").split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", let comps = URLComponents(string: String(parts[1])) else {
            return send(c, 400, "text/plain", "bad request")
        }
        let query = Dictionary((comps.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard query["t"] == token else {
            return send(c, 403, "text/plain", "missing or wrong token (see the Debug screen in the app)")
        }
        let path = comps.path
        switch path {
        case "/":
            send(c, 200, "text/html; charset=utf-8", DebugServer.page)
        case "/status":
            lock.lock()
            var s = snapshot
            lock.unlock()
            s["serverTime"] = ISO8601DateFormatter().string(from: Date())
            sendJSON(c, s)
        case "/tail":
            let after = Int(query["after"] ?? "") ?? 0
            let t = LogStore.shared.tail(after: after)
            sendJSON(c, ["last": t.last, "lines": t.lines])
        case "/logs":
            sendJSON(c, ["files": LogStore.shared.files().map { $0.lastPathComponent }])
        default:
            if path.hasPrefix("/log/"), let text = LogStore.shared.read(String(path.dropFirst(5))) {
                send(c, 200, "text/plain; charset=utf-8", text)
            } else {
                send(c, 404, "text/plain", "not found")
            }
        }
    }

    private func sendJSON(_ c: NWConnection, _ obj: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .prettyPrinted])) ?? Data("{}".utf8)
        send(c, 200, "application/json", String(decoding: data, as: UTF8.self))
    }

    private func send(_ c: NWConnection, _ code: Int, _ type: String, _ body: String) {
        let payload = Data(body.utf8)
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found"][code] ?? "OK"
        let header = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(payload.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        c.send(content: Data(header.utf8) + payload, completion: .contentProcessed { _ in c.cancel() })
    }

    // MARK: - helpers

    /// IPv4 address of the Wi-Fi interface (en0).
    static func wifiAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: ifa.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }

    private static let page = """
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Mapper log</title>
    <style>body{font:13px ui-monospace,Menlo,Consolas,monospace;margin:0;background:#111;color:#ddd}
    header{position:sticky;top:0;background:#222;padding:8px 12px}a{color:#8cf}pre{margin:0;padding:12px;white-space:pre-wrap}
    #st{color:#9c9;white-space:pre-wrap}</style></head><body>
    <header>Mapper live log &middot; <a id="files" href="#">files</a> &middot; <a id="stl" href="#">status</a><div id="st"></div></header>
    <pre id="log"></pre><script>
    const t=new URLSearchParams(location.search).get('t');let last=0;
    const q=p=>fetch(p+(p.includes('?')?'&':'?')+'t='+t).then(r=>r.json());
    async function poll(){try{const r=await q('/tail?after='+last);if(r.lines.length){const el=document.getElementById('log');
    const atEnd=innerHeight+scrollY>=document.body.scrollHeight-40;el.textContent+=r.lines.join('\\n')+'\\n';
    if(atEnd)scrollTo(0,document.body.scrollHeight)}last=r.last}catch(e){}setTimeout(poll,1000)}
    async function status(){try{const s=await q('/status');document.getElementById('st').textContent=
    `${s.status||''}`}catch(e){}setTimeout(status,2000)}
    document.getElementById('files').onclick=async e=>{e.preventDefault();const r=await q('/logs');
    document.getElementById('log').innerHTML=r.files.map(f=>`<a href="/log/${f}?t=${t}">${f}</a>`).join('\\n')};
    document.getElementById('stl').onclick=e=>{e.preventDefault();location.href='/status?t='+t};
    poll();status();</script></body></html>
    """
}
