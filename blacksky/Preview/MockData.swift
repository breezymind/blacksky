import Foundation
import SwiftUI

#if DEBUG
private struct MockBlueskyAPI: BlueskyAPI {
    func getTimeline(session: OAuthSession, cursor: String?) async throws -> FeedPage {
        FeedPage(posts: [
            FeedPost(
                uri: "at://did:plc:mock/app.bsky.feed.post/one",
                cid: "bafymock1",
                author: Profile(did: "did:plc:mock", handle: "reader.example", displayName: "Mock Reader", avatarURL: nil, description: "읽기 전용 미리보기", isVerified: true, labels: []),
                text: "blacksky의 피드 미리보기입니다.",
                createdAt: Date().addingTimeInterval(-900),
                indexedAt: Date().addingTimeInterval(-900),
                replyCount: 2,
                repostCount: 4,
                likeCount: 12,
                isReply: false,
                replyParentAuthor: nil,
                repostedBy: nil,
                attachments: [.unsupported],
                labels: []
            )
        ], cursor: nil)
    }

    func getFollows(session: OAuthSession, cursor: String?) async throws -> FollowingPage {
        FollowingPage(profiles: [
            Profile(did: "did:plc:mock-follow", handle: "following.example", displayName: "Mock Following", avatarURL: nil, description: "팔로잉 목록 미리보기", isVerified: false, labels: ["preview"])
        ], cursor: nil)
    }
}

private struct MockPreview: View {
    @StateObject private var app: AppModel

    init() {
        let store = InMemoryCredentialStore()
        try? store.save(OAuthSession(
            did: "did:plc:mock",
            handle: "reader.example",
            pdsURL: URL(string: "https://pds.example")!,
            accessToken: "preview-access",
            refreshToken: "preview-refresh",
            expiresAt: Date().addingTimeInterval(3600),
            scope: "atproto"
        ))
        _app = StateObject(wrappedValue: AppModel(api: MockBlueskyAPI(), credentialStore: store))
    }

    var body: some View {
        MainShellView()
            .environmentObject(app)
            .frame(width: 980, height: 720)
    }
}

#Preview("Mock 피드와 팔로잉") {
    MockPreview()
}
#endif
