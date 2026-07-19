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
