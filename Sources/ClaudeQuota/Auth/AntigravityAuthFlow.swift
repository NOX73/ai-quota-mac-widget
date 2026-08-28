import Foundation
import CryptoKit
import AppKit

public struct AntigravityTokenSet {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresIn: Double?
}

/// Distinguishes a token endpoint outright rejecting the request (the refresh token itself is
/// dead — e.g. revoked/expired, reported via HTTP 4xx) from a transient failure (network hiccup,
/// timeout, Google-side 5xx) worth retrying later without forcing the user to log in again.
public enum AntigravityAuthError: LocalizedError {
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
public final class AntigravityAuthFlow: ObservableObject {
    /// Public OAuth client used by Google's Antigravity CLI/IDE, discovered by inspecting the
    /// official Antigravity binary's network traffic (the same client several open-source
    /// community auth plugins for opencode/etc. rely on, e.g. opencode-antigravity-auth). Not a
    /// confidential value — it's baked into every copy of the official Antigravity binary and
    /// already public across those community repos — but GitHub's push protection still flags
    /// its shape as a leaked credential, so it lives in .env / GeneratedCredentials.swift
    /// (gitignored, see doc/features/oauth-credentials.md) instead of a literal here.
    public static var clientID: String { GeneratedCredentials.antigravityClientID }
    public static var clientSecret: String { GeneratedCredentials.antigravityClientSecret }

    private static let authorizeURL = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let tokenURL = "https://oauth2.googleapis.com/token"
    private static let scopes = [
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
        "https://www.googleapis.com/auth/cclog",
        "https://www.googleapis.com/auth/experimentsandconfigs"
    ].joined(separator: " ")

    @Published public private(set) var isAuthenticating: Bool = false
    @Published public private(set) var listeningURLString: String?
    @Published public private(set) var errorMessage: String?

    private var server: LocalOAuthServer?
    private var codeVerifier: String?
    private var state: String?

    public init() {}

    public func startAuthorization(completion: @escaping (Result<AntigravityTokenSet, Error>) -> Void) {
        stopAuthorization()

        let verifier = generateCodeVerifier()
        let challenge = generateCodeChallenge(from: verifier)
        let stateToken = UUID().uuidString

        self.codeVerifier = verifier
        self.state = stateToken
        self.isAuthenticating = true
        self.errorMessage = nil

        // Port 51121 is the registered redirect port for this OAuth client (mirrors the
        // official Antigravity CLI's own local callback server) — no fallback port is possible.
        let localServer = LocalOAuthServer(preferredPort: 51121, fallbackPorts: [])
        self.server = localServer

        localServer.start(timeout: 180, onReady: { [weak self] readyPort in
            guard let self = self else { return }
            let redirectURI = "http://localhost:\(readyPort)/oauth-callback"
            self.listeningURLString = redirectURI

            var components = URLComponents(string: Self.authorizeURL)!
            components.queryItems = [
                URLQueryItem(name: "client_id", value: Self.clientID),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "redirect_uri", value: redirectURI),
                URLQueryItem(name: "scope", value: Self.scopes),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "access_type", value: "offline"),
                URLQueryItem(name: "prompt", value: "consent"),
                URLQueryItem(name: "state", value: stateToken)
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
                    completion(.failure(NSError(domain: "AntigravityAuth", code: -1, userInfo: [NSLocalizedDescriptionKey: desc])))
                    return
                }

                if let returnedState = queryParams["state"], returnedState != stateToken {
                    let err = "State mismatch — possible CSRF, aborting"
                    self.errorMessage = err
                    completion(.failure(NSError(domain: "AntigravityAuth", code: -3, userInfo: [NSLocalizedDescriptionKey: err])))
                    return
                }

                if let code = queryParams["code"] {
                    self.exchangeCodeForToken(code: code, verifier: verifier, completion: completion)
                } else {
                    let err = "No authorization code found in callback response"
                    self.errorMessage = err
                    completion(.failure(NSError(domain: "AntigravityAuth", code: -2, userInfo: [NSLocalizedDescriptionKey: err])))
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

    private func exchangeCodeForToken(code: String, verifier: String, completion: @escaping (Result<AntigravityTokenSet, Error>) -> Void) {
        let redirectURI = listeningURLString ?? "http://localhost:51121/oauth-callback"

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

    static func performCodeExchange(code: String, redirectURI: String, verifier: String) async throws -> AntigravityTokenSet {
        try await performTokenRequest(body: [
            "client_id": clientID,
            "client_secret": clientSecret,
            "code": code,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
            "code_verifier": verifier
        ])
    }

    /// Exchanges a stored refresh token for a new access token. Note Google's refresh grant
    /// typically omits `refresh_token` in the response (no rotation) — callers should keep the
    /// existing refresh token when `refreshToken` comes back nil.
    public static func refreshAccessToken(refreshToken: String) async throws -> AntigravityTokenSet {
        try await performTokenRequest(body: [
            "client_id": clientID,
            "client_secret": clientSecret,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ])
    }

    private static func performTokenRequest(body: [String: String]) async throws -> AntigravityTokenSet {
        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncode(body).data(using: .utf8)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // Transport-level failure (offline, DNS, timeout, ...) — says nothing about whether
            // the refresh token itself is still good.
            throw AntigravityAuthError.transient(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AntigravityAuthError.transient("No HTTP response from token endpoint")
        }

        if http.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let accessToken = json["access_token"] as? String {
            return AntigravityTokenSet(
                accessToken: accessToken,
                refreshToken: json["refresh_token"] as? String,
                expiresIn: json["expires_in"] as? Double
            )
        }

        let responseStr = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
        let msg = "Token request failed (HTTP \(http.statusCode)): \(responseStr)"
        // OAuth2 token errors (invalid_grant, invalid_client, ...) are reported as 4xx per spec —
        // that's a definitive "this refresh token is dead". A 5xx is Google's server having a bad
        // moment and says nothing about the token, so treat it as retryable instead.
        if (400...499).contains(http.statusCode) {
            throw AntigravityAuthError.permanent(msg)
        }
        throw AntigravityAuthError.transient(msg)
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
