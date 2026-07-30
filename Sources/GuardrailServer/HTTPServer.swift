// Copyright (c) 2026 Tommy Stellmacher
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Minimaler HTTP/1.1-Server auf POSIX-Sockets
//
// Gleiche Bauart wie im AIGateway, gleiche bewusste Luecken:
//
// - **Kein TLS.** Ein handgeschriebener TLS-Stack waere das groesste Risiko im
//   ganzen Baustein. Gebunden wird per Default auf Loopback; Terminierung
//   uebernimmt ein Reverse Proxy davor.
// - **Kein Keep-Alive.** Eine Anfrage je Verbindung. Der Durchsatz einer
//   Pruefkette haengt an den Regexen, nicht am Socket.
// - **Kein chunked Request-Body.** Nur `Content-Length`.
//
// Der Dienst prueft Ausgaenge — er bekommt also potenziell genau die Daten zu
// sehen, die nicht abfliessen sollen. Deshalb ist Loopback der Default und
// nicht bloss eine Empfehlung.

public struct HTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data

    /// Oeffentlich, damit die Routing-Schicht ohne Socket geprueft werden kann —
    /// sonst waere der Weg Anfrage → Bericht nur mit echten Verbindungen
    /// erreichbar und bliebe deshalb ungetestet.
    public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

public enum GuardrailServerError: Error, CustomStringConvertible {
    case socket(String)

    public var description: String {
        switch self {
        case .socket(let detail): return "Server konnte nicht starten: \(detail)"
        }
    }
}

/// Uebergabe zwischen dem async-Handler und dem synchronen Verbindungs-Thread.
/// Der Zugriff ist durch das Semaphor geordnet — geschrieben wird genau einmal,
/// gelesen erst danach.
private final class ResponseBox: @unchecked Sendable {
    var result: (status: Int, body: Data)?
}

public final class HTTPServer: @unchecked Sendable {

    public typealias Handler = @Sendable (HTTPRequest) async -> (status: Int, body: Data)

    private let port: UInt16
    private let loopbackOnly: Bool
    private let maxBodyBytes: Int
    /// Ohne Lese-Timeout haelt ein Client, der den Rumpf nie zu Ende sendet,
    /// seinen Verbindungs-Thread unbegrenzt.
    private let readTimeoutSeconds: Int
    /// Thread je Verbindung ohne Deckel hiesse: N langsame Clients binden N
    /// Threads. Darueber wird sofort mit 503 abgewiesen.
    private let maxConcurrentConnections: Int
    private let handler: Handler

    private var listenFD: Int32 = -1
    private var running = false
    private var actualPort: UInt16 = 0

    /// Der Port, auf dem tatsaechlich gelauscht wird.
    ///
    /// Weicht von `port` ab, wenn 0 uebergeben wurde — dann sucht das System
    /// einen freien. Genau das braucht ein Test, der die Socket-Schicht wirklich
    /// anspricht, statt nur den Handler aufzurufen; ohne diese Auskunft blieb
    /// die Parser- und Annahme-Schicht unpruefbar.
    public var boundPort: UInt16 {
        stateLock.lock(); defer { stateLock.unlock() }
        return actualPort
    }
    private var activeConnections = 0
    private let stateLock = NSLock()

    public init(port: UInt16 = 8790, loopbackOnly: Bool = true,
                maxBodyBytes: Int = 1_000_000, readTimeoutSeconds: Int = 30,
                maxConcurrentConnections: Int = 64,
                handler: @escaping Handler) {
        self.port = port
        self.loopbackOnly = loopbackOnly
        self.maxBodyBytes = maxBodyBytes
        self.readTimeoutSeconds = readTimeoutSeconds
        self.maxConcurrentConnections = maxConcurrentConnections
        self.handler = handler
    }

    public func start() throws {
        // Ein geschlossener Socket der Gegenseite darf den Prozess nicht toeten.
        signal(SIGPIPE, SIG_IGN)

        #if canImport(Darwin)
        let streamType = SOCK_STREAM
        #else
        let streamType = Int32(SOCK_STREAM.rawValue)
        #endif
        let fd = socket(AF_INET, streamType, 0)
        guard fd >= 0 else { throw GuardrailServerError.socket("socket() fehlgeschlagen") }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        #if canImport(Darwin)
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        #endif

        var addr = sockaddr_in()
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: loopbackOnly ? inet_addr("127.0.0.1") : in_addr_t(0))

        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            throw GuardrailServerError.socket("bind() auf Port \(port) fehlgeschlagen (errno \(errno))")
        }
        guard listen(fd, 64) == 0 else {
            close(fd)
            throw GuardrailServerError.socket("listen() fehlgeschlagen (errno \(errno))")
        }

        // Bei Port 0 vergibt das System einen freien — den muss der Aufrufer
        // erfahren koennen.
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let queried = withUnsafeMutablePointer(to: &local) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length) == 0
            }
        }
        let resolved: UInt16 = queried ? local.sin_port.bigEndian : port

        stateLock.lock()
        listenFD = fd
        running = true
        actualPort = resolved
        stateLock.unlock()
        // Bewusst STARK gehalten: ein lauschender Server, den niemand mehr
        // referenziert, waere sonst sofort weg — der Socket laege gebunden da
        // und keine Verbindung wuerde je angenommen. Die Schleife endet mit
        // `stop()`, danach loest sich der Zyklus auf.
        Thread.detachNewThread { self.acceptLoop() }
    }

    public func stop() {
        running = false
        if listenFD >= 0 {
            shutdown(listenFD, Int32(SHUT_RDWR))
            close(listenFD)
            listenFD = -1
        }
    }

    // MARK: - Annahme

    private func acceptLoop() {
        while running {
            var clientAddr = sockaddr()
            var length = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(listenFD, &clientAddr, &length)
            guard client >= 0 else {
                if running { continue } else { return }
            }

            stateLock.lock()
            let overloaded = activeConnections >= maxConcurrentConnections
            if !overloaded { activeConnections += 1 }
            stateLock.unlock()

            if overloaded {
                Self.write(client, status: 503, body: Data(#"{"error":"server overloaded"}"#.utf8))
                shutdown(client, Int32(SHUT_RDWR))
                close(client)
                continue
            }

            Thread.detachNewThread {
                self.serve(client)
                self.stateLock.lock()
                self.activeConnections -= 1
                self.stateLock.unlock()
            }
        }
    }

    private func serve(_ fd: Int32) {
        defer {
            shutdown(fd, Int32(SHUT_RDWR))
            close(fd)
        }
        // SO_RCVTIMEO begrenzt nur das EINZELNE read(). Ein Client, der alle
        // paar Sekunden ein Byte schickt, haelt seinen Thread damit beliebig
        // lange — bei 64 Verbindungen genuegen 64 solcher Clients, um den
        // Dienst stillzulegen. Deshalb zusaetzlich eine absolute Frist fuer die
        // ganze Anfrage; das kurze Socket-Timeout sorgt nur dafuer, dass read()
        // regelmaessig zurueckkommt und die Frist ueberhaupt geprueft wird.
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        // Auch die Schreibseite darf nicht unbegrenzt haengen (langsamer Leser).
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let deadline = Date().addingTimeInterval(TimeInterval(readTimeoutSeconds))
        let outcome = readRequest(fd, deadline: deadline)
        guard case .ok(let request) = outcome else {
            let status = outcome.status
            Self.write(fd, status: status, body: Data("{\"error\":\"\(outcome.reason)\"}".utf8))
            return
        }

        // Die Annahme-Schleife laeuft synchron; der Handler ist async. Ein
        // Semaphor ist hier ehrlicher als ein Task, der ins Leere laeuft.
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        Task { [handler] in
            box.result = await handler(request)
            semaphore.signal()
        }
        semaphore.wait()
        let result = box.result ?? (500, Data(#"{"error":"no response"}"#.utf8))
        Self.write(fd, status: result.status, body: result.body)
    }

    /// Ergebnis des Einlesens — mit dem Statuscode, der zur Ursache passt.
    enum ReadOutcome {
        case ok(HTTPRequest)
        case malformed(String)
        case tooLarge
        case timedOut

        var status: Int {
            switch self {
            case .ok: return 200
            case .malformed: return 400
            case .tooLarge: return 413
            case .timedOut: return 408
            }
        }

        var reason: String {
            switch self {
            case .ok: return "ok"
            case .malformed(let detail): return "malformed request: \(detail)"
            case .tooLarge: return "payload too large"
            case .timedOut: return "request timeout"
            }
        }
    }

    func readRequest(_ fd: Int32, deadline: Date) -> ReadOutcome {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)

        /// Liest einmal nach; unterscheidet Frist, Abbruch und Fortschritt.
        func readMore() -> ReadOutcome? {
            if Date() >= deadline { return .timedOut }
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                return nil
            }
            // n == -1 mit EAGAIN/EWOULDBLOCK ist der Timeout des Sockets: die
            // Frist ist noch nicht um, also weiterlesen.
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                return Date() >= deadline ? .timedOut : nil
            }
            return .malformed("connection closed")
        }

        // Kopf lesen, bis die Leerzeile kommt — mit Obergrenze, damit ein Client
        // nicht endlos Header schicken kann.
        while buffer.range(of: Data("\r\n\r\n".utf8)) == nil {
            if buffer.count > 64 * 1024 { return .malformed("header too large") }
            if let stop = readMore() { return stop }
        }
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: buffer[buffer.startIndex..<separator.lowerBound], encoding: .utf8)
        else { return .malformed("undecodable header") }

        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.components(separatedBy: " ") ?? []
        guard requestLine.count >= 2 else { return .malformed("request line") }

        var headers: [String: String] = [:]
        var seen = Set<String>()
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // Ein zweites Content-Length ist die klassische Schmuggel-Vorlage:
            // zwei Vermittler lesen unterschiedliche Laengen und zerlegen den
            // Strom verschieden. Hier gibt es dazu keine Meinung, sondern 400.
            if key == "content-length", !seen.insert(key).inserted, headers[key] != value {
                return .malformed("conflicting content-length")
            }
            headers[key] = value
        }

        // Transfer-Encoding wird nicht unterstuetzt. Es still zu ignorieren und
        // stattdessen Content-Length zu glauben, ist genau der Schmuggelpfad.
        if headers["transfer-encoding"] != nil {
            return .malformed("transfer-encoding not supported")
        }

        var body = Data(buffer[separator.upperBound...])
        let expected: Int
        if let raw = headers["content-length"] {
            // Fail-closed: ein unlesbares Content-Length wurde frueher zu 0, und
            // der Dienst urteilte dann ueber einen leeren Ausgang, als waere er
            // geprueft worden.
            guard let parsed = Int(raw), parsed >= 0 else {
                return .malformed("content-length")
            }
            expected = parsed
        } else if requestLine[0] == "POST" || requestLine[0] == "PUT" {
            return .malformed("content-length required")
        } else {
            expected = 0
        }
        if expected > maxBodyBytes { return .tooLarge }

        while body.count < expected {
            if let stop = readMore() { return stop }
            body = Data(buffer[separator.upperBound...])
        }
        // Nie mehr weitergeben als angekuendigt — der Ueberhang gehoert zur
        // naechsten Anfrage und darf nicht in diese hineinlaufen.
        if body.count > expected { body = body.prefix(expected) }

        return .ok(HTTPRequest(method: requestLine[0], path: requestLine[1],
                               headers: headers, body: body))
    }

    // MARK: - Antwort

    private static func write(_ fd: Int32, status: Int, body: Data) {
        var head = "HTTP/1.1 \(status) \(reason(status))\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        _ = writeAll(fd, Data(head.utf8))
        _ = writeAll(fd, body)
    }

    @discardableResult
    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var ok = true
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                #if canImport(Darwin)
                let n = Darwin.write(fd, base.advanced(by: sent), raw.count - sent)
                #else
                let n = send(fd, base.advanced(by: sent), raw.count - sent, Int32(MSG_NOSIGNAL))
                #endif
                if n <= 0 { ok = false; return }
                sent += n
            }
        }
        return ok
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 503: return "Service Unavailable"
        default: return "Error"
        }
    }
}
