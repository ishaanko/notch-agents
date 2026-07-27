import Foundation
import Network

final class LocalEventServer: @unchecked Sendable {
    typealias EventHandler = ([String: Any], @escaping ([String: Any]) -> Void) -> Void

    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "app.notchagents.event-server", qos: .userInitiated)
    private var listener: NWListener?
    private let handler: EventHandler
    var onStateChange: ((Bool) -> Void)?

    init(port: UInt16 = 18_989, handler: @escaping EventHandler) {
        self.port = NWEndpoint.Port(rawValue: port)!
        self.handler = handler
    }

    func start() {
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: port)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async { self?.onStateChange?(state == .ready) }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            onStateChange?(false)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        onStateChange?(false)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, complete, error in
            guard let self else { return }
            var next = buffer
            if let data { next.append(data) }
            if let request = HTTPRequest.parse(next) {
                self.handle(request, connection: connection)
            } else if complete || error != nil || next.count > 1_048_576 {
                self.send(["ok": false, "error": "invalid request"], status: "400 Bad Request", on: connection)
            } else {
                self.receive(on: connection, buffer: next)
            }
        }
    }

    private func handle(_ request: HTTPRequest, connection: NWConnection) {
        if request.method == "GET", request.path == "/health" {
            send(["ok": true, "service": "notch-agents", "port": Int(port.rawValue)], on: connection)
            return
        }
        guard request.method == "POST", request.path == "/event",
              let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            send(["ok": false, "error": "not found"], status: "404 Not Found", on: connection)
            return
        }
        handler(object) { [weak self, weak connection] response in
            guard let self, let connection else { return }
            self.queue.async { self.send(response, on: connection) }
        }
    }

    private func send(_ object: [String: Any], status: String = "200 OK", on connection: NWConnection) {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}

private struct HTTPRequest {
    var method: String
    var path: String
    var body: Data

    static func parse(_ data: Data) -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator),
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let pieces = first.split(separator: " ")
        guard pieces.count >= 2 else { return nil }
        let contentLength = lines.first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        return HTTPRequest(
            method: String(pieces[0]),
            path: String(pieces[1]),
            body: data.subdata(in: bodyStart..<(bodyStart + contentLength))
        )
    }
}

