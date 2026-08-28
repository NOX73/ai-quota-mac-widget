import Foundation
import CryptoKit
import AppKit

@MainActor
public final class ClaudeAuthFlow: ObservableObject {
    @Published public private(set) var isAuthenticating: Bool = false
    @Published public private(set) var listeningURLString: String?
    @Published public private(set) var errorMessage: String?

    private var server: LocalOAuthServer?
    private var codeVerifier: String?
    private var state: String?

    public init() {}

    public func startAuthorization(completion: @escaping (Result<String, Error>) -> Void) {
        stopAuthorization()

        let verifier = generateCodeVerifier()
        let challenge = generateCodeChallenge(from: verifier)
        let stateToken = UUID().uuidString

        self.codeVerifier = verifier
        self.state = stateToken
        self.isAuthenticating = true
        self.errorMessage = nil

        let localServer = LocalOAuthServer(preferredPort: 54321)
        self.server = localServer

        localServer.start(timeout: 180) { [weak self] result in
            guard let self = self else { return }
            self.isAuthenticating = false

            switch result {
            case .success(let queryParams):
                if let error = queryParams["error"] {
                    let desc = queryParams["error_description"] ?? error
                    self.errorMessage = desc
                    completion(.failure(NSError(domain: "ClaudeAuth", code: -1, userInfo: [NSLocalizedDescriptionKey: desc])))
                    return
                }

                if let returnedState = queryParams["state"], returnedState != stateToken {
                    let err = "State mismatch — possible CSRF, aborting"
                    self.errorMessage = err
                    completion(.failure(NSError(domain: "ClaudeAuth", code: -3, userInfo: [NSLocalizedDescriptionKey: err])))
                    return
                }

                if let code = queryParams["code"] {
                    self.exchangeCodeForToken(code: code, state: queryParams["state"], verifier: verifier, completion: completion)
                } else if let token = queryParams["token"] ?? queryParams["access_token"] {
                    completion(.success(token))
                } else {
                    let err = "No authorization code or token found in callback response"
                    self.errorMessage = err
                    completion(.failure(NSError(domain: "ClaudeAuth", code: -2, userInfo: [NSLocalizedDescriptionKey: err])))
                }

            case .failure(let error):
                self.errorMessage = error.localizedDescription
                completion(.failure(error))
            }
        }

        let port = localServer.listeningPort
        let redirectURI = "http://localhost:\(port)/callback"
        self.listeningURLString = redirectURI

        var components = URLComponents(string: "https://claude.com/cai/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: "xxxxxxx"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: stateToken)
        ]

        if let authURL = components.url {
            NSWorkspace.shared.open(authURL)
        }
    }

    public func stopAuthorization() {
        server?.stop()
        server = nil
        isAuthenticating = false
        listeningURLString = nil
    }

    private func exchangeCodeForToken(code: String, state: String?, verifier: String, completion: @escaping (Result<String, Error>) -> Void) {
        if code.hasPrefix("sk-") {
            completion(.success(code))
            return
        }

        let redirectURI = listeningURLString ?? "http://localhost:54321/callback"
        let clientID = "xxxxxxx"

        Task {
            do {
                let token = try await self.performTokenExchange(
                    clientID: clientID,
                    code: code,
                    state: state,
                    redirectURI: redirectURI,
                    verifier: verifier
                )
                completion(.success(token))
            } catch {
                let errMsg = error.localizedDescription
                await MainActor.run {
                    self.errorMessage = errMsg
                }
                completion(.failure(error))
            }
        }
    }

    /// Mirrors the exact request the official Claude Code CLI sends (verified by inspecting its
    /// shipped binary): JSON POST to platform.claude.com, redirect_uri equal to the loopback URL
    /// actually used for the browser callback (not a fixed console URL).
    private func performTokenExchange(
        clientID: String,
        code: String,
        state: String?,
        redirectURI: String,
        verifier: String
    ) async throws -> String {
        let url = URL(string: "https://platform.claude.com/v1/oauth/token")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
            "state": state ?? ""
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "ClaudeAuth", code: -401, userInfo: [NSLocalizedDescriptionKey: "No HTTP response from token endpoint"])
        }

        if http.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let accessToken = json["access_token"] as? String {
            return accessToken
        }

        let responseStr = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
        let msg = "Token exchange failed (HTTP \(http.statusCode)): \(responseStr)"
        throw NSError(domain: "ClaudeAuth", code: -402, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    private func generateCodeVerifier() -> String {
        var buffer = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return Data(buffer).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        guard let data = verifier.data(using: .utf8) else { return "" }
        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

