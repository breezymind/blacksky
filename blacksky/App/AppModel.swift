import AppKit
import Foundation
import SwiftUI

enum AppAuthState: Equatable, Sendable {
    case restoring
    case loggedOut(message: String?)
    case authenticated
}

protocol URLHandler: Sendable {
    @discardableResult
    func open(_ url: URL) -> Bool
}

struct SystemURLHandler: URLHandler, Sendable {
    func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var authState: AppAuthState = .restoring
    @Published private(set) var session: OAuthSession?
    @Published var handleInput = ""
    @Published private(set) var authError: String?
    @Published private(set) var isAuthenticating = false
    @Published var selectedSection: Section = .feed

    let feed: FeedViewModel
    let following: FollowingViewModel

    private let credentialStore: any CredentialStore
    private let oauth: any OAuthAuthenticating
    private let urlHandler: any URLHandler
    private let cache: MemoryCache

    init(
        api: any BlueskyAPI = BlueskyAPIClient(),
        credentialStore: any CredentialStore = KeychainStore(),
        oauth: any OAuthAuthenticating = OAuthService(),
        urlHandler: any URLHandler = SystemURLHandler()
    ) {
        let cache = MemoryCache()
        self.cache = cache
        self.credentialStore = credentialStore
        self.oauth = oauth
        self.urlHandler = urlHandler
        self.feed = FeedViewModel(api: api, cache: cache)
        self.following = FollowingViewModel(api: api, cache: cache)
        self.feed.onSessionExpired = { [weak self] in self?.sessionExpired() }
        self.following.onSessionExpired = { [weak self] in self?.sessionExpired() }

        Task { [weak self] in
            await self?.restoreSession()
        }
    }

    func restoreSession() async {
        do {
            guard let stored = try credentialStore.load() else {
                authState = .loggedOut(message: nil)
                return
            }
            guard stored.canUseDPoP else {
                try? credentialStore.delete()
                authState = .loggedOut(message: "보안 세션을 새로 설정해야 합니다. 다시 로그인해 주세요.")
                return
            }
            let restored: OAuthSession
            if stored.isExpired {
                do {
                    restored = try await oauth.refresh(session: stored)
                    try credentialStore.save(restored)
                } catch {
                    try? credentialStore.delete()
                    authState = .loggedOut(message: "로그인 세션이 만료되었습니다. 다시 로그인해 주세요.")
                    return
                }
            } else {
                restored = stored
            }
            session = restored
            handleInput = restored.handle
            authState = .authenticated
        } catch {
            authState = .loggedOut(message: "저장된 세션을 복원하지 못했습니다. 다시 로그인해 주세요.")
        }
    }

    func startLogin() async {
        authError = nil
        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            let url = try await oauth.startLogin(handle: handleInput)
            if !urlHandler.open(url) {
                authError = "브라우저를 열 수 없습니다. 다시 시도해 주세요."
            }
        } catch {
            authError = (error as? LocalizedError)?.errorDescription ?? "로그인을 시작할 수 없습니다."
        }
    }

    func completeLogin(from callbackURL: URL) async {
        do {
            let newSession = try await oauth.completeLogin(callbackURL: callbackURL)
            try credentialStore.save(newSession)
            session = newSession
            handleInput = newSession.handle
            authError = nil
            authState = .authenticated
        } catch {
            authError = (error as? LocalizedError)?.errorDescription ?? "로그인에 실패했습니다."
            authState = .loggedOut(message: authError)
        }
    }

    func logout() {
        session = nil
        handleInput = ""
        feed.clear()
        following.clear()
        cache.clear()
        try? credentialStore.delete()
        authError = nil
        authState = .loggedOut(message: nil)
    }

    func sessionExpired() {
        session = nil
        handleInput = ""
        feed.clear()
        following.clear()
        cache.clear()
        try? credentialStore.delete()
        authState = .loggedOut(message: "세션이 만료되었습니다. 다시 로그인해 주세요.")
    }

    func openPost(_ post: FeedPost) {
        guard let url = BlueskyWebURL.post(uri: post.uri, handle: post.author.handle) else { return }
        _ = urlHandler.open(url)
    }

    func openProfile(_ profile: Profile) {
        guard let url = BlueskyWebURL.profile(handle: profile.handle) else { return }
        _ = urlHandler.open(url)
    }

    func openExternal(_ url: URL) {
        _ = urlHandler.open(url)
    }

    func refreshCurrentSection(_ section: Section) async {
        switch section {
        case .feed: await feed.refresh()
        case .following: break
        }
    }
}

enum BlueskyWebURL {
    static func profile(handle: String) -> URL? {
        URL(string: "https://bsky.app/profile/\(handle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? handle)")
    }

    static func post(uri: String, handle: String) -> URL? {
        let components = uri.split(separator: "/")
        guard let rkey = components.last else { return nil }
        guard let profileURL = profile(handle: handle) else { return nil }
        return profileURL.appendingPathComponent("post").appendingPathComponent(String(rkey))
    }
}
