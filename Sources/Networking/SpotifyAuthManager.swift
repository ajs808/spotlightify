import AppKit
import CryptoKit
import Foundation
import Network

enum SpotifyAuthError: LocalizedError {
    case missingClientID
    case invalidCallback
    case missingCode
    case cancelled
    case timedOut
    case invalidTokenResponse
    case tokenRequestFailed(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "Add your Spotify Client ID before logging in."
        case .invalidCallback:
            return "Spotify did not return to \(SpotifyAuthManager.redirectURIDescription)."
        case .missingCode:
            return "Spotify did not return an authorization code."
        case .cancelled:
            return "Spotify login was cancelled."
        case .timedOut:
            return "Spotify login timed out before returning to \(SpotifyAuthManager.redirectURIDescription)."
        case .invalidTokenResponse:
            return "Spotify token response was invalid."
        case .tokenRequestFailed(let statusCode):
            return "Spotify token request failed with HTTP \(statusCode)."
        }
    }
}

enum SpotifyAuthorizationState: Equatable {
    case ready
    case requiresInteractiveLogin
    case interactiveLoginInProgress
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int
    let refreshToken: String?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case scope
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
    }
}

final class SpotifyAuthManager: NSObject, @unchecked Sendable {
    static let redirectURIDescription = "http://127.0.0.1:43821/callback"
    static let libraryModifyScope = "user-library-modify"
    static let requestedScopes = [
        "user-read-playback-state",
        "user-modify-playback-state",
        "user-read-recently-played",
        "user-library-read",
        libraryModifyScope
    ]

    private let configuration: AppConfiguration
    private let keychain: KeychainStore
    private let clientIDProvider: @Sendable () -> String
    private let session: URLSession
    private let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!
    @MainActor private var authorizationTask: Task<SpotifyToken, Error>?
    @MainActor private(set) var isInteractiveAuthInProgress = false
    @MainActor var onAuthorizationSucceeded: (() -> Void)?

    init(
        configuration: AppConfiguration,
        keychain: KeychainStore,
        clientIDProvider: @escaping @Sendable () -> String,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.keychain = keychain
        self.clientIDProvider = clientIDProvider
        self.session = session
        super.init()
    }

    func ensureAuthorized(forceReauthentication: Bool = false) async throws -> SpotifyToken {
        AppLogger.shared.log("ensureAuthorized force=\(forceReauthentication)", category: "auth")
        if !forceReauthentication, let token = try keychain.loadToken(), !token.isExpired {
            AppLogger.shared.log("using cached access token", category: "auth")
            return token
        }

        let task = await MainActor.run {
            if let authorizationTask {
                AppLogger.shared.log("awaiting in-flight authorization task", category: "auth")
                return authorizationTask
            }

            let task = Task<SpotifyToken, Error> {
                if !forceReauthentication, let token = try self.keychain.loadToken(), !token.isExpired {
                    AppLogger.shared.log("using cached access token after waiting", category: "auth")
                    return token
                }

                if !forceReauthentication, let token = try self.keychain.loadToken(), !token.refreshToken.isEmpty {
                    do {
                        AppLogger.shared.log("refreshing access token", category: "auth")
                        let refreshed = try await self.refreshToken(token.refreshToken, previousScope: token.scope)
                        try self.keychain.save(token: refreshed)
                        AppLogger.shared.log("token refresh succeeded", category: "auth")
                        return refreshed
                    } catch {
                        AppLogger.shared.log("token refresh failed: \(error.localizedDescription)", category: "auth")
                        guard self.shouldDiscardRefreshToken(after: error) else {
                            throw error
                        }
                        try? self.keychain.deleteToken()
                    }
                }

                await MainActor.run {
                    self.isInteractiveAuthInProgress = true
                }

                defer {
                    Task { @MainActor in
                        self.isInteractiveAuthInProgress = false
                    }
                }

                AppLogger.shared.log("starting interactive auth", category: "auth")
                let newToken = try await self.authenticateInteractively()
                try self.keychain.save(token: newToken)
                AppLogger.shared.log("interactive auth succeeded and token saved", category: "auth")
                await MainActor.run {
                    self.onAuthorizationSucceeded?()
                }
                return newToken
            }

            authorizationTask = task
            return task
        }

        do {
            let token = try await task.value
            await MainActor.run {
                self.authorizationTask = nil
            }
            return token
        } catch {
            await MainActor.run {
                self.authorizationTask = nil
            }
            throw error
        }
    }

    func currentToken() throws -> SpotifyToken? {
        try keychain.loadToken()
    }

    func clearStoredAuthorization() throws {
        try keychain.deleteToken()
    }

    func authorizationStateForSearch() async -> SpotifyAuthorizationState {
        if await MainActor.run(body: { isInteractiveAuthInProgress }) {
            return .interactiveLoginInProgress
        }

        guard let token = try? keychain.loadToken() else {
            return .requiresInteractiveLogin
        }

        if !token.isExpired || !token.refreshToken.isEmpty {
            return .ready
        }

        return .requiresInteractiveLogin
    }

    private func authenticateInteractively() async throws -> SpotifyToken {
        let clientID = clientIDProvider()
        guard !clientID.isEmpty, clientID != "CHANGE_ME" else {
            AppLogger.shared.log("missing client id", category: "auth")
            throw SpotifyAuthError.missingClientID
        }

        let pkce = PKCEPair.generate()
        let state = UUID().uuidString
        let authURL = try authorizationURL(clientID: clientID, state: state, pkce: pkce)
        AppLogger.shared.log("auth URL created", category: "auth")
        let callbackURL = try await beginWebAuthentication(url: authURL)
        AppLogger.shared.log("web auth callback received", category: "auth")

        guard
            let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
            let stateValue = components.queryItems?.first(where: { $0.name == "state" })?.value,
            stateValue == state
        else {
            AppLogger.shared.log("callback state mismatch", category: "auth")
            throw SpotifyAuthError.invalidCallback
        }

        guard let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            AppLogger.shared.log("callback missing code", category: "auth")
            throw SpotifyAuthError.missingCode
        }

        AppLogger.shared.log("exchanging auth code for token", category: "auth")
        return try await exchangeCodeForToken(clientID: clientID, code: code, pkce: pkce)
    }

    private func authorizationURL(clientID: String, state: String, pkce: PKCEPair) throws -> URL {
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "scope", value: Self.requestedScopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: pkce.codeChallenge),
            URLQueryItem(name: "state", value: state)
        ]
        return components.url!
    }

    private func beginWebAuthentication(url: URL) async throws -> URL {
        let server = try LoopbackCallbackServer(
            host: configuration.oauthRedirectHost,
            port: configuration.oauthRedirectPort
        )

        AppLogger.shared.log("starting loopback callback server at \(configuration.redirectURI)", category: "auth")
        return try await server.waitForCallback(opening: url)
    }

    private func exchangeCodeForToken(clientID: String, code: String, pkce: PKCEPair) async throws -> SpotifyToken {
        let body = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "code_verifier", value: pkce.codeVerifier)
        ]

        let response = try await sendTokenRequest(body: body)
        guard response.tokenType.lowercased() == "bearer" else {
            AppLogger.shared.log("token exchange invalid token type \(response.tokenType)", category: "auth")
            throw SpotifyAuthError.invalidTokenResponse
        }
        AppLogger.shared.log("token exchange succeeded", category: "auth")
        return SpotifyToken(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? "",
            expiryDate: Date().addingTimeInterval(TimeInterval(response.expiresIn)),
            scope: response.scope
        )
    }

    private func refreshToken(_ refreshToken: String, previousScope: String?) async throws -> SpotifyToken {
        let clientID = clientIDProvider()
        guard !clientID.isEmpty, clientID != "CHANGE_ME" else {
            throw SpotifyAuthError.missingClientID
        }
        let body = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientID)
        ]

        let response = try await sendTokenRequest(body: body)
        AppLogger.shared.log("refresh token request succeeded", category: "auth")
        return SpotifyToken(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? refreshToken,
            expiryDate: Date().addingTimeInterval(TimeInterval(response.expiresIn)),
            scope: response.scope ?? previousScope
        )
    }

    private func shouldDiscardRefreshToken(after error: Error) -> Bool {
        guard case SpotifyAuthError.tokenRequestFailed(let statusCode) = error else {
            return false
        }
        return statusCode == 400 || statusCode == 401
    }

    private func sendTokenRequest(body: [URLQueryItem]) async throws -> TokenResponse {
        var components = URLComponents()
        components.queryItems = body

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            if let httpResponse = response as? HTTPURLResponse {
                AppLogger.shared.log("token request failed status=\(httpResponse.statusCode)", category: "auth")
                throw SpotifyAuthError.tokenRequestFailed(statusCode: httpResponse.statusCode)
            } else {
                AppLogger.shared.log("token request failed invalid response", category: "auth")
                throw SpotifyAuthError.invalidTokenResponse
            }
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }
}

struct PKCEPair: Equatable {
    let codeVerifier: String
    let codeChallenge: String

    static func generate() -> PKCEPair {
        let verifier = randomVerifier()
        let challenge = codeChallenge(for: verifier)
        return PKCEPair(codeVerifier: verifier, codeChallenge: challenge)
    }

    static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    private static func randomVerifier() -> String {
        let allowedCharacters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return String((0..<64).compactMap { _ in allowedCharacters.randomElement() })
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private final class LoopbackCallbackServer: @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "app.spotlightify.auth-callback")
    private let listener: NWListener
    private let lock = NSLock()
    private var didFinish = false
    private var continuation: CheckedContinuation<URL, Error>?

    init(host: String, port: UInt16) throws {
        self.host = host
        self.port = port
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw SpotifyAuthError.invalidCallback
        }
        listener = try NWListener(using: .tcp, on: nwPort)
    }

    func waitForCallback(opening authURL: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    AppLogger.shared.log("loopback callback server ready", category: "auth")
                    DispatchQueue.main.async {
                        NSWorkspace.shared.open(authURL)
                    }
                case .failed(let error):
                    AppLogger.shared.log("loopback callback server failed: \(error)", category: "auth")
                    self.finish(.failure(error))
                default:
                    break
                }
            }

            listener.newConnectionHandler = { connection in
                AppLogger.shared.log("loopback callback connection accepted", category: "auth")
                connection.start(queue: self.queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, error in
                    if let error {
                        AppLogger.shared.log("loopback callback receive failed: \(error)", category: "auth")
                        self.finish(.failure(error))
                        connection.cancel()
                        return
                    }

                    guard
                        let data,
                        let request = String(data: data, encoding: .utf8),
                        let firstLine = request.split(separator: "\r\n").first ?? request.split(separator: "\n").first
                    else {
                        AppLogger.shared.log("loopback callback invalid HTTP request", category: "auth")
                        self.finish(.failure(SpotifyAuthError.invalidCallback))
                        connection.cancel()
                        return
                    }

                    let parts = firstLine.split(separator: " ")
                    guard parts.count >= 2 else {
                        AppLogger.shared.log("loopback callback malformed request line", category: "auth")
                        self.finish(.failure(SpotifyAuthError.invalidCallback))
                        connection.cancel()
                        return
                    }

                    let target = String(parts[1])
                    let callbackURL = URL(string: "http://\(self.host):\(self.port)\(target)")
                    AppLogger.shared.log("loopback callback target received", category: "auth")

                    let responseHTML = """
                    <html><body style="font-family:-apple-system,system-ui;padding:24px;">
                    <h2>Spotlightify</h2>
                    <p>Login complete. You can close this browser tab.</p>
                    </body></html>
                    """
                    let response = """
                    HTTP/1.1 200 OK\r
                    Content-Type: text/html; charset=utf-8\r
                    Content-Length: \(responseHTML.utf8.count)\r
                    Connection: close\r
                    \r
                    \(responseHTML)
                    """

                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                        connection.cancel()
                    })

                    if let callbackURL {
                        self.finish(.success(callbackURL))
                    } else {
                        self.finish(.failure(SpotifyAuthError.invalidCallback))
                    }
                }
            }

            listener.start(queue: queue)

            queue.asyncAfter(deadline: .now() + 60) {
                guard !self.isFinished else { return }
                AppLogger.shared.log("loopback callback server timed out waiting for redirect", category: "auth")
                self.finish(.failure(SpotifyAuthError.timedOut))
            }
        }
    }

    private var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didFinish
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        listener.cancel()
        continuation?.resume(with: result)
    }
}
