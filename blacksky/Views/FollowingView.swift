import SwiftUI

struct FollowingView: View {
    @ObservedObject var viewModel: FollowingViewModel
    @EnvironmentObject private var app: AppModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if viewModel.profiles.isEmpty {
                    emptyOrLoading
                } else {
                    ForEach(viewModel.profiles) { profile in
                        Button {
                            app.openProfile(profile)
                        } label: {
                            FollowingRow(profile: profile)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            if profile.id == viewModel.profiles.last?.id {
                                Task { await viewModel.loadMore() }
                            }
                        }
                    }
                    if let error = viewModel.loadMoreError {
                        RetryRow(message: error) { await viewModel.retryLoadMore() }
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
        .navigationTitle("팔로잉")
    }

    @ViewBuilder
    private var emptyOrLoading: some View {
        switch viewModel.state {
        case .loading:
            ForEach(0..<8, id: \.self) { _ in FollowingSkeletonRow() }
        case .empty:
            FollowingEmptyState()
        case .failed(let message):
            VStack(spacing: 12) {
                Text(message).foregroundStyle(.secondary)
                Button("다시 시도") {
                    if let session = app.session {
                        Task { await viewModel.loadInitial(session: session) }
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 260)
        case .sessionExpired:
            Text("세션이 만료되었습니다. 다시 로그인해 주세요.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 260)
        default:
            Text("팔로잉 목록을 불러올 수 없습니다.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 260)
        }
    }
}

private struct FollowingRow: View {
    let profile: Profile

    var body: some View {
        HStack(spacing: 12) {
            RemoteImageView(url: profile.avatarURL, accessibilityLabel: "\(profile.preferredName)의 프로필 이미지")
                .frame(width: 48, height: 48)
                .background(.secondary.opacity(0.18), in: Circle())
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(profile.preferredName).fontWeight(.semibold)
                    if profile.isVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.blue)
                            .accessibilityLabel("인증된 계정")
                    }
                    if !profile.labels.isEmpty {
                        Image(systemName: "tag.fill")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("라벨: \(profile.labels.joined(separator: ", "))")
                    }
                }
                Text("@\(profile.handle)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let description = profile.description, !description.isEmpty {
                    Text(description)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "arrow.up.right")
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("작성자 \(profile.preferredName), 핸들 \(profile.handle), 소개 \(profile.description ?? "없음")")
        .accessibilityHint("Return 키로 Bluesky 프로필을 엽니다")
    }
}

private struct FollowingSkeletonRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(.secondary.opacity(0.16)).frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4).fill(.secondary.opacity(0.16)).frame(width: 160, height: 14)
                RoundedRectangle(cornerRadius: 4).fill(.secondary.opacity(0.16)).frame(width: 260, height: 12)
            }
            Spacer()
        }
        .padding(12)
        .accessibilityLabel("팔로잉 목록을 불러오는 중")
    }
}

private struct FollowingEmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.2.slash").font(.title)
            Text("팔로잉하는 사용자가 없습니다.").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }
}
