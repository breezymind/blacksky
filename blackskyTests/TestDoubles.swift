import Foundation
@testable import blacksky

actor RecordingHTTPClient: HTTPClient {
    let payload: Data
    private(set) var lastRequest: URLRequest?

    init(payload: Data) {
        self.payload = payload
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (payload, response)
    }
}

struct NoOpOAuth: OAuthAuthenticating {
    func startLogin(handle: String) async throws -> URL {
        throw OAuthError.network("not used in test")
    }

    func completeLogin(callbackURL: URL) async throws -> OAuthSession {
        throw OAuthError.network("not used in test")
    }

    func refresh(session: OAuthSession) async throws -> OAuthSession {
        throw OAuthError.network("not used in test")
    }
}

actor OAuthFixtureHTTPClient: HTTPClient {
    private(set) var requests: [URLRequest] = []
    private var parAttempts = 0

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard let url = request.url else { throw URLError(.badURL) }
        switch url.path {
        case "/.well-known/oauth-protected-resource":
            return response(
                request: request,
                status: 200,
                body: #"{"authorization_servers":["https://auth.example"]}"#
            )
        case "/.well-known/oauth-authorization-server":
            return response(
                request: request,
                status: 200,
                body: #"{"issuer":"https://auth.example","authorization_endpoint":"https://auth.example/oauth/authorize","token_endpoint":"https://auth.example/oauth/token","pushed_authorization_request_endpoint":"https://auth.example/oauth/par"}"#
            )
        case "/oauth/par":
            parAttempts += 1
            if parAttempts == 1 {
                return response(request: request, status: 401, body: "{}", headers: ["DPoP-Nonce": "par-nonce"])
            }
            return response(request: request, status: 200, body: #"{"request_uri":"urn:example:request","expires_in":60}"#)
        case "/oauth/token":
            return response(
                request: request,
                status: 200,
                body: #"{"access_token":"access","refresh_token":"refresh","expires_in":3600,"scope":"atproto","sub":"did:plc:resolved"}"#,
                headers: ["DPoP-Nonce": "token-nonce"]
            )
        default:
            return response(request: request, status: 404, body: "{}")
        }
    }

    private func response(request: URLRequest, status: Int, body: String, headers: [String: String] = [:]) -> (Data, URLResponse) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        return (Data(body.utf8), response)
    }
}

actor BlockingImageLoader: ImageLoading {
    private(set) var cancellationCount = 0

    func load(url: URL) async throws -> Data {
        do {
            try await Task.sleep(for: .seconds(10))
        } catch is CancellationError {
            cancellationCount += 1
            throw CancellationError()
        }
        return Data()
    }
}

struct FixedIdentityResolver: OAuthIdentityResolver {
    func resolve(handle: String) async throws -> ResolvedIdentity {
        ResolvedIdentity(did: "did:plc:resolved", pdsURL: URL(string: "https://pds.example")!)
    }
}
