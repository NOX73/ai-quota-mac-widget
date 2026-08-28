import Foundation
import Network

public enum LocalOAuthServerError: Error, LocalizedError {
    case listenerFailed(String)
    case timeout
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .listenerFailed(let msg): return "Local server error: \(msg)"
        case .timeout: return "Authorization request timed out"
        case .cancelled: return "Authorization cancelled"
        }
    }
}

public final class LocalOAuthServer: @unchecked Sendable {
    private var listener: NWListener?
    private var port: UInt16
    /// Ports to try, in order, if `port` is already taken. These must match redirect URIs the
    /// OAuth client actually has registered with the provider — an arbitrary/random port gets
    /// rejected as an invalid redirect_uri before the user ever sees a login screen, so this list
    /// should stay narrow and explicit rather than a wide scan range.
    private var fallbackPorts: [UInt16]
    private var completionHandler: ((Result<[String: String], Error>) -> Void)?
    /// Invoked once the listener actually reaches `.ready` on some port — callers that need to
    /// embed the port in a redirect_uri must wait for this rather than reading `listeningPort`
    /// right after calling `start()`, since a fallback-port retry happens asynchronously and the
    /// port read synchronously beforehand can be stale.
    private var onReady: ((UInt16) -> Void)?
    private let queue = DispatchQueue(label: "com.claude.quota.oauth-server")

    public init(preferredPort: UInt16 = 54321, fallbackPorts: [UInt16] = []) {
        self.port = preferredPort
        self.fallbackPorts = fallbackPorts
    }

    public var listeningPort: UInt16 {
        return self.port
    }

    public func start(
        timeout: TimeInterval = 180,
        onReady: ((UInt16) -> Void)? = nil,
        completion: @escaping (Result<[String: String], Error>) -> Void
    ) {
        self.completionHandler = completion
        if let onReady {
            self.onReady = onReady
        }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            guard let nwPort = NWEndpoint.Port(rawValue: self.port) else {
                completion(.failure(LocalOAuthServerError.listenerFailed("Invalid port \(self.port)")))
                return
            }

            let listener = try NWListener(using: parameters, on: nwPort)
            self.listener = listener

            listener.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    print("Local OAuth server listening on http://127.0.0.1:\(self.port)")
                    if let onReady = self.onReady {
                        let readyPort = self.port
                        DispatchQueue.main.async {
                            onReady(readyPort)
                        }
                    }
                case .failed(let error):
                    print("Local OAuth server port \(self.port) failed: \(error)")
                    if !self.fallbackPorts.isEmpty {
                        self.stop()
                        self.port = self.fallbackPorts.removeFirst()
                        self.start(timeout: timeout, completion: completion)
                    } else {
                        self.finish(with: .failure(LocalOAuthServerError.listenerFailed(error.localizedDescription)))
                    }
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            listener.start(queue: queue)

            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(with: .failure(LocalOAuthServerError.timeout))
            }

        } catch {
            completion(.failure(LocalOAuthServerError.listenerFailed(error.localizedDescription)))
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func finish(with result: Result<[String: String], Error>) {
        guard let handler = completionHandler else { return }
        completionHandler = nil
        stop()
        DispatchQueue.main.async {
            handler(result)
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)

        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, context, isComplete, error in
            guard let self = self, let data = data, !data.isEmpty else {
                connection.cancel()
                return
            }

            let requestString = String(data: data, encoding: .utf8) ?? ""
            let params = self.parseQueryParams(from: requestString)

            let htmlResponse = """
            HTTP/1.1 200 OK\r
            Content-Type: text/html; charset=utf-8\r
            Connection: close\r
            \r
            <!DOCTYPE html>
            <html>
            <head>
                <meta charset="utf-8">
                <title>Authorization Successful</title>
                <style>
                    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; text-align: center; padding: 60px 20px; background-color: #1a1a1a; color: #ffffff; }
                    .card { background-color: #2a2a2a; border-radius: 12px; padding: 32px; display: inline-block; max-width: 420px; box-shadow: 0 4px 12px rgba(0,0,0,0.3); }
                    .icon { font-size: 48px; color: #4CAF50; margin-bottom: 16px; }
                    h2 { margin: 0 0 12px 0; font-size: 22px; }
                    p { color: #aaaaaa; font-size: 14px; margin: 0 0 20px 0; line-height: 1.5; }
                    .note { font-size: 12px; color: #666666; }
                </style>
            </head>
            <body>
                <div class="card">
                    <div class="icon">✓</div>
                    <h2>Authorization Successful</h2>
                    <p>ClaudeQuota widget has received your authentication token.</p>
                    <p class="note">You can close this tab and return to the application.</p>
                </div>
            </body>
            </html>
            """

            if let responseData = htmlResponse.data(using: .utf8) {
                connection.send(content: responseData, completion: .contentProcessed({ _ in
                    connection.cancel()
                }))
            } else {
                connection.cancel()
            }

            if !params.isEmpty {
                self.finish(with: .success(params))
            }
        }
    }

    private func parseQueryParams(from httpRequest: String) -> [String: String] {
        guard let firstLine = httpRequest.components(separatedBy: "\r\n").first,
              let target = firstLine.components(separatedBy: " ").dropFirst().first,
              let urlComponents = URLComponents(string: target),
              let queryItems = urlComponents.queryItems else {
            return [:]
        }

        var result: [String: String] = [:]
        for item in queryItems {
            if let value = item.value {
                result[item.name] = value
            }
        }
        return result
    }
}

