import AppKit
import Foundation
import SwiftUI

protocol ImageLoading: Sendable {
    func load(url: URL) async throws -> Data
}

struct URLSessionImageLoader: ImageLoading {
    func load(url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

@MainActor
final class RemoteImageModel: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var isLoading = false
    @Published private(set) var failed = false

    private let loader: any ImageLoading
    private var task: Task<Void, Never>?

    init(loader: any ImageLoading = URLSessionImageLoader()) {
        self.loader = loader
    }

    func load(url: URL?) {
        task?.cancel()
        image = nil
        failed = false
        guard let url else { return }
        isLoading = true
        let loader = self.loader
        task = Task { [weak self] in
            do {
                let data = try await loader.load(url: url)
                try Task.checkCancellation()
                guard let image = NSImage(data: data) else { throw URLError(.cannotDecodeContentData) }
                self?.image = image
                self?.isLoading = false
            } catch is CancellationError {
                self?.isLoading = false
            } catch {
                self?.failed = true
                self?.isLoading = false
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}

struct RemoteImageView: View {
    let url: URL?
    let accessibilityLabel: String
    @StateObject private var model: RemoteImageModel

    init(url: URL?, accessibilityLabel: String, loader: any ImageLoading = URLSessionImageLoader()) {
        self.url = url
        self.accessibilityLabel = accessibilityLabel
        _model = StateObject(wrappedValue: RemoteImageModel(loader: loader))
    }

    var body: some View {
        Group {
            if let image = model.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else if model.isLoading {
                ProgressView()
                    .controlSize(.small)
            } else if model.failed {
                Text("이 콘텐츠는 현재 앱에서 표시할 수 없습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
        .accessibilityLabel(accessibilityLabel)
        .task(id: url) { model.load(url: url) }
        .onDisappear { model.cancel() }
    }
}
