import SwiftUI

@main
struct BlackskyApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .frame(minWidth: 720, minHeight: 520)
                .onOpenURL { url in
                    Task { await app.completeLogin(from: url) }
                }
        }
        .defaultSize(width: 980, height: 720)
        .commands {
            CommandMenu("이동") {
                Button("피드") { app.selectedSection = .feed }
                    .keyboardShortcut("1", modifiers: .command)
                Button("팔로잉") { app.selectedSection = .following }
                    .keyboardShortcut("2", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("새로고침") {
                    Task { await app.refreshCurrentSection(app.selectedSection) }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

private struct RootView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        Group {
            switch app.authState {
            case .restoring:
                ProgressView("세션을 확인하는 중…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loggedOut:
                LoginView()
            case .authenticated:
                MainShellView()
            }
        }
        .frame(minWidth: 720, minHeight: 520)
    }
}
