import Foundation
import SwiftUI

@MainActor
final class FeedViewModel: ObservableObject {
    @Published private(set) var posts: [FeedPost] = []
    @Published private(set) var state: ContentState = .idle
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var loadMoreError: String?
    @Published private(set) var refreshError: String?

    private let api: any BlueskyAPI
    private let cache: MemoryCache
    private var cursor: String?
    private var session: OAuthSession?
    var onSessionExpired: (() -> Void)?

    init(api: any BlueskyAPI, cache: MemoryCache = MemoryCache()) {
        self.api = api
        self.cache = cache
    }

    func loadInitial(session: OAuthSession) async {
        self.session = session
        state = .loading
        loadMoreError = nil
        refreshError = nil
        do {
            let page = try await api.getTimeline(session: session, cursor: nil)
            posts = Self.deduplicated(page.posts)
            cursor = page.cursor
            cache.storeFeed(posts)
            state = posts.isEmpty ? .empty : .loaded
        } catch {
            apply(error: error)
        }
    }

    func refresh() async {
        guard let session else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        loadMoreError = nil
        refreshError = nil
        defer { isRefreshing = false }
        do {
            let page = try await api.getTimeline(session: session, cursor: nil)
            let refreshed = Self.deduplicated(page.posts)
            posts = refreshed
            cursor = page.cursor
            cache.storeFeed(posts)
            state = posts.isEmpty ? .empty : .loaded
        } catch {
            // Keep the previous collection; only its error state changes.
            if isSessionExpired(error) {
                state = .sessionExpired
                onSessionExpired?()
            } else {
                refreshError = errorMessage(error)
            }
        }
    }

    func loadMore() async {
        guard let session, let cursor, !cursor.isEmpty, !isLoadingMore else { return }
        isLoadingMore = true
        loadMoreError = nil
        defer { isLoadingMore = false }
        do {
            let page = try await api.getTimeline(session: session, cursor: cursor)
            posts = Self.deduplicated(posts + page.posts)
            self.cursor = page.cursor
            cache.storeFeed(posts)
            state = posts.isEmpty ? .empty : .loaded
        } catch {
            loadMoreError = errorMessage(error)
            if isSessionExpired(error) {
                state = .sessionExpired
                onSessionExpired?()
            }
        }
    }

    func retryLoadMore() async {
        await loadMore()
    }

    func clear() {
        posts = []
        cursor = nil
        session = nil
        state = .idle
        isRefreshing = false
        isLoadingMore = false
        loadMoreError = nil
        refreshError = nil
    }

    private func apply(error: Error, preserveExistingState: Bool = false) {
        if isSessionExpired(error) {
            state = .sessionExpired
            onSessionExpired?()
            return
        }
        if !preserveExistingState || posts.isEmpty {
            state = .failed(errorMessage(error))
        }
        loadMoreError = errorMessage(error)
    }

    private func isSessionExpired(_ error: Error) -> Bool {
        if case BlueskyAPIError.unauthorized = error { return true }
        return false
    }

    private func errorMessage(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "네트워크 오류가 발생했습니다."
    }

    static func deduplicated(_ posts: [FeedPost]) -> [FeedPost] {
        var seen = Set<String>()
        return posts.filter { seen.insert($0.uri).inserted }
    }
}

@MainActor
final class FollowingViewModel: ObservableObject {
    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var state: ContentState = .idle
    @Published private(set) var isLoadingMore = false
    @Published private(set) var loadMoreError: String?

    private let api: any BlueskyAPI
    private let cache: MemoryCache
    private var cursor: String?
    private var session: OAuthSession?
    var onSessionExpired: (() -> Void)?

    init(api: any BlueskyAPI, cache: MemoryCache = MemoryCache()) {
        self.api = api
        self.cache = cache
    }

    func loadInitial(session: OAuthSession) async {
        self.session = session
        state = .loading
        loadMoreError = nil
        do {
            let page = try await api.getFollows(session: session, cursor: nil)
            profiles = Self.deduplicated(page.profiles)
            cursor = page.cursor
            cache.storeFollowing(profiles)
            state = profiles.isEmpty ? .empty : .loaded
        } catch {
            apply(error: error)
        }
    }

    func loadMore() async {
        guard let session, let cursor, !cursor.isEmpty, !isLoadingMore else { return }
        isLoadingMore = true
        loadMoreError = nil
        defer { isLoadingMore = false }
        do {
            let page = try await api.getFollows(session: session, cursor: cursor)
            profiles = Self.deduplicated(profiles + page.profiles)
            self.cursor = page.cursor
            cache.storeFollowing(profiles)
            state = profiles.isEmpty ? .empty : .loaded
        } catch {
            loadMoreError = errorMessage(error)
            if isSessionExpired(error) {
                state = .sessionExpired
                onSessionExpired?()
            }
        }
    }

    func retryLoadMore() async {
        await loadMore()
    }

    func clear() {
        profiles = []
        cursor = nil
        session = nil
        state = .idle
        isLoadingMore = false
        loadMoreError = nil
    }

    private func apply(error: Error) {
        if isSessionExpired(error) {
            state = .sessionExpired
            onSessionExpired?()
            return
        }
        state = .failed(errorMessage(error))
        loadMoreError = errorMessage(error)
    }

    private func isSessionExpired(_ error: Error) -> Bool {
        if case BlueskyAPIError.unauthorized = error { return true }
        return false
    }

    private func errorMessage(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "네트워크 오류가 발생했습니다."
    }

    static func deduplicated(_ profiles: [Profile]) -> [Profile] {
        var seen = Set<String>()
        return profiles.filter { seen.insert($0.did).inserted }
    }
}

final class MemoryCache: @unchecked Sendable {
    private let lock = NSLock()
    private var feed: [FeedPost] = []
    private var following: [Profile] = []

    func storeFeed(_ posts: [FeedPost]) {
        lock.lock(); defer { lock.unlock() }
        feed = posts
    }

    func storeFollowing(_ profiles: [Profile]) {
        lock.lock(); defer { lock.unlock() }
        following = profiles
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        feed.removeAll()
        following.removeAll()
    }
}
