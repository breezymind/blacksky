import Foundation

protocol BlueskyAPI: Sendable {
    func getTimeline(session: OAuthSession, cursor: String?) async throws -> FeedPage
    func getFollows(session: OAuthSession, cursor: String?) async throws -> FollowingPage
}

protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionHTTPClient: HTTPClient {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

enum BlueskyAPIError: Error, Equatable, LocalizedError, Sendable {
    case unauthorized
    case httpStatus(Int)
    case malformedURL
    case invalidResponse
    case decoding(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "세션이 만료되었습니다. 다시 로그인해 주세요."
        case .httpStatus: return "네트워크 오류가 발생했습니다."
        case .malformedURL, .invalidResponse, .decoding: return "응답을 읽을 수 없습니다."
        case .transport: return "네트워크 오류가 발생했습니다."
        }
    }
}

struct BlueskyAPIClient: BlueskyAPI, Sendable {
    private let httpClient: any HTTPClient
    private let decoder: JSONDecoder

    init(httpClient: any HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
        self.decoder = JSONDecoder()
    }

    func getTimeline(session: OAuthSession, cursor: String? = nil) async throws -> FeedPage {
        let url = try xrpcURL(base: session.pdsURL, method: "app.bsky.feed.getTimeline", query: [
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "cursor", value: cursor)
        ])
        let response: TimelineResponse = try await get(url: url, session: session)
        return FeedPage(posts: response.feed.compactMap { $0.makeFeedPost() }, cursor: response.cursor)
    }

    func getFollows(session: OAuthSession, cursor: String? = nil) async throws -> FollowingPage {
        let url = try xrpcURL(base: session.pdsURL, method: "app.bsky.graph.getFollows", query: [
            URLQueryItem(name: "actor", value: session.did),
            URLQueryItem(name: "limit", value: "100"),
            URLQueryItem(name: "cursor", value: cursor)
        ])
        let response: FollowsResponse = try await get(url: url, session: session)
        return FollowingPage(profiles: response.follows.map(\.profile), cursor: response.cursor)
    }

    private func get<Response: Decodable>(url: URL, session: OAuthSession) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await httpClient.send(request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw BlueskyAPIError.invalidResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                if httpResponse.statusCode == 401 { throw BlueskyAPIError.unauthorized }
                throw BlueskyAPIError.httpStatus(httpResponse.statusCode)
            }
            do {
                return try decoder.decode(Response.self, from: data)
            } catch {
                throw BlueskyAPIError.decoding(error.localizedDescription)
            }
        } catch let error as BlueskyAPIError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BlueskyAPIError.transport(error.localizedDescription)
        }
    }

    private func xrpcURL(base: URL, method: String, query: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw BlueskyAPIError.malformedURL
        }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/xrpc/" + method
        components.queryItems = query.filter { $0.value != nil }
        guard let url = components.url else { throw BlueskyAPIError.malformedURL }
        return url
    }
}

private struct TimelineResponse: Decodable {
    let cursor: String?
    let feed: [RawFeedItem]
}

private struct FollowsResponse: Decodable {
    let cursor: String?
    let follows: [RawFollow]
}

private struct RawFollow: Decodable {
    let did: String
    let handle: String
    let displayName: String?
    let avatar: String?
    let description: String?
    let labels: [RawLabel]
    let verification: JSONValue?

    var profile: Profile {
        Profile(
            did: did,
            handle: handle,
            displayName: displayName,
            avatarURL: avatar.flatMap(URL.init(string:)),
            description: description,
            isVerified: verification?.object?["verifiedStatus"]?.string == "valid",
            labels: labels.map(\.val)
        )
    }
}

private struct RawFeedItem: Decodable {
    let post: RawPost
    let reason: JSONValue?

    func makeFeedPost() -> FeedPost? {
        post.makeFeedPost(repostedBy: reason?.reposter)
    }
}

private struct RawPost: Decodable {
    let uri: String
    let cid: String
    let author: RawAuthor
    let record: JSONValue
    let embed: JSONValue?
    let replyCount: Int?
    let repostCount: Int?
    let likeCount: Int?
    let indexedAt: String?
    let labels: [RawLabel]

    func makeFeedPost(repostedBy: Profile? = nil) -> FeedPost? {
        let recordObject = record.object ?? [:]
        let text = recordObject["text"]?.string ?? ""
        let createdAt = Date.parseISO8601(recordObject["createdAt"]?.string)
        let replyObject = recordObject["reply"]?.object
        let parentAuthor = replyObject?["parent"]?.object?["author"].flatMap(RawAuthor.init(value:))?.profile
        let attachments = AttachmentParser.parse(embed: embed)
        return FeedPost(
            uri: uri,
            cid: cid,
            author: author.profile,
            text: text,
            createdAt: createdAt,
            indexedAt: Date.parseISO8601(indexedAt),
            replyCount: replyCount ?? 0,
            repostCount: repostCount ?? 0,
            likeCount: likeCount ?? 0,
            isReply: replyObject != nil,
            replyParentAuthor: parentAuthor,
            repostedBy: repostedBy,
            attachments: attachments,
            labels: labels.map(\.val)
        )
    }
}

private struct RawAuthor: Decodable {
    let did: String
    let handle: String
    let displayName: String?
    let avatar: String?
    let description: String?
    let labels: [RawLabel]
    let verification: JSONValue?

    init(value: JSONValue) {
        let object = value.object ?? [:]
        did = object["did"]?.string ?? ""
        handle = object["handle"]?.string ?? ""
        displayName = object["displayName"]?.string
        avatar = object["avatar"]?.string
        description = object["description"]?.string
        labels = (object["labels"]?.array ?? []).compactMap(RawLabel.init(value:))
        verification = object["verification"]
    }

    var profile: Profile {
        Profile(
            did: did,
            handle: handle,
            displayName: displayName,
            avatarURL: avatar.flatMap(URL.init(string:)),
            description: description,
            isVerified: verification?.object?["verifiedStatus"]?.string == "valid",
            labels: labels.map(\.val)
        )
    }
}

private struct RawLabel: Decodable {
    let val: String

    init(value: JSONValue) {
        val = value.object?["val"]?.string ?? ""
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        val = try container.decodeIfPresent(String.self, forKey: .val) ?? ""
    }

    private enum CodingKeys: String, CodingKey { case val }
}

private enum AttachmentParser {
    static func parse(embed: JSONValue?) -> [PostAttachment] {
        guard let object = embed?.object else { return [] }
        let type = object["$type"]?.string ?? ""
        switch type {
        case "app.bsky.embed.images#view":
            let images = (object["images"]?.array ?? []).compactMap { image -> PostAttachment? in
                guard let imageObject = image.object,
                      let urlString = imageObject["fullsize"]?.string ?? imageObject["thumb"]?.string,
                      let url = URL(string: urlString) else { return nil }
                return .image(url: url, altText: imageObject["alt"]?.string ?? "")
            }
            return images.isEmpty ? [.unsupported] : images
        case "app.bsky.embed.external#view":
            guard let external = object["external"]?.object,
                  let urlString = external["uri"]?.string,
                  let url = URL(string: urlString) else { return [.unsupported] }
            return [.external(
                title: external["title"]?.string ?? urlString,
                description: external["description"]?.string,
                url: url,
                imageURL: external["thumb"]?.string.flatMap(URL.init(string:))
            )]
        case "app.bsky.embed.record#view":
            return parseQuote(object["record"])
        case "app.bsky.embed.recordWithMedia#view":
            var attachments = parseMedia(object["media"])
            attachments.append(contentsOf: parseQuote(object["record"]))
            return attachments.isEmpty ? [.unsupported] : attachments
        case "app.bsky.embed.video#view":
            return [.video(thumbnailURL: object["thumbnail"]?.string.flatMap(URL.init(string:)), altText: object["alt"]?.string)]
        default:
            return [.unsupported]
        }
    }

    private static func parseMedia(_ value: JSONValue?) -> [PostAttachment] {
        guard let object = value?.object else { return [.unsupported] }
        let type = object["$type"]?.string ?? ""
        if type == "app.bsky.embed.images#view" {
            return parse(embed: value)
        }
        if type == "app.bsky.embed.external#view" {
            return parse(embed: value)
        }
        return [.unsupported]
    }

    private static func parseQuote(_ value: JSONValue?) -> [PostAttachment] {
        guard let object = value?.object,
              let uri = object["uri"]?.string,
              let authorValue = object["author"] else { return [.unsupported] }
        let author = RawAuthor(value: authorValue).profile
        let text = object["value"]?.object?["text"]?.string ?? object["text"]?.string ?? ""
        return [.quote(QuotePost(uri: uri, author: author, text: text))]
    }
}

private enum JSONValue: Decodable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let object = try? container.decode([String: JSONValue].self) { self = .object(object); return }
        if let array = try? container.decode([JSONValue].self) { self = .array(array); return }
        if let string = try? container.decode(String.self) { self = .string(string); return }
        if let bool = try? container.decode(Bool.self) { self = .bool(bool); return }
        if let number = try? container.decode(Double.self) { self = .number(number); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "지원하지 않는 JSON 값")
    }

    var object: [String: JSONValue]? { if case .object(let value) = self { return value }; return nil }
    var array: [JSONValue]? { if case .array(let value) = self { return value }; return nil }
    var string: String? { if case .string(let value) = self { return value }; return nil }
    var reposter: Profile? {
        guard object?["$type"]?.string == "app.bsky.feed.defs#reasonRepost",
              let by = object?["by"] else { return nil }
        return RawAuthor(value: by).profile
    }
}
