import SwiftUI

struct FeedView: View {
    @ObservedObject var viewModel: FeedViewModel
    @EnvironmentObject private var app: AppModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if viewModel.posts.isEmpty {
                    emptyOrLoading
                } else {
                    ForEach(viewModel.posts) { post in
                        PostCard(post: post)
                            .onAppear {
                                if post.id == viewModel.posts.last?.id {
                                    Task { await viewModel.loadMore() }
                                }
                            }
                    }
                    if let error = viewModel.refreshError {
                        RetryRow(message: error) {
                            await viewModel.refresh()
                        }
                    }
                    if let error = viewModel.loadMoreError {
                        RetryRow(message: error) {
                            await viewModel.retryLoadMore()
                        }
                    } else if viewModel.isLoadingMore {
                        ProgressView("더 불러오는 중…")
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                }
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .navigationTitle("피드")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Label("새로고침", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(viewModel.isRefreshing)
                .accessibilityLabel("피드 새로고침")
            }
        }
    }

    @ViewBuilder
    private var emptyOrLoading: some View {
        switch viewModel.state {
        case .loading:
            ForEach(0..<5, id: \.self) { _ in SkeletonPostRow() }
        case .empty:
            EmptyState(title: "피드가 비어 있습니다.", systemImage: "tray")
        case .failed(let message):
            ErrorState(message: message) {
                if let session = app.session { await viewModel.loadInitial(session: session) }
            }
        case .sessionExpired:
            EmptyState(title: "세션이 만료되었습니다. 다시 로그인해 주세요.", systemImage: "lock")
        default:
            EmptyState(title: "피드를 불러올 수 없습니다.", systemImage: "wifi.exclamationmark")
        }
    }
}

private struct PostCard: View {
    let post: FeedPost
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let repostedBy = post.repostedBy {
                Label("\(repostedBy.preferredName)이 재게시함", systemImage: "arrow.2.squarepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("재게시한 사용자 \(repostedBy.preferredName)")
            }
            HStack(alignment: .top, spacing: 10) {
                ProfileAvatar(profile: post.author)
                VStack(alignment: .leading, spacing: 3) {
                    Button {
                        app.openProfile(post.author)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(post.author.preferredName).fontWeight(.semibold)
                            Text("@\(post.author.handle)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("작성자 \(post.author.preferredName), 핸들 \(post.author.handle)")
                    if post.isReply {
                        Text("답글")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            if let parent = post.replyParentAuthor {
                Text("\(parent.preferredName)에게 답글")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                app.openPost(post)
            } label: {
                VStack(alignment: .leading, spacing: 12) {
                    Text(post.text.isEmpty ? " " : post.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("본문: \(post.text.isEmpty ? "본문 없음" : post.text)")

                    ForEach(Array(post.attachments.enumerated()), id: \.offset) { _, attachment in
                        AttachmentView(attachment: attachment)
                    }

                    HStack(spacing: 18) {
                        StatLabel(value: post.replyCount, title: "답글", systemImage: "bubble")
                        StatLabel(value: post.repostCount, title: "재게시", systemImage: "arrow.2.squarepath")
                        StatLabel(value: post.likeCount, title: "좋아요", systemImage: "heart")
                        if !post.labels.isEmpty {
                            Label(post.labels.joined(separator: ", "), systemImage: "tag")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .buttonStyle(.plain)
            .focusable()
            .accessibilityHint("Return 키로 Bluesky 게시물을 엽니다")
            if let date = post.createdAt {
                Text(date, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("작성 시간 \(date.formatted(date: .abbreviated, time: .shortened))")
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(post.accessibilitySummary)
        .accessibilityHint("Return 키로 Bluesky 게시물을 엽니다")
    }
}

private struct AttachmentView: View {
    let attachment: PostAttachment
    @EnvironmentObject private var app: AppModel

    var body: some View {
        switch attachment {
        case .image(let url, let altText):
            RemoteImageView(url: url, accessibilityLabel: altText.isEmpty ? "이미지 첨부" : "이미지 첨부: \(altText)")
                .frame(maxHeight: 360)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        case .external(let title, let description, let url, let imageURL):
            HStack(spacing: 12) {
                if imageURL != nil {
                    RemoteImageView(url: imageURL, accessibilityLabel: "외부 링크 이미지")
                        .frame(width: 72, height: 56)
                        .clipped()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).fontWeight(.medium).lineLimit(2)
                    if let description, !description.isEmpty {
                        Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer()
                Image(systemName: "arrow.up.right.square")
            }
            .padding(10)
            .background(.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture { app.openExternal(url) }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { app.openExternal(url) }
            .accessibilityLabel("외부 링크 카드: \(title)")
        case .quote(let quote):
            VStack(alignment: .leading, spacing: 5) {
                Label("인용", systemImage: "quote.opening")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(quote.author.preferredName).fontWeight(.medium)
                Text(quote.text.isEmpty ? "본문 없음" : quote.text)
                    .font(.callout)
                    .lineLimit(5)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("인용 게시물, \(quote.author.preferredName), \(quote.text)")
        case .video(let thumbnailURL, let altText):
            if let thumbnailURL {
                RemoteImageView(url: thumbnailURL, accessibilityLabel: altText ?? "동영상 썸네일")
                    .frame(maxHeight: 280)
                    .overlay { Image(systemName: "play.circle.fill").font(.largeTitle).foregroundStyle(.white) }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                unsupportedView
            }
        case .unsupported:
            unsupportedView
        }
    }

    private var unsupportedView: some View {
        Text("이 콘텐츠는 현재 앱에서 표시할 수 없습니다.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("이 콘텐츠는 현재 앱에서 표시할 수 없습니다.")
    }
}

private struct ProfileAvatar: View {
    let profile: Profile

    var body: some View {
        RemoteImageView(url: profile.avatarURL, accessibilityLabel: "\(profile.preferredName)의 프로필 이미지")
            .frame(width: 42, height: 42)
            .background(.secondary.opacity(0.18), in: Circle())
            .clipShape(Circle())
    }
}

private struct StatLabel: View {
    let value: Int
    let title: String
    let systemImage: String

    var body: some View {
        Label("\(value) \(title)", systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct SkeletonPostRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 4).fill(.secondary.opacity(0.16)).frame(width: 180, height: 16)
            RoundedRectangle(cornerRadius: 4).fill(.secondary.opacity(0.16)).frame(maxWidth: .infinity).frame(height: 44)
            RoundedRectangle(cornerRadius: 4).fill(.secondary.opacity(0.16)).frame(width: 240, height: 14)
        }
        .padding(18)
        .redacted(reason: .placeholder)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("피드 게시물을 불러오는 중")
    }
}

private struct EmptyState: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.title)
            Text(title).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .accessibilityElement(children: .combine)
    }
}

private struct ErrorState: View {
    let message: String
    let retry: () async -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("다시 시도") { Task { await retry() } }
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }
}

struct RetryRow: View {
    let message: String
    let retry: () async -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text(message).font(.callout).foregroundStyle(.secondary)
            Button("다시 시도") { Task { await retry() } }
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}
