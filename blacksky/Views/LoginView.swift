import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            VStack(spacing: 10) {
                Text("blacksky")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("macOS에서 Bluesky 피드와 팔로잉을 읽어보세요.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Bluesky 핸들")
                    .font(.headline)
                TextField("handle.bsky.social", text: $app.handleInput)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)
                    .onSubmit { Task { await app.startLogin() } }
                    .accessibilityLabel("Bluesky 핸들")
            }
            .frame(maxWidth: 360)

            Button {
                Task { await app.startLogin() }
            } label: {
                HStack {
                    if app.isAuthenticating { ProgressView().controlSize(.small) }
                    Text("Bluesky로 로그인")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(app.isAuthenticating || app.handleInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .frame(maxWidth: 360)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("Bluesky로 로그인")

            if let message = loginMessage {
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .accessibilityLabel("로그인 안내: \(message)")
            }
            if let error = app.authError {
                Text(error)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .accessibilityLabel("로그인 오류: \(error)")
            }
            Spacer()
        }
        .padding(40)
        .frame(minWidth: 720, minHeight: 520)
    }

    private var loginMessage: String? {
        if case .loggedOut(let message) = app.authState { return message }
        return nil
    }
}
