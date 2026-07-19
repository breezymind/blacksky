import SwiftUI

struct MainShellView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $app.selectedSection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationTitle("blacksky")
            .accessibilityLabel("주요 메뉴")
        } detail: {
            Group {
                switch app.selectedSection {
                case .feed:
                    FeedView(viewModel: app.feed)
                case .following:
                    FollowingView(viewModel: app.following)
                }
            }
            .frame(minWidth: 480, minHeight: 420)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("로그아웃", systemImage: "rectangle.portrait.and.arrow.right") {
                    app.logout()
                }
                .accessibilityLabel("로그아웃")
            }
        }
        .task(id: app.session?.did) {
            guard let session = app.session else { return }
            if app.feed.state == .idle { await app.feed.loadInitial(session: session) }
            if app.following.state == .idle { await app.following.loadInitial(session: session) }
        }
    }
}
