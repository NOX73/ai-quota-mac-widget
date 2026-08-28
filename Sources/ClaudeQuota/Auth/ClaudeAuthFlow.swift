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

                if let code = queryParams["code"] {
                    self.exchangeCodeForToken(code: code, verifier: verifier, completion: completion)
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

        var components = URLComponents(string: "https://claude.ai/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: "xxxxxxx"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "user:inference"),
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

    private func exchangeCodeForToken(code: String, verifier: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard let tokenEndpoint = URL(string: "https://api.anthropic.com/v1/oauth/tokens") else {
            completion(.success(code))
            return
        }

        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "grant_type": "authorization_code",
            "client_id": "xxxxxxx",
            "code": code,
            "redirect_uri": listeningURLString ?? "http://localhost:54321/callback",
            "code_verifier": verifier
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            completion(.success(code))
            return
        }

        request.httpBody = httpBody

        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let accessToken = json["access_token"] as? String {
                    completion(.success(accessToken))
                } else {
                    completion(.success(code))
                }
            } catch {
                completion(.success(code))
            }
        }
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

