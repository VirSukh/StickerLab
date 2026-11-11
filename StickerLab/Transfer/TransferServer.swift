import Foundation
import Network
import UIKit

// MARK: - Minimal HTTP over Network.framework

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let body: Data
}

struct HTTPResponse {
    var status = 200
    var contentType = "application/json; charset=utf-8"
    var body: Data

    static func json(_ object: [String: Any], status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8))
    }

    static func jsonArray(_ array: [[String: Any]]) -> HTTPResponse {
        HTTPResponse(body: (try? JSONSerialization.data(withJSONObject: array)) ?? Data("[]".utf8))
    }

    static func html(_ text: String) -> HTTPResponse {
        HTTPResponse(contentType: "text/html; charset=utf-8", body: Data(text.utf8))
    }
}

/// One HTTP request per connection (Connection: close), body read via Content-Length.
final class HTTPConnection {
    static let maxBody = 200 * 1024 * 1024

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: (HTTPRequest) async -> HTTPResponse
    private var buffer = Data()

    init(connection: NWConnection, queue: DispatchQueue, handler: @escaping (HTTPRequest) async -> HTTPResponse) {
        self.connection = connection
        self.queue = queue
        self.handler = handler
    }

    func start() {
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [self] data, _, isComplete, error in
            if let data { buffer.append(data) }
            switch parse() {
            case .some(.success(let request)):
                Task {
                    let response = await handler(request)
                    send(response)
                }
            case .some(.failure(let error)):
                send(error.response)
            case .none:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    receive()
                }
            }
        }
    }

    /// nil = need more bytes.
    private func parse() -> Result<HTTPRequest, HTTPResponseError>? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > 64 * 1024 ? .failure(HTTPResponseError(.json(["ok": false], status: 431))) : nil
        }
        let head = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .failure(HTTPResponseError(.json(["ok": false], status: 400))) }

        var length = 0
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                length = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        guard length <= Self.maxBody else {
            return .failure(HTTPResponseError(.json(["ok": false, "message": "File troppo grande (max 200 MB)."], status: 413)))
        }
        let bodyStart = headerEnd.upperBound
        guard buffer.endIndex - bodyStart >= length else { return nil }

        let target = String(requestLine[1])
        let components = URLComponents(string: "http://local" + target)
        var query: [String: String] = [:]
        components?.queryItems?.forEach { query[$0.name] = $0.value ?? "" }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + length))
        return .success(HTTPRequest(method: String(requestLine[0]), path: components?.path ?? target, query: query, body: body))
    }

    private func send(_ response: HTTPResponse) {
        let reason = response.status == 200 ? "OK" : "Error"
        let head = "HTTP/1.1 \(response.status) \(reason)\r\n"
            + "Content-Type: \(response.contentType)\r\n"
            + "Content-Length: \(response.body.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
    }
}

struct HTTPResponseError: Error {
    let response: HTTPResponse
    init(_ response: HTTPResponse) { self.response = response }
}

// MARK: - Transfer server

/// "Ricevi dal PC": a web page on the local Wi-Fi to drop GIFs / images / videos straight into a pack.
@MainActor
final class TransferServer: ObservableObject {
    @Published private(set) var address: String?
    @Published private(set) var errorText: String?
    @Published private(set) var received = 0
    @Published private(set) var events: [String] = []

    private var listener: NWListener?
    private weak var store: PackStore?
    private let queue = DispatchQueue(label: "stickerlab.transfer")
    private let ports: [UInt16] = [8080, 8081, 8088, 8888, 9090]

    func start(store: PackStore) {
        self.store = store
        guard listener == nil else { return }
        guard let ip = Self.localIPAddress() else {
            errorText = "Non sei connesso a una rete Wi-Fi. Collega iPhone e PC alla stessa rete."
            return
        }
        listen(ip: ip, portIndex: 0)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        address = nil
    }

    private func listen(ip: String, portIndex: Int) {
        guard portIndex < ports.count, let port = NWEndpoint.Port(rawValue: ports[portIndex]) else {
            errorText = "Impossibile avviare il server: tutte le porte sono occupate."
            return
        }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                HTTPConnection(connection: connection, queue: self?.queue ?? .global()) { request in
                    guard let self else { return .json(["ok": false], status: 503) }
                    return await self.handle(request)
                }.start()
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.address = "http://\(ip):\(port.rawValue)"
                        self.errorText = nil
                    case .failed:
                        self.listener?.cancel()
                        self.listener = nil
                        self.listen(ip: ip, portIndex: portIndex + 1)
                    default:
                        break
                    }
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            listen(ip: ip, portIndex: portIndex + 1)
        }
    }

    private func log(_ text: String) {
        events.insert(text, at: 0)
        if events.count > 40 { events.removeLast() }
    }

    // MARK: Routes

    private func handle(_ request: HTTPRequest) async -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            return .html(TransferPage.html)
        case ("GET", "/api/packs"):
            return packsResponse()
        case ("POST", "/api/packs"):
            return createPack(request)
        case ("POST", "/api/upload"):
            return await upload(request)
        default:
            return .json(["ok": false, "message": "Non trovato"], status: 404)
        }
    }

    private func packsResponse() -> HTTPResponse {
        let packs = store?.packs ?? []
        return .jsonArray(packs.map {
            [
                "id": $0.id.uuidString,
                "name": $0.name,
                "count": $0.stickers.count,
                "max": StickerPack.maxStickers,
                "animated": $0.animated,
            ]
        })
    }

    private func createPack(_ request: HTTPRequest) -> HTTPResponse {
        guard let store else { return .json(["ok": false, "message": "App non pronta"], status: 503) }
        let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        let name = (json["name"] as? String)?.trimmed ?? ""
        let animated = json["animated"] as? Bool ?? false
        let publisher = UserDefaults.standard.string(forKey: "defaultPublisher") ?? ""
        let pack = store.createPack(name: name.isEmpty ? "Dal PC" : name, publisher: publisher, animated: animated)
        log("Creato il pacchetto \(pack.name)")
        return .json(["ok": true, "id": pack.id.uuidString, "name": pack.name])
    }

    private func upload(_ request: HTTPRequest) async -> HTTPResponse {
        guard let store else { return .json(["ok": false, "message": "App non pronta"], status: 503) }
        let fileName = request.query["filename"] ?? "file"
        guard let packID = UUID(uuidString: request.query["pack"] ?? ""), var pack = store.pack(id: packID) else {
            return .json(["ok": false, "message": "Pacchetto non trovato"])
        }
        guard !request.body.isEmpty else { return .json(["ok": false, "message": "File vuoto"]) }

        // Full pack: continue in a new one with the same type.
        if pack.isFull {
            pack = store.createPack(name: "\(pack.name) 2", publisher: pack.publisher, animated: pack.animated)
            log("Pacchetto pieno: continuo in \(pack.name)")
        }
        do {
            let file = try Downloader.store(request.body)
            let item = ImportItem(fileURL: file, sourceURL: nil, name: fileName)
            let data = try await StickerPipeline.makeDefaultSticker(from: item, animated: pack.animated)
            let emojis = EmojiParser.parse(UserDefaults.standard.string(forKey: "defaultEmoji") ?? "😀")
            try store.addSticker(data: data, animated: pack.animated, emojis: emojis, source: nil, to: pack.id)
            try? FileManager.default.removeItem(at: file)
            received += 1
            let count = store.pack(id: pack.id)?.stickers.count ?? 0
            log("✓ \(fileName) → \(pack.name) (\(count)/\(StickerPack.maxStickers))")
            return .json([
                "ok": true,
                "message": "Aggiunto a \(pack.name) (\(count)/\(StickerPack.maxStickers))",
                "packId": pack.id.uuidString,
            ])
        } catch {
            log("✗ \(fileName): \(error.localizedDescription)")
            return .json(["ok": false, "message": error.localizedDescription, "packId": pack.id.uuidString])
        }
    }

    // MARK: Network address

    /// IPv4 address on Wi-Fi (en0) or the iPhone hotspot (bridge100).
    static func localIPAddress() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        var candidates: [String: String] = [:]
        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = interface.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                candidates[name] = String(cString: host)
            }
        }
        return candidates["en0"] ?? candidates["bridge100"] ?? candidates.values.first
    }
}
