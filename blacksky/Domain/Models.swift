import CryptoKit
import Foundation

struct DPoPKeyMaterial: Codable, Equatable, Sendable {
    let dataRepresentation: Data
    let usesSecureEnclave: Bool

    static func generate() -> DPoPKeyMaterial {
        if let key = try? SecureEnclave.P256.Signing.PrivateKey() {
            return DPoPKeyMaterial(dataRepresentation: key.dataRepresentation, usesSecureEnclave: true)
        }
        return DPoPKeyMaterial(
            dataRepresentation: P256.Signing.PrivateKey().rawRepresentation,
            usesSecureEnclave: false
        )
    }

    static let testing = DPoPKeyMaterial(
        dataRepresentation: P256.Signing.PrivateKey().rawRepresentation,
        usesSecureEnclave: false
    )

    func sign(_ data: Data) throws -> Data {
        if usesSecureEnclave {
            let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: dataRepresentation)
            return try key.signature(for: data).rawRepresentation
        }
        let key = try P256.Signing.PrivateKey(rawRepresentation: dataRepresentation)
        return try key.signature(for: data).rawRepresentation
    }

    var publicJWK: [String: String] {
        get throws {
            let raw: Data
            if usesSecureEnclave {
                raw = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: dataRepresentation).publicKey.rawRepresentation
            } else {
                raw = try P256.Signing.PrivateKey(rawRepresentation: dataRepresentation).publicKey.rawRepresentation
            }
            guard raw.count == 64 else { throw DPoPError.invalidKey }
            return [
                "kty": "EC",
                "crv": "P-256",
                "x": raw.prefix(32).base64URLEncoded,
                "y": raw.suffix(32).base64URLEncoded
            ]
        }
    }
}

enum DPoPError: Error, Equatable, Sendable {
    case invalidKey
    case signingFailed
}

struct OAuthSession: Codable, Equatable, Sendable {
    let did: String
    let handle: String
    let pdsURL: URL
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let scope: String
    let dpopKey: DPoPKeyMaterial?
    let authorizationServer: URL?
    let authorizationServerNonce: String?
    let resourceServerNonce: String?

    init(
        did: String,
        handle: String,
        pdsURL: URL,
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        scope: String,
        dpopKey: DPoPKeyMaterial? = nil,
        authorizationServer: URL? = nil,
        authorizationServerNonce: String? = nil,
        resourceServerNonce: String? = nil
    ) {
        self.did = did
        self.handle = handle
        self.pdsURL = pdsURL
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
        self.dpopKey = dpopKey
        self.authorizationServer = authorizationServer
        self.authorizationServerNonce = authorizationServerNonce
        self.resourceServerNonce = resourceServerNonce
    }

    var isExpired: Bool {
        expiresAt <= Date().addingTimeInterval(60)
    }

    var canUseDPoP: Bool { dpopKey != nil }
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

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}

enum DPoPProofBuilder {
    static func make(
        key: DPoPKeyMaterial,
        method: String,
        url: URL,
        nonce: String?,
        accessToken: String? = nil
    ) throws -> String {
        let header: [String: Any] = [
            "typ": "dpop+jwt",
            "alg": "ES256",
            "jwk": try key.publicJWK
        ]
        var payload: [String: Any] = [
            "jti": UUID().uuidString,
            "htm": method.uppercased(),
            "htu": url.withoutQuery.absoluteString,
            "iat": Int(Date().timeIntervalSince1970)
        ]
        if let nonce, !nonce.isEmpty { payload["nonce"] = nonce }
        if let accessToken {
            payload["ath"] = SHA256.hash(data: Data(accessToken.utf8)).withUnsafeBytes { Data($0).base64URLEncoded }
        }
        let encodedHeader = try jsonData(header).base64URLEncoded
        let encodedPayload = try jsonData(payload).base64URLEncoded
        let signingInput = Data("\(encodedHeader).\(encodedPayload)".utf8)
        let signature = try key.sign(signingInput).base64URLEncoded
        return "\(encodedHeader).\(encodedPayload).\(signature)"
    }

    private static func jsonData(_ value: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(value) else { throw DPoPError.signingFailed }
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
}

extension URL {
    var withoutQuery: URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
        components.query = nil
        components.fragment = nil
        return components.url ?? self
    }
}
