import Foundation
import CryptoKit
import AppKit

public struct CodexTokenSet {
    public let accessToken: String
    public let refreshToken: String?
    public let idToken: String?
}

/// Distinguishes a token endpoint outright rejecting the request (the refresh token itself is
/// dead — e.g. revoked/expired, reported via HTTP 4xx) from a transient failure (network hiccup,
/// timeout, server-side 5xx) worth retrying later without forcing the user to log in again.
public enum CodexAuthError: LocalizedError {
    case permanent(String)
    case transient(String)

    public var errorDescription: String? {
        switch self {
        case .permanent(let message), .transient(let message):
            return message
        }
    }
}

@MainActor
public final class CodexAuthFlow: ObservableObject {
    /// Public OAuth client id used by the official Codex CLI, discovered by inspecting the
    /// open-source `openai/codex` repo (codex-rs/login). See GeneratedCredentials.swift
    /// (generated from .env — see doc/features/oauth-credentials.md) for the actual value.
    public static let clientID = GeneratedCredentials.codexClientID
    private static let issuer = "https://auth.openai.com"

    @Published public private(set) var isAuthenticating: Bool = false
    @Published public private(set) var listeningURLString: String?
    @Published public private(set) var errorMessage: String?

    private var server: LocalOAuthServer?
    private var codeVerifier: String?
    private var state: String?

    public init() {}

    public func startAuthorization(completion: @escaping (Result<CodexTokenSet, Error>) -> Void) {
        stopAuthorization()

        let verifier = generateCodeVerifier()
        let challenge = generateCodeChallenge(from: verifier)
        let stateToken = UUID().uuidString

        self.codeVerifier = verifier
        self.state = stateToken
        self.isAuthenticating = true
        self.errorMessage = nil

        // 1455 and 1457 are the only redirect ports registered for this OAuth client — any other
        // port gets rejected as an invalid redirect_uri, so this mirrors the official Codex CLI's
        // own primary/fallback ports exactly rather than scanning a wider range.
        let localServer = LocalOAuthServer(preferredPort: 1455, fallbackPorts: [1457])
        self.server = localServer

        localServer.start(timeout: 180, onReady: { [weak self] readyPort in
            guard let self = self else { return }
            let redirectURI = "http://localhost:\(readyPort)/auth/callback"
            self.listeningURLString = redirectURI

            var components = URLComponents(string: "\(Self.issuer)/oauth/authorize")!
            components.queryItems = [
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "client_id", value: Self.clientID),
                URLQueryItem(name: "redirect_uri", value: redirectURI),
                URLQueryItem(name: "scope", value: "openid profile email offline_access api.connectors.read api.connectors.invoke"),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "id_token_add_organizations", value: "true"),
                URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
                URLQueryItem(name: "state", value: stateToken),
                URLQueryItem(name: "originator", value: "codex_cli_rs")
            ]

            if let authURL = components.url {
                NSWorkspace.shared.open(authURL)
            }
        }) { [weak self] result in
            guard let self = self else { return }
            self.isAuthenticating = false

            switch result {
            case .success(let queryParams):
                if let error = queryParams["error"] {
                    let desc = queryParams["error_description"] ?? error
                    self.errorMessage = desc
                    completion(.failure(NSError(domain: "CodexAuth", code: -1, userInfo: [NSLocalizedDescriptionKey: desc])))
                    return
                }

                if let returnedState = queryParams["state"], returnedState != stateToken {
                    let err = "State mismatch — possible CSRF, aborting"
                    self.errorMessage = err
                    completion(.failure(NSError(domain: "CodexAuth", code: -3, userInfo: [NSLocalizedDescriptionKey: err])))
                    return
                }

                if let code = queryParams["code"] {
                    self.exchangeCodeForToken(code: code, verifier: verifier, completion: completion)
                } else {
                    let err = "No authorization code found in callback response"
                    self.errorMessage = err
                    completion(.failure(NSError(domain: "CodexAuth", code: -2, userInfo: [NSLocalizedDescriptionKey: err])))
                }

            case .failure(let error):
                self.errorMessage = error.localizedDescription
                completion(.failure(error))
            }
        }
    }

    public func stopAuthorization() {
        server?.stop()
        server = nil
        isAuthenticating = false
        listeningURLString = nil
    }

    private func exchangeCodeForToken(code: String, verifier: String, completion: @escaping (Result<CodexTokenSet, Error>) -> Void) {
        let redirectURI = listeningURLString ?? "http://localhost:1455/auth/callback"

        Task {
            do {
                let tokenSet = try await Self.performCodeExchange(code: code, redirectURI: redirectURI, verifier: verifier)
                completion(.success(tokenSet))
            } catch {
                self.errorMessage = error.localizedDescription
                completion(.failure(error))
            }
        }
    }

    /// Mirrors the exact request the official Codex CLI sends for the authorization_code grant
    /// (verified against the open-source codex-rs/login/src/server.rs): form-encoded POST to
    /// auth.openai.com.
    static func performCodeExchange(code: String, redirectURI: String, verifier: String) async throws -> CodexTokenSet {
        let url = URL(string: "\(issuer)/oauth/token")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyParams = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier
        ]
        request.httpBody = formEncode(bodyParams).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "CodexAuth", code: -401, userInfo: [NSLocalizedDescriptionKey: "No HTTP response from token endpoint"])
        }

        if http.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let accessToken = json["access_token"] as? String {
            return CodexTokenSet(
                accessToken: accessToken,
                refreshToken: json["refresh_token"] as? String,
                idToken: json["id_token"] as? String
            )
        }

        let responseStr = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
        let msg = "Token request failed (HTTP \(http.statusCode)): \(responseStr)"
        throw NSError(domain: "CodexAuth", code: -402, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    /// Exchanges a stored refresh token for a new access token, per the same endpoint/shape the
    /// CLI uses for refreshes (JSON body, unlike the form-encoded authorization_code exchange).
    public static func refreshAccessToken(refreshToken: String) async throws -> CodexTokenSet {
        let url = URL(string: "\(issuer)/oauth/token")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ])

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // Transport-level failure (offline, DNS, timeout, ...) — says nothing about whether
            // the refresh token itself is still good.
            throw CodexAuthError.transient(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CodexAuthError.transient("No HTTP response from token endpoint")
        }

        if http.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let accessToken = json["access_token"] as? String {
            return CodexTokenSet(
                accessToken: accessToken,
                refreshToken: json["refresh_token"] as? String,
                idToken: json["id_token"] as? String
            )
        }

        let responseStr = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
        let msg = "Token refresh failed (HTTP \(http.statusCode)): \(responseStr)"
        // OAuth2 token errors (invalid_grant, invalid_client, ...) are reported as 4xx per spec —
        // that's a definitive "this refresh token is dead". A 5xx is the server having a bad
        // moment and says nothing about the token, so treat it as retryable instead. 429 is also
        // a 4xx but means "rate limited", not "token invalid" — retryable too.
        if http.statusCode != 429, (400...499).contains(http.statusCode) {
            throw CodexAuthError.permanent(msg)
        }
        throw CodexAuthError.transient(msg)
    }

    private static func formEncode(_ params: [String: String]) -> String {
        params.map { key, value in
            let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(key)=\(encodedValue)"
        }.joined(separator: "&")
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
