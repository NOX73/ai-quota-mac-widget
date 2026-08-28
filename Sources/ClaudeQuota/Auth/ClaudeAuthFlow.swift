import Foundation
import CryptoKit
import AppKit

public struct ClaudeTokenSet {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
}

@MainActor
public final class ClaudeAuthFlow: ObservableObject {
    public static let clientID = "xxxxxxx"

    @Published public private(set) var isAuthenticating: Bool = false
    @Published public private(set) var listeningURLString: String?
    @Published public private(set) var errorMessage: String?

    private var server: LocalOAuthServer?
    private var codeVerifier: String?
    private var state: String?

    public init() {}

    public func startAuthorization(completion: @escaping (Result<ClaudeTokenSet, Error>) -> Void) {
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
                    completion(.success(ClaudeTokenSet(accessToken: token, refreshToken: nil, expiresAt: nil)))
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
            URLQueryItem(name: "client_id", value: Self.clientID),
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

    private func exchangeCodeForToken(code: String, state: String?, verifier: String, completion: @escaping (Result<ClaudeTokenSet, Error>) -> Void) {
        if code.hasPrefix("sk-") {
            completion(.success(ClaudeTokenSet(accessToken: code, refreshToken: nil, expiresAt: nil)))
            return
        }

        let redirectURI = listeningURLString ?? "http://localhost:54321/callback"

        Task {
            do {
                let body: [String: Any] = [
                    "grant_type": "authorization_code",
                    "code": code,
                    "redirect_uri": redirectURI,
                    "client_id": Self.clientID,
                    "code_verifier": verifier,
                    "state": state ?? ""
                ]
                let tokenSet = try await Self.performTokenRequest(body: body)
                completion(.success(tokenSet))
            } catch {
                let errMsg = error.localizedDescription
                self.errorMessage = errMsg
                completion(.failure(error))
            }
        }
    }

    /// Mirrors the exact request the official Claude Code CLI sends (verified by inspecting its
    /// shipped binary): JSON POST to platform.claude.com. Used for both the authorization_code
    /// exchange (redirect_uri equal to the loopback URL used for the browser callback, not a
    /// fixed console URL) and refresh_token renewals.
    static func performTokenRequest(body: [String: Any]) async throws -> ClaudeTokenSet {
        let url = URL(string: "https://platform.claude.com/v1/oauth/token")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "ClaudeAuth", code: -401, userInfo: [NSLocalizedDescriptionKey: "No HTTP response from token endpoint"])
        }

        if http.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let accessToken = json["access_token"] as? String {
            let expiresAt = (json["expires_in"] as? Double).map { Date().addingTimeInterval($0) }
            return ClaudeTokenSet(accessToken: accessToken, refreshToken: json["refresh_token"] as? String, expiresAt: expiresAt)
        }

        let responseStr = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
        let msg = "Token request failed (HTTP \(http.statusCode)): \(responseStr)"
        throw NSError(domain: "ClaudeAuth", code: -402, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    /// Exchanges a stored refresh token for a new access token, per the same endpoint the CLI uses.
    public static func refreshAccessToken(refreshToken: String) async throws -> ClaudeTokenSet {
        try await performTokenRequest(body: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID
        ])
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

