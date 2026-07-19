import Foundation
import XCTest
@testable import blacksky

final class BlackskyTests: XCTestCase {
    @MainActor
    func testFeedPaginationUsesOpaqueCursorDeduplicatesAndAllowsOneLoadAtATime() async {
        let api = FakeBlueskyAPI()
        let first = makePost(uri: "at://did:plc:one/app.bsky.feed.post/one", text: "첫 글")
        let duplicate = makePost(uri: first.uri, text: "중복 글")
        let second = makePost(uri: "at://did:plc:one/app.bsky.feed.post/two", text: "둘째 글")
        await api.enqueueTimeline(FeedPage(posts: [first], cursor: "opaque cursor/?x=1"))
        await api.enqueueTimeline(FeedPage(posts: [duplicate, second], cursor: nil))

        let viewModel = FeedViewModel(api: api)
        let session = makeSession()
        await viewModel.loadInitial(session: session)
        async let firstLoad: Void = viewModel.loadMore()
        async let secondLoad: Void = viewModel.loadMore()
        _ = await (firstLoad, secondLoad)

        let calls = await api.timelineCalls
        XCTAssertEqual(calls, [nil, "opaque cursor/?x=1"])
        XCTAssertEqual(viewModel.posts.map(\.uri), [first.uri, second.uri])
    }

    @MainActor
    func testRefreshFailureKeepsExistingFeed() async {
        let api = FakeBlueskyAPI()
        let post = makePost(uri: "at://did:plc:one/app.bsky.feed.post/one", text: "기존 글")
        await api.enqueueTimeline(FeedPage(posts: [post], cursor: "next"))
        await api.enqueueTimelineError(BlueskyAPIError.transport("offline"))

        let viewModel = FeedViewModel(api: api)
        await viewModel.loadInitial(session: makeSession())
        await viewModel.refresh()

        XCTAssertEqual(viewModel.posts, [post])
        XCTAssertEqual(viewModel.state, .loaded)
        XCTAssertNotNil(viewModel.refreshError)
    }

    @MainActor
    func testFollowingPaginationDeduplicatesByDID() async {
        let api = FakeBlueskyAPI()
        let first = makeProfile(did: "did:plc:one", handle: "one.test")
        let duplicate = makeProfile(did: first.did, handle: "renamed.test")
        let second = makeProfile(did: "did:plc:two", handle: "two.test")
        await api.enqueueFollows(FollowingPage(profiles: [first], cursor: "opaque-follow-cursor"))
        await api.enqueueFollows(FollowingPage(profiles: [duplicate, second], cursor: nil))

        let viewModel = FollowingViewModel(api: api)
        await viewModel.loadInitial(session: makeSession())
        await viewModel.loadMore()

        XCTAssertEqual(viewModel.profiles.map(\.did), [first.did, second.did])
        let calls = await api.followCalls
        XCTAssertEqual(calls, [nil, "opaque-follow-cursor"] )
    }

    func testCredentialStoreRoundTripAndDeletion() throws {
        let store = InMemoryCredentialStore()
        let session = makeSession()
        try store.save(session)
        XCTAssertEqual(try store.load(), session)
        try store.delete()
        XCTAssertNil(try store.load())
        XCTAssertEqual(store.saveCount, 1)
        XCTAssertEqual(store.deleteCount, 1)
    }

    func testConfigurationUsesHostedMetadataAndRegistersOAuthCallback() {
        let configuration = OAuthClientConfiguration.development
        XCTAssertEqual(configuration.clientID, "https://breezymind.github.io/blacksky/oauth-client-metadata.json")
        XCTAssertEqual(configuration.redirectURI.absoluteString, "blacksky://oauth/callback")
        XCTAssertEqual(configuration.redirectURI.scheme, "blacksky")
    }

    func testTimelineAndFollowingRequestsUseReadOnlyEndpointLimits() async throws {
        let timelineClient = RecordingHTTPClient(payload: Data(#"{"cursor":"opaque-next","feed":[]}"#.utf8))
        let api = BlueskyAPIClient(httpClient: timelineClient)
        _ = try await api.getTimeline(session: makeSession(), cursor: "opaque cursor")
        let timelineRequestValue = await timelineClient.lastRequest
        let timelineRequest = try XCTUnwrap(timelineRequestValue)
        let timelineQuery = try XCTUnwrap(URLComponents(url: try XCTUnwrap(timelineRequest.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(timelineQuery.first(where: { $0.name == "limit" })?.value, "50")
        XCTAssertEqual(timelineQuery.first(where: { $0.name == "cursor" })?.value, "opaque cursor")
        XCTAssertEqual(timelineRequest.httpMethod, "GET")
        XCTAssertEqual(timelineRequest.url?.path, "/xrpc/app.bsky.feed.getTimeline")

        let followsClient = RecordingHTTPClient(payload: Data(#"{"cursor":null,"follows":[]}"#.utf8))
        let followsAPI = BlueskyAPIClient(httpClient: followsClient)
        _ = try await followsAPI.getFollows(session: makeSession(), cursor: nil)
        let followsRequestValue = await followsClient.lastRequest
        let followsRequest = try XCTUnwrap(followsRequestValue)
        let followsQuery = try XCTUnwrap(URLComponents(url: try XCTUnwrap(followsRequest.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(followsQuery.first(where: { $0.name == "actor" })?.value, "did:plc:test")
        XCTAssertEqual(followsQuery.first(where: { $0.name == "limit" })?.value, "100")
        XCTAssertEqual(followsRequest.httpMethod, "GET")
        XCTAssertEqual(followsRequest.url?.path, "/xrpc/app.bsky.graph.getFollows")
        XCTAssertFalse([timelineRequest, followsRequest].contains { $0.url?.path.contains(".create") == true })
    }

    func testBuiltAppMetadataRegistersDisplayNameAndOAuthCallback() throws {
        let testBundle = Bundle(for: BlackskyTests.self)
        let appURL = testBundle.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appBundle = try XCTUnwrap(Bundle(url: appURL))
        let info = try XCTUnwrap(appBundle.infoDictionary)

        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "blacksky")
        let urlTypes = try XCTUnwrap(info["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertTrue(schemes.contains("blacksky"))
        XCTAssertEqual(OAuthClientConfiguration.development.redirectURI.absoluteString, "blacksky://oauth/callback")
    }

    @MainActor
    func testSessionRestoreExpirationAndLogoutClearMemoryAndCredentials() async throws {
        let store = InMemoryCredentialStore()
        let session = makeSession()
        try store.save(session)
        let api = FakeBlueskyAPI()
        let app = AppModel(api: api, credentialStore: store, oauth: NoOpOAuth())
        await app.restoreSession()

        XCTAssertEqual(app.authState, .authenticated)
        XCTAssertEqual(app.session, session)

        await api.enqueueTimeline(FeedPage(posts: [makePost(uri: "at://did:plc:test/app.bsky.feed.post/one", text: "캐시될 글")], cursor: nil))
        await app.feed.loadInitial(session: session)
        XCTAssertFalse(app.feed.posts.isEmpty)

        app.logout()

        XCTAssertEqual(app.authState, .loggedOut(message: nil))
        XCTAssertNil(app.session)
        XCTAssertTrue(app.feed.posts.isEmpty)
        XCTAssertNil(try store.load())

        let expiredStore = InMemoryCredentialStore()
        let expired = OAuthSession(
            did: session.did,
            handle: session.handle,
            pdsURL: session.pdsURL,
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            expiresAt: Date().addingTimeInterval(-1),
            scope: session.scope,
            dpopKey: session.dpopKey,
            authorizationServer: session.authorizationServer,
            authorizationServerNonce: session.authorizationServerNonce,
            resourceServerNonce: session.resourceServerNonce
        )
        try expiredStore.save(expired)
        let expiredApp = AppModel(api: FakeBlueskyAPI(), credentialStore: expiredStore, oauth: NoOpOAuth())
        await expiredApp.restoreSession()

        XCTAssertEqual(expiredApp.authState, .loggedOut(message: "로그인 세션이 만료되었습니다. 다시 로그인해 주세요."))
        XCTAssertNil(try expiredStore.load())
    }

    func testTimelineResponseMapsRichReadOnlyPostContent() async throws {
        let client = RecordingHTTPClient(payload: timelinePayload(embed: richEmbed))
        let page = try await BlueskyAPIClient(httpClient: client).getTimeline(session: makeSession())
        let post = try XCTUnwrap(page.posts.first)

        XCTAssertEqual(post.text, "본문")
        XCTAssertTrue(post.isReply)
        XCTAssertEqual(post.replyParentAuthor?.handle, "parent.test")
        XCTAssertEqual(post.repostedBy?.handle, "reposter.test")
        XCTAssertEqual(post.replyCount, 2)
        XCTAssertEqual(post.repostCount, 3)
        XCTAssertEqual(post.likeCount, 4)
        XCTAssertEqual(post.labels, ["safe"])
        XCTAssertNotNil(post.createdAt)
        XCTAssertNotNil(post.indexedAt)

        XCTAssertEqual(post.attachments.count, 2)
        guard case .image(let imageURL, let altText) = post.attachments[0] else {
            return XCTFail("이미지 첨부가 매핑되지 않았습니다.")
        }
        XCTAssertEqual(imageURL.absoluteString, "https://cdn.example/image.jpg")
        XCTAssertEqual(altText, "설명")
        guard case .quote(let quote) = post.attachments[1] else {
            return XCTFail("인용 게시물이 매핑되지 않았습니다.")
        }
        XCTAssertEqual(quote.author.handle, "quoted.test")
        XCTAssertEqual(quote.text, "인용 본문")
    }

    func testTimelineResponseUsesLinkAndUnsupportedAttachmentFallbacks() async throws {
        let externalClient = RecordingHTTPClient(payload: timelinePayload(embed: externalEmbed))
        let externalPage = try await BlueskyAPIClient(httpClient: externalClient).getTimeline(session: makeSession())
        guard case .external(let title, let description, let url, let imageURL) = externalPage.posts[0].attachments[0] else {
            return XCTFail("외부 링크 카드가 매핑되지 않았습니다.")
        }
        XCTAssertEqual(title, "외부 링크")
        XCTAssertEqual(description, "링크 설명")
        XCTAssertEqual(url.absoluteString, "https://example.com/article")
        XCTAssertEqual(imageURL?.absoluteString, "https://cdn.example/thumb.jpg")

        let unsupportedClient = RecordingHTTPClient(payload: timelinePayload(embed: unsupportedEmbed))
        let unsupportedPage = try await BlueskyAPIClient(httpClient: unsupportedClient).getTimeline(session: makeSession())
        guard case .unsupported = unsupportedPage.posts[0].attachments[0] else {
            return XCTFail("지원하지 않는 첨부가 대체 상태로 매핑되지 않았습니다.")
        }
        XCTAssertEqual(PostAttachment.unsupported.accessibilityDescription, "이 콘텐츠는 현재 앱에서 표시할 수 없습니다.")
    }

    func testFollowingResponseMapsProfileDisplayFieldsVerificationAndLabels() async throws {
        let payload = Data(#"{"cursor":"next-follow","follows":[{"did":"did:plc:one","handle":"one.test","displayName":"One","avatar":"https://cdn.example/avatar.jpg","description":"한 줄 소개","labels":[{"val":"moderator"}],"verification":{"verifiedStatus":"valid"}}]}"#.utf8)
        let page = try await BlueskyAPIClient(httpClient: RecordingHTTPClient(payload: payload)).getFollows(session: makeSession())
        let profile = try XCTUnwrap(page.profiles.first)

        XCTAssertEqual(page.cursor, "next-follow")
        XCTAssertEqual(profile.did, "did:plc:one")
        XCTAssertEqual(profile.preferredName, "One")
        XCTAssertEqual(profile.avatarURL?.absoluteString, "https://cdn.example/avatar.jpg")
        XCTAssertEqual(profile.description, "한 줄 소개")
        XCTAssertTrue(profile.isVerified)
        XCTAssertEqual(profile.labels, ["moderator"])
    }

    @MainActor
    func testRemoteImageCancelsRequestWhenViewDisappears() async {
        let loader = BlockingImageLoader()
        let model = RemoteImageModel(loader: loader)
        model.load(url: URL(string: "https://cdn.example/image.jpg"))
        await Task.yield()
        model.cancel()

        for _ in 0..<10 {
            if await loader.cancellationCount > 0 { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("이미지 요청이 취소되지 않았습니다.")
    }

    func testOAuthUsesDiscoveryPARPKCEDPoPAndCallbackWithoutPasswordInput() async throws {
        let configuration = OAuthClientConfiguration(
            clientID: "https://client.example/metadata.json",
            redirectURI: URL(string: "blacksky://oauth/callback")!,
            scope: "atproto"
        )
        let resolver = FixedIdentityResolver()
        let httpClient = OAuthFixtureHTTPClient()
        let service = OAuthService(configuration: configuration, identityResolver: resolver, httpClient: httpClient)
        let authorizationURL = try await service.startLogin(handle: "reader.test")
        let authorizationComponents = try XCTUnwrap(URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false))
        let authorizationQuery = try XCTUnwrap(authorizationComponents.queryItems)
        let requestsAfterStart = await httpClient.requests
        let parBody = try XCTUnwrap(requestsAfterStart.last { $0.url?.path == "/oauth/par" }?.httpBody)
        let parItems = try XCTUnwrap(URLComponents(string: "?\(String(data: parBody, encoding: .utf8) ?? "")")?.queryItems)
        let state = try XCTUnwrap(parItems.first(where: { $0.name == "state" })?.value)
        XCTAssertEqual(authorizationComponents.host, "auth.example")
        XCTAssertEqual(authorizationComponents.path, "/oauth/authorize")
        XCTAssertEqual(authorizationQuery.first(where: { $0.name == "request_uri" })?.value, "urn:example:request")
        XCTAssertNil(authorizationQuery.first(where: { $0.name == "password" }))

        let requests = await httpClient.requests
        XCTAssertEqual(requests.filter { $0.url?.path == "/oauth/par" }.count, 2)
        let parRequest = try XCTUnwrap(requests.first { $0.url?.path == "/oauth/par" })
        XCTAssertEqual(parRequest.value(forHTTPHeaderField: "DPoP")?.split(separator: ".").count, 3)
        XCTAssertTrue(String(data: parRequest.httpBody ?? Data(), encoding: .utf8)?.contains("code_challenge") == true)

        let callback = URL(string: "blacksky://oauth/callback?code=test-code&state=\(state)")!
        let session = try await service.completeLogin(callbackURL: callback)
        XCTAssertEqual(session.did, "did:plc:resolved")
        XCTAssertEqual(session.handle, "reader.test")
        XCTAssertEqual(session.accessToken, "access")
        XCTAssertEqual(session.refreshToken, "refresh")
        XCTAssertNotNil(session.dpopKey)
        XCTAssertEqual(session.authorizationServerNonce, "token-nonce")
    }

    private func makeSession() -> OAuthSession {
        OAuthSession(
            did: "did:plc:test",
            handle: "reader.test",
            pdsURL: URL(string: "https://pds.example")!,
            accessToken: "access-token-for-test",
            refreshToken: "refresh-token-for-test",
            expiresAt: Date().addingTimeInterval(3600),
            scope: "atproto",
            dpopKey: .testing
        )
    }

    private func makeProfile(did: String, handle: String) -> Profile {
        Profile(did: did, handle: handle, displayName: handle, avatarURL: nil, description: "소개", isVerified: false, labels: [])
    }

    private func makePost(uri: String, text: String) -> FeedPost {
        FeedPost(uri: uri, cid: "cid-\(uri)", author: makeProfile(did: "did:plc:author", handle: "author.test"), text: text, createdAt: nil, indexedAt: nil, replyCount: 1, repostCount: 2, likeCount: 3, isReply: false, replyParentAuthor: nil, repostedBy: nil, attachments: [], labels: [])
    }

    private var richEmbed: String {
        #"{"$type":"app.bsky.embed.recordWithMedia#view","media":{"$type":"app.bsky.embed.images#view","images":[{"fullsize":"https://cdn.example/image.jpg","alt":"설명"}]},"record":{"uri":"at://did:plc:quoted/app.bsky.feed.post/quoted","author":{"did":"did:plc:quoted","handle":"quoted.test","displayName":"Quoted","labels":[]},"value":{"text":"인용 본문"}}}"#
    }

    private var externalEmbed: String {
        #"{"$type":"app.bsky.embed.external#view","external":{"uri":"https://example.com/article","title":"외부 링크","description":"링크 설명","thumb":"https://cdn.example/thumb.jpg"}}"#
    }

    private var unsupportedEmbed: String {
        #"{"$type":"app.bsky.embed.unknown#view"}"#
    }

    private func timelinePayload(embed: String) -> Data {
        Data("""
        {
          "cursor": "opaque-next",
          "feed": [{
            "post": {
              "uri": "at://did:plc:author/app.bsky.feed.post/one",
              "cid": "cid-one",
              "author": {"did": "did:plc:author", "handle": "author.test", "displayName": "Author", "avatar": null, "description": null, "labels": []},
              "record": {"text": "본문", "createdAt": "2026-01-01T00:00:00Z", "reply": {"parent": {"author": {"did": "did:plc:parent", "handle": "parent.test", "displayName": "Parent", "labels": []}}}},
              "embed": \(embed),
              "replyCount": 2,
              "repostCount": 3,
              "likeCount": 4,
              "indexedAt": "2026-01-01T00:01:00Z",
              "labels": [{"val": "safe"}]
            },
            "reason": {"$type": "app.bsky.feed.defs#reasonRepost", "by": {"did": "did:plc:reposter", "handle": "reposter.test", "displayName": "Reposter", "labels": []}}
          }]
        }
        """.utf8)
    }
}

private actor FakeBlueskyAPI: BlueskyAPI {
    private(set) var timelineCalls: [String?] = []
    private(set) var followCalls: [String?] = []
    private var timelineResults: [Result<FeedPage, Error>] = []
    private var followResults: [Result<FollowingPage, Error>] = []

    func enqueueTimeline(_ page: FeedPage) { timelineResults.append(.success(page)) }
    func enqueueTimelineError(_ error: Error) { timelineResults.append(.failure(error)) }
    func enqueueFollows(_ page: FollowingPage) { followResults.append(.success(page)) }

    func getTimeline(session: OAuthSession, cursor: String?) async throws -> FeedPage {
        timelineCalls.append(cursor)
        try? await Task.sleep(for: .milliseconds(30))
        guard !timelineResults.isEmpty else { throw BlueskyAPIError.transport("no fixture") }
        let result = timelineResults.removeFirst()
        return try result.get()
    }

    func getFollows(session: OAuthSession, cursor: String?) async throws -> FollowingPage {
        followCalls.append(cursor)
        guard !followResults.isEmpty else { throw BlueskyAPIError.transport("no fixture") }
        let result = followResults.removeFirst()
        return try result.get()
    }
}
