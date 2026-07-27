# Sparkle Integration Guide for Blacksky

이 가이드는 Blacksky macOS 앱에 [Sparkle 2](https://sparkle-project.org/)를 통합하여 자동 업데이트를 활성화하는 방법을 설명합니다.

## 1. Sparkle 2 추가 (Swift Package Manager)

Xcode에서:
1. **File → Add Package Dependencies...**
2. 검색창에 `https://github.com/sparkle-project/Sparkle` 입력
3. Dependency Rule: "Up to Next Major" `2.0.0` 이상 선택
4. **Add Package**

## 2. Info.plist 설정

`Info.plist`에 아래 항목들을 추가합니다:

```xml
<key>SUFeedURL</key>
<string>https://breezymind.github.io/blacksky/appcast.xml</string>

<key>SUEnableAutomaticChecks</key>
<true/>

<key>SUPublicEDKey</key>
<string>MCowBQYDK2VwAyEA0ZOHMsOZg4nhFmHShSN1L3pn6jyE0uUeWf1scFAxK98=</string>

<key>SUScheduledCheckInterval</key>
<integer>86400</integer>
```

**키 설명:**
| Key | 설명 |
|-----|------|
| `SUFeedURL` | 업데이트 피드 URL (GitHub Pages) |
| `SUEnableAutomaticChecks` | 앱 시작 시 자동 업데이트 체크 활성화 |
| `SUPublicEDKey` | EdDSA 공개키 — 서명 검증에 사용 (변경하지 마세요) |
| `SUScheduledCheckInterval` | 체크 주기 (초) — 86400 = 24시간 |

## 3. App Delegate에서 Sparkle 초기화

### SwiftUI App (권장)

```swift
import SwiftUI
import Sparkle

@main
struct BlackskyApp: App {
    @StateObject private var updater = UpdaterViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updater)
            }
        }
    }
}

// MARK: - Sparkle Updater ViewModel

final class UpdaterViewModel: ObservableObject {
    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}

// MARK: - Check for Updates Menu Item

struct CheckForUpdatesView: View {
    let updater: UpdaterViewModel

    var body: some View {
        Button("Check for Updates...") {
            updater.checkForUpdates()
        }
        .keyboardShortcut("u", modifiers: [.command, .shift])
    }
}
```

### AppKit (NSApplicationDelegate)

```swift
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var updaterController: SPUStandardUpdaterController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }
}
```

## 4. 엔타이틀먼트 (Sandbox 권한)

샌드박스 앱인 경우 `.entitlements`에 네트워크 권한이 필요합니다:

```xml
<key>com.apple.security.network.client</key>
<true/>
```

Sparkle이 업데이트를 다운로드할 수 있게 `Downloads` 폴더 접근 권한도 필요할 수 있습니다:
```xml
<key>com.apple.security.files.downloads.read-write</key>
<true/>
```

## 5. 버전 관리

앱의 버전은 Xcode 타겟의 `General` → `Identity`에서 설정합니다:
- **Version**: `CFBundleShortVersionString` (예: `1.0`)
- **Build**: `CFBundleVersion` (예: `1`)

Sparkle은 기본적으로 `CFBundleVersion`과 `CFBundleShortVersionString`을 모두 사용하여 버전을 비교합니다.

## 6. 업데이트 흐름

```
앱 실행
  → Sparkle이 주기적으로 appcast.xml 체크
    → 새 버전 발견 시 사용자에게 알림
      → 사용자 승인 시 DMG 다운로드 및 마운트
        → 앱 재시작으로 업데이트 완료
```

## 7. 문제 해결

### 업데이트가 감지되지 않는 경우
- `SUFeedURL`이 올바른지 확인: `https://breezymind.github.io/blacksky/appcast.xml`
- GitHub Pages가 최신 appcast.xml을 배포했는지 확인
- `CFBundleVersion`이 appcast의 `sparkle:version`보다 낮은지 확인

### 서명 검증 실패
- `Info.plist`의 `SUPublicEDKey`가 `public/sparkle-public.pem`의 공개키와 일치하는지 확인
- 릴리스 시 `sign_update` 도구로 올바르게 서명되었는지 확인

### 디버깅 활성화
Xcode Scheme에서 `Arguments`에 추가:
```
-spuDebugLogEnabled YES
```
