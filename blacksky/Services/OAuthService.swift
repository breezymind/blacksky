import Foundation
import CryptoKit

struct OAuthClientConfiguration: Sendable, Equatable {
    let clientID: String
    let redirectURI: URL
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let scope: String

    static let development = OAuthClientConfiguration(
        clientID: "https://breezymind.github.io/blacksky/oauth-client-metadata.json",
        redirectURI: URL(string: "blacksky://oauth/callback")!,
        authorizationEndpoint: URL(string: "https://bsky.social/oauth/authorize")!,
        tokenEndpoint: URL(string: "https://bsky.social/oauth/token")!,
        scope: "atproto transition:generic"
    )
}

struct ResolvedIdentity: Sendable, Equatable {
    let did: String
    let pdsURL: URL
}

protocol OAuthIdentityResolver: Sendable {
    func resolve(handle: String) async throws -> ResolvedIdentity
}

protocol OAuthAuthenticating: Sendable {
    func startLogin(handle: String) async throws -> URL
    func completeLogin(callbackURL: URL) async throws -> OAuthSession
}

enum OAuthError: Error, Equatable, LocalizedError, Sendable {
    case invalidHandle
    case invalidCallback
    case stateMismatch
    case missingAuthorizationCode
    case invalidTokenResponse
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidHandle: return "Bluesky 핸들을 입력해 주세요."
        case .invalidCallback, .stateMismatch, .missingAuthorizationCode, .invalidTokenResponse:
            return "로그인 응답을 확인할 수 없습니다. 다시 시도해 주세요."
        case .network: return "로그인에 실패했습니다. 네트워크 연결을 확인해 주세요."
        }
    }
}

struct BlueskyIdentityResolver: OAuthIdentityResolver, Sendable {
    private let httpClient: any HTTPClient
    private let publicAPI: URL
    private let plcDirectory: URL

    init(
        httpClient: any HTTPClient = URLSessionHTTPClient(),
        publicAPI: URL = URL(string: "https://public.api.bsky.app")!,
        plcDirectory: URL = URL(string: "https://plc.directory")!
    ) {
        self.httpClient = httpClient
        self.publicAPI = publicAPI
        self.plcDirectory = plcDirectory
    }

    func resolve(handle: String) async throws -> ResolvedIdentity {
        guard !handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OAuthError.invalidHandle
        }
        guard var components = URLComponents(url: publicAPI, resolvingAgainstBaseURL: false) else {
            throw OAuthError.network("invalid resolver URL")
        }
        components.path = "/xrpc/com.atproto.identity.resolveHandle"
        components.queryItems = [URLQueryItem(name: "handle", value: handle)]
        guard let url = components.url else { throw OAuthError.network("invalid resolver URL") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await httpClient.send(request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw OAuthError.network("handle resolution failed")
            }
            let resolved = try JSONDecoder().decode(ResolvedHandleResponse.self, from: data)
            let pdsURL = try await resolvePDS(for: resolved.did)
            return ResolvedIdentity(did: resolved.did, pdsURL: pdsURL)
        } catch let error as OAuthError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OAuthError.network(error.localizedDescription)
        }
    }

    private func resolvePDS(for did: String) async throws -> URL {
        guard let url = URL(string: plcDirectory.absoluteString + "/" + did) else {
            throw OAuthError.network("invalid DID")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await httpClient.send(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OAuthError.network("DID resolution failed")
        }
        let document = try JSONDecoder().decode(PLCDocument.self, from: data)
        guard let endpointString = document.service.first(where: { $0.type == "AtprotoPersonalDataServer" })?.serviceEndpoint,
              let endpoint = URL(string: endpointString) else {
            throw OAuthError.network("PDS endpoint missing")
        }
        return endpoint
    }

    private struct ResolvedHandleResponse: Decodable { let did: String }
    private struct PLCDocument: Decodable {
        let service: [Service]
        struct Service: Decodable {
            let type: String
            let serviceEndpoint: String
        }
    }
}

actor OAuthService: OAuthAuthenticating {
    private let configuration: OAuthClientConfiguration
    private let identityResolver: any OAuthIdentityResolver
    private let httpClient: any HTTPClient
    private var transaction: Transaction?

    init(
        configuration: OAuthClientConfiguration = .development,
        identityResolver: any OAuthIdentityResolver = BlueskyIdentityResolver(),
        httpClient: any HTTPClient = URLSessionHTTPClient()
    ) {
        self.configuration = configuration
        self.identityResolver = identityResolver
        self.httpClient = httpClient
    }

    func startLogin(handle: String) async throws -> URL {
        let identity = try await identityResolver.resolve(handle: handle)
        let state = randomString(byteCount: 32)
        let verifier = randomString(byteCount: 48)
        let challenge = sha256Base64URL(verifier)
        transaction = Transaction(state: state, verifier: verifier, identity: identity, handle: handle)

        guard var components = URLComponents(url: configuration.authorizationEndpoint, resolvingAgainstBaseURL: false) else {
            throw OAuthError.invalidCallback
        }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: configuration.scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "login_hint", value: handle)
        ]
        guard let url = components.url else { throw OAuthError.invalidCallback }
        return url
    }

    func completeLogin(callbackURL: URL) async throws -> OAuthSession {
        guard callbackURL.scheme == configuration.redirectURI.scheme,
              callbackURL.host == configuration.redirectURI.host,
              callbackURL.path == configuration.redirectURI.path,
              let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              let state = queryItems.first(where: { $0.name == "state" })?.value,
              let current = transaction,
              state == current.state else {
            throw OAuthError.stateMismatch
        }
        if let error = queryItems.first(where: { $0.name == "error" })?.value, !error.isEmpty {
            transaction = nil
            throw OAuthError.invalidCallback
        }
        guard let code = queryItems.first(where: { $0.name == "code" })?.value else {
            throw OAuthError.missingAuthorizationCode
        }

        var request = URLRequest(url: configuration.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncoded([
            "grant_type": "authorization_code",
            "client_id": configuration.clientID,
            "redirect_uri": configuration.redirectURI.absoluteString,
            "code": code,
            "code_verifier": current.verifier
        ])
        do {
            let (data, response) = try await httpClient.send(request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw OAuthError.network("token exchange failed")
            }
            let token = try JSONDecoder().decode(TokenResponse.self, from: data)
            guard !token.accessToken.isEmpty, !token.refreshToken.isEmpty else {
                throw OAuthError.invalidTokenResponse
            }
            transaction = nil
            return OAuthSession(
                did: token.sub ?? current.identity.did,
                handle: current.handle,
                pdsURL: current.identity.pdsURL,
                accessToken: token.accessToken,
                refreshToken: token.refreshToken,
                expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn)),
                scope: token.scope ?? configuration.scope
            )
        } catch let error as OAuthError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OAuthError.network(error.localizedDescription)
        }
    }

    private struct Transaction: Sendable {
        let state: String
        let verifier: String
        let identity: ResolvedIdentity
        let handle: String
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int
        let scope: String?
        let sub: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case scope
            case sub
        }
    }

    private func randomString(byteCount: Int) -> String {
        Data((0..<byteCount).map { _ in UInt8.random(in: 0...255) })
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    private func sha256Base64URL(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    private func formEncoded(_ values: [String: String]) -> Data {
        let body = values
            .sorted { $0.key < $1.key }
            .map { "\(formEscape($0.key))=\(formEscape($0.value))" }
            .joined(separator: "&")
        return Data(body.utf8)
    }

    private func formEscape(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
