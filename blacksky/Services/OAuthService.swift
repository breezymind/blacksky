import CryptoKit
import Foundation

struct OAuthClientConfiguration: Sendable, Equatable {
    let clientID: String
    let redirectURI: URL
    let authorizationEndpoint: URL?
    let tokenEndpoint: URL?
    let pushedAuthorizationRequestEndpoint: URL?
    let scope: String

    init(
        clientID: String,
        redirectURI: URL,
        authorizationEndpoint: URL? = nil,
        tokenEndpoint: URL? = nil,
        pushedAuthorizationRequestEndpoint: URL? = nil,
        scope: String
    ) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.pushedAuthorizationRequestEndpoint = pushedAuthorizationRequestEndpoint
        self.scope = scope
    }

    static let development = OAuthClientConfiguration(
        clientID: "https://breezymind.github.io/blacksky/oauth-client-metadata.json",
        redirectURI: URL(string: "blacksky://oauth/callback")!,
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
    func refresh(session: OAuthSession) async throws -> OAuthSession
}

enum OAuthError: Error, Equatable, LocalizedError, Sendable {
    case invalidHandle
    case invalidCallback
    case stateMismatch
    case missingAuthorizationCode
    case invalidTokenResponse
    case identityMismatch
    case missingDPoPKey
    case protocolViolation(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidHandle: return "Bluesky 핸들을 입력해 주세요."
        case .invalidCallback, .stateMismatch, .missingAuthorizationCode, .invalidTokenResponse:
            return "로그인 응답을 확인할 수 없습니다. 다시 시도해 주세요."
        case .identityMismatch, .missingDPoPKey, .protocolViolation:
            return "Bluesky OAuth 응답을 검증할 수 없습니다. 다시 로그인해 주세요."
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
        let discovery = try await discover(pdsURL: identity.pdsURL)
        let dpopKey = DPoPKeyMaterial.generate()
        let state = randomString(byteCount: 32)
        let verifier = randomString(byteCount: 48)
        let challenge = sha256Base64URL(verifier)
        transaction = Transaction(
            state: state,
            verifier: verifier,
            identity: identity,
            handle: handle,
            discovery: discovery,
            dpopKey: dpopKey,
            authorizationServerNonce: nil
        )

        do {
            let parResponse = try await pushedAuthorizationRequest(
                discovery: discovery,
                key: dpopKey,
                nonce: nil,
                values: [
                    "client_id": configuration.clientID,
                    "response_type": "code",
                    "redirect_uri": configuration.redirectURI.absoluteString,
                    "scope": configuration.scope,
                    "state": state,
                    "code_challenge": challenge,
                    "code_challenge_method": "S256",
                    "login_hint": handle
                ]
            )
            let par: PARResponse
            do {
                par = try JSONDecoder().decode(PARResponse.self, from: parResponse.data)
            } catch {
                throw OAuthError.protocolViolation("PAR response missing request_uri")
            }
            transaction?.authorizationServerNonce = parResponse.nonce
            guard var components = URLComponents(url: discovery.authorizationEndpoint, resolvingAgainstBaseURL: false) else {
                throw OAuthError.protocolViolation("invalid authorization endpoint")
            }
            components.queryItems = [
                URLQueryItem(name: "client_id", value: configuration.clientID),
                URLQueryItem(name: "request_uri", value: par.requestURI)
            ]
            guard let url = components.url else { throw OAuthError.invalidCallback }
            return url
        } catch {
            transaction = nil
            throw error
        }
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
        if let expectedIssuer = current.discovery.issuer {
            guard queryItems.first(where: { $0.name == "iss" })?.value == expectedIssuer.absoluteString else {
                transaction = nil
                throw OAuthError.protocolViolation("authorization issuer mismatch")
            }
        }
        guard let code = queryItems.first(where: { $0.name == "code" })?.value else {
            throw OAuthError.missingAuthorizationCode
        }

        do {
            let token = try await tokenRequest(
                endpoint: current.discovery.tokenEndpoint,
                key: current.dpopKey,
                nonce: current.authorizationServerNonce,
                values: [
                    "grant_type": "authorization_code",
                    "client_id": configuration.clientID,
                    "redirect_uri": configuration.redirectURI.absoluteString,
                    "code": code,
                    "code_verifier": current.verifier
                ]
            )
            guard let subject = token.sub, subject == current.identity.did else {
                throw OAuthError.identityMismatch
            }
            guard !token.accessToken.isEmpty, !token.refreshToken.isEmpty else {
                throw OAuthError.invalidTokenResponse
            }
            transaction = nil
            return OAuthSession(
                did: subject,
                handle: current.handle,
                pdsURL: current.identity.pdsURL,
                accessToken: token.accessToken,
                refreshToken: token.refreshToken,
                expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn)),
                scope: token.scope ?? configuration.scope,
                dpopKey: current.dpopKey,
                authorizationServer: current.discovery.issuer,
                authorizationServerNonce: token.nonce ?? current.authorizationServerNonce,
                resourceServerNonce: nil
            )
        } catch let error as OAuthError {
            transaction = nil
            throw error
        } catch is CancellationError {
            transaction = nil
            throw CancellationError()
        } catch {
            transaction = nil
            throw OAuthError.network(error.localizedDescription)
        }
    }

    func refresh(session: OAuthSession) async throws -> OAuthSession {
        guard let key = session.dpopKey else { throw OAuthError.missingDPoPKey }
        let discovery = try await discover(pdsURL: session.pdsURL, preferredAuthorizationServer: session.authorizationServer)
        let token = try await tokenRequest(
            endpoint: discovery.tokenEndpoint,
            key: key,
            nonce: session.authorizationServerNonce,
            values: [
                "grant_type": "refresh_token",
                "refresh_token": session.refreshToken,
                "client_id": configuration.clientID
            ]
        )
        guard let subject = token.sub ?? Optional(session.did), subject == session.did else {
            throw OAuthError.identityMismatch
        }
        guard !token.accessToken.isEmpty else { throw OAuthError.invalidTokenResponse }
        return OAuthSession(
            did: session.did,
            handle: session.handle,
            pdsURL: session.pdsURL,
            accessToken: token.accessToken,
            refreshToken: token.refreshToken.isEmpty ? session.refreshToken : token.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn)),
            scope: token.scope ?? session.scope,
            dpopKey: key,
            authorizationServer: discovery.issuer,
            authorizationServerNonce: token.nonce ?? session.authorizationServerNonce,
            resourceServerNonce: session.resourceServerNonce
        )
    }

    private func discover(pdsURL: URL, preferredAuthorizationServer: URL? = nil) async throws -> OAuthDiscovery {
        if let authorizationEndpoint = configuration.authorizationEndpoint,
           let tokenEndpoint = configuration.tokenEndpoint,
           let parEndpoint = configuration.pushedAuthorizationRequestEndpoint {
            return OAuthDiscovery(
                issuer: preferredAuthorizationServer,
                authorizationEndpoint: authorizationEndpoint,
                tokenEndpoint: tokenEndpoint,
                pushedAuthorizationRequestEndpoint: parEndpoint
            )
        }

        let protectedURL = try wellKnownURL(base: pdsURL, path: "/.well-known/oauth-protected-resource")
        let protected: ProtectedResourceMetadata = try await getJSON(url: protectedURL)
        let issuer = preferredAuthorizationServer ?? protected.authorizationServers.first
        guard let issuer else { throw OAuthError.protocolViolation("authorization server missing") }
        let metadataURL = try wellKnownURL(base: issuer, path: "/.well-known/oauth-authorization-server")
        let metadata: AuthorizationServerMetadata = try await getJSON(url: metadataURL)
        guard let parEndpoint = metadata.pushedAuthorizationRequestEndpoint else {
            throw OAuthError.protocolViolation("PAR endpoint missing")
        }
        return OAuthDiscovery(
            issuer: metadata.issuer ?? issuer,
            authorizationEndpoint: metadata.authorizationEndpoint,
            tokenEndpoint: metadata.tokenEndpoint,
            pushedAuthorizationRequestEndpoint: parEndpoint
        )
    }

    private func pushedAuthorizationRequest(
        discovery: OAuthDiscovery,
        key: DPoPKeyMaterial,
        nonce: String?,
        values: [String: String]
    ) async throws -> DPoPResponse {
        var request = URLRequest(url: discovery.pushedAuthorizationRequestEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncoded(values)
        return try await sendDPoP(request: request, key: key, nonce: nonce)
    }

    private func tokenRequest(
        endpoint: URL,
        key: DPoPKeyMaterial,
        nonce: String?,
        values: [String: String]
    ) async throws -> TokenResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncoded(values)
        let result = try await sendDPoP(request: request, key: key, nonce: nonce)
        do {
            var token = try JSONDecoder().decode(TokenResponse.self, from: result.data)
            token.nonce = result.nonce
            return token
        } catch {
            throw OAuthError.invalidTokenResponse
        }
    }

    private func sendDPoP(request: URLRequest, key: DPoPKeyMaterial, nonce: String?) async throws -> DPoPResponse {
        var currentNonce = nonce
        for attempt in 0..<2 {
            var signedRequest = request
            let proof = try DPoPProofBuilder.make(
                key: key,
                method: request.httpMethod ?? "GET",
                url: request.url ?? URL(string: "https://invalid.local")!,
                nonce: currentNonce
            )
            signedRequest.setValue(proof, forHTTPHeaderField: "DPoP")
            let (data, response) = try await httpClient.send(signedRequest)
            guard let http = response as? HTTPURLResponse else { throw OAuthError.network("invalid OAuth response") }
            let responseNonce = http.value(forHTTPHeaderField: "DPoP-Nonce")
            if (http.statusCode == 400 || http.statusCode == 401), attempt == 0,
               let responseNonce, !responseNonce.isEmpty, responseNonce != currentNonce {
                currentNonce = responseNonce
                continue
            }
            guard (200..<300).contains(http.statusCode) else {
                throw OAuthError.network("OAuth request failed (\(http.statusCode))")
            }
            return DPoPResponse(data: data, nonce: responseNonce ?? currentNonce)
        }
        throw OAuthError.network("DPoP nonce negotiation failed")
    }

    private func getJSON<Response: Decodable>(url: URL) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await httpClient.send(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OAuthError.network("OAuth metadata request failed")
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw OAuthError.protocolViolation("invalid OAuth metadata")
        }
    }

    private func wellKnownURL(base: URL, path: String) throws -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw OAuthError.protocolViolation("invalid metadata URL")
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw OAuthError.protocolViolation("invalid metadata URL") }
        return url
    }

    private struct Transaction: Sendable {
        let state: String
        let verifier: String
        let identity: ResolvedIdentity
        let handle: String
        let discovery: OAuthDiscovery
        let dpopKey: DPoPKeyMaterial
        var authorizationServerNonce: String?
    }

    private struct OAuthDiscovery: Sendable {
        let issuer: URL?
        let authorizationEndpoint: URL
        let tokenEndpoint: URL
        let pushedAuthorizationRequestEndpoint: URL
    }

    private struct ProtectedResourceMetadata: Decodable {
        let authorizationServers: [URL]
        enum CodingKeys: String, CodingKey { case authorizationServers = "authorization_servers" }
    }

    private struct AuthorizationServerMetadata: Decodable {
        let issuer: URL?
        let authorizationEndpoint: URL
        let tokenEndpoint: URL
        let pushedAuthorizationRequestEndpoint: URL?
        enum CodingKeys: String, CodingKey {
            case issuer
            case authorizationEndpoint = "authorization_endpoint"
            case tokenEndpoint = "token_endpoint"
            case pushedAuthorizationRequestEndpoint = "pushed_authorization_request_endpoint"
        }
    }

    private struct DPoPResponse: Sendable {
        let data: Data
        let nonce: String?
    }

    private struct PARResponse: Decodable {
        let requestURI: String
        enum CodingKeys: String, CodingKey { case requestURI = "request_uri" }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int
        let scope: String?
        let sub: String?
        var nonce: String? = nil

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case scope
            case sub
        }
    }

    private func randomString(byteCount: Int) -> String {
        Data((0..<byteCount).map { _ in UInt8.random(in: 0...255) }).base64URLEncoded
    }

    private func sha256Base64URL(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).withUnsafeBytes { Data($0).base64URLEncoded }
    }

    private func formEncoded(_ values: [String: String]) -> Data {
        values
            .sorted { $0.key < $1.key }
            .map { "\(formEscape($0.key))=\(formEscape($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }

    private func formEscape(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
