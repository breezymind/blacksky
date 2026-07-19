import Foundation

struct OAuthSession: Codable, Equatable, Sendable {
    let did: String
    let handle: String
    let pdsURL: URL
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let scope: String

    var isExpired: Bool {
        expiresAt <= Date().addingTimeInterval(60)
    }
}

struct Profile: Codable, Equatable, Identifiable, Sendable {
    let did: String
    let handle: String
    let displayName: String?
    let avatarURL: URL?
    let description: String?
    let isVerified: Bool
    let labels: [String]

    var id: String { did }
    var preferredName: String { displayName?.isEmpty == false ? displayName! : handle }
}

struct QuotePost: Equatable, Sendable {
    let uri: String
    let author: Profile
    let text: String
}

enum PostAttachment: Equatable, Sendable {
    case image(url: URL, altText: String)
    case external(title: String, description: String?, url: URL, imageURL: URL?)
    case quote(QuotePost)
    case video(thumbnailURL: URL?, altText: String?)
    case unsupported

    var accessibilityDescription: String {
        switch self {
        case .image(_, let altText):
            return altText.isEmpty ? "이미지" : "이미지: \(altText)"
        case .external(let title, _, _, _):
            return "외부 링크: \(title)"
        case .quote(let post):
            return "인용 게시물: \(post.author.preferredName), \(post.text)"
        case .video:
            return "동영상 썸네일"
        case .unsupported:
            return "이 콘텐츠는 현재 앱에서 표시할 수 없습니다."
        }
    }
}

struct FeedPost: Equatable, Identifiable, Sendable {
    let uri: String
    let cid: String
    let author: Profile
    let text: String
    let createdAt: Date?
    let indexedAt: Date?
    let replyCount: Int
    let repostCount: Int
    let likeCount: Int
    let isReply: Bool
    let replyParentAuthor: Profile?
    let repostedBy: Profile?
    let attachments: [PostAttachment]
    let labels: [String]

    var id: String { uri }

    var accessibilitySummary: String {
        let body = text.isEmpty ? "본문 없음" : text
        let attachmentText = attachments.map(\.accessibilityDescription).joined(separator: ", ")
        let time = createdAt.map(Self.dateFormatter.string) ?? "시간 없음"
        return [author.preferredName, body, attachmentText, time]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

struct FeedPage: Equatable, Sendable {
    let posts: [FeedPost]
    let cursor: String?
}

struct FollowingPage: Equatable, Sendable {
    let profiles: [Profile]
    let cursor: String?
}

enum Section: String, CaseIterable, Identifiable, Sendable {
    case feed
    case following

    var id: String { rawValue }
    var title: String {
        switch self {
        case .feed: return "피드"
        case .following: return "팔로잉"
        }
    }
    var systemImage: String {
        switch self {
        case .feed: return "house"
        case .following: return "person.2"
        }
    }
}

enum ContentState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case empty
    case failed(String)
    case sessionExpired
}

extension Date {
    static func parseISO8601(_ value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }
}
