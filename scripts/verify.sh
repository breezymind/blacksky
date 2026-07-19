#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

XCODEBUILD=(xcodebuild -project blacksky.xcodeproj -scheme blacksky)
AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
ISSUE_STORE="$AGENT_DIR/scripts/issue-store.js"

if [[ ! -x "$(command -v xcodebuild)" ]]; then
    echo "xcodebuild를 찾을 수 없습니다. macOS/Xcode 환경에서 실행하세요." >&2
    exit 1
fi

printf '%s\n' '== Xcode scheme =='
"${XCODEBUILD[@]}" -list
printf '%s\n' '== Build =='
"${XCODEBUILD[@]}" -configuration Debug build CODE_SIGNING_ALLOWED=NO
printf '%s\n' '== Unit tests =='
"${XCODEBUILD[@]}" test -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO

contains() {
    local file="$1"
    local expected="$2"
    if ! grep -Fq -- "$expected" "$file"; then
        echo "검증 실패: $file 에서 '$expected'를 찾지 못했습니다." >&2
        exit 1
    fi
}

printf '%s\n' '== Verification command contract =='
contains package.json '"test": "bash scripts/verify.sh"'

printf '%s\n' '== OAuth client metadata checks =='
node <<'NODE'
const fs = require('fs');

const expectedClientID = 'https://breezymind.github.io/blacksky/oauth-client-metadata.json';
const expectedRedirectURI = 'io.github.breezymind:/oauth/callback';
const metadataPath = 'public/oauth-client-metadata.json';
let metadata;
try {
    metadata = JSON.parse(fs.readFileSync(metadataPath, 'utf8'));
} catch (error) {
    throw new Error(`${metadataPath}가 유효한 JSON이 아닙니다: ${error.message}`);
}

if (metadata.client_id !== expectedClientID) {
    throw new Error(`metadata client_id가 예상값과 다릅니다: ${metadata.client_id}`);
}
if (metadata.application_type !== 'native') {
    throw new Error('metadata application_type은 native여야 합니다.');
}
if (JSON.stringify(metadata.grant_types) !== JSON.stringify(['authorization_code', 'refresh_token'])) {
    throw new Error('metadata grant_types가 예상값과 다릅니다.');
}
if (JSON.stringify(metadata.response_types) !== JSON.stringify(['code'])) {
    throw new Error('metadata response_types가 예상값과 다릅니다.');
}
if (!Array.isArray(metadata.redirect_uris) || !metadata.redirect_uris.includes(expectedRedirectURI)) {
    throw new Error(`metadata redirect_uris에 ${expectedRedirectURI}가 없습니다.`);
}
if (metadata.dpop_bound_access_tokens !== true) {
    throw new Error('metadata dpop_bound_access_tokens는 true여야 합니다.');
}

const oauthSource = fs.readFileSync('blacksky/Services/OAuthService.swift', 'utf8');
const appClientID = oauthSource.match(/clientID:\s*"([^"]+)"/)?.[1];
if (appClientID !== expectedClientID) {
    throw new Error(`앱 OAuth clientID가 metadata client_id와 다릅니다: ${appClientID}`);
}
if (!oauthSource.includes(`redirectURI: URL(string: "${expectedRedirectURI}")!`)) {
    throw new Error(`앱 OAuth callback URL scheme이 ${expectedRedirectURI}가 아닙니다.`);
}
NODE

printf '%s\n' '== Pages deployment checks =='
contains .github/workflows/pages.yml 'actions/upload-pages-artifact@v3'
contains .github/workflows/pages.yml 'path: public/'
if grep -Eq 'docs/|docs/issues.sqlite' .github/workflows/pages.yml; then
    echo '검증 실패: GitHub Pages workflow가 docs/를 소스로 사용합니다.' >&2
    exit 1
fi

printf '%s\n' '== App contract checks =='
contains blacksky/Info.plist '<key>CFBundleDisplayName</key>'
contains blacksky/Info.plist '<key>CFBundleName</key>'
contains blacksky/Info.plist '<string>blacksky</string>'
contains blacksky/Info.plist '<string>io.github.breezymind.oauth-callback</string>'
contains blacksky/Info.plist '<string>io.github.breezymind</string>'
contains blacksky/Views/MainShellView.swift 'NavigationSplitView'
contains blacksky/App/BlackskyApp.swift '.defaultSize(width: 980, height: 720)'
contains blacksky/App/BlackskyApp.swift 'keyboardShortcut("1", modifiers: .command)'
contains blacksky/App/BlackskyApp.swift 'keyboardShortcut("2", modifiers: .command)'
contains blacksky/App/BlackskyApp.swift 'keyboardShortcut("r", modifiers: .command)'
contains blacksky/Views/LoginView.swift 'Bluesky 핸들'
contains blacksky/Views/LoginView.swift 'Bluesky로 로그인'
contains blacksky/Services/OAuthService.swift 'OAuthClientConfiguration'
contains blacksky/Services/OAuthService.swift 'io.github.breezymind:/oauth/callback'
contains blacksky/Services/OAuthService.swift 'pushed_authorization_request_endpoint'
contains blacksky/Services/OAuthService.swift 'DPoPProofBuilder'
contains blacksky/Services/OAuthService.swift 'code_challenge_method'
contains blacksky/Services/OAuthService.swift 'authorization_servers'
contains blacksky/Domain/Models.swift 'payload["ath"]'
contains blacksky/App/BlackskyApp.swift '.onOpenURL'
contains blacksky/App/AppModel.swift 'restoreSession()'
contains blacksky/App/AppModel.swift 'stored.isExpired'
contains blacksky/App/AppModel.swift 'cache.clear()'
contains blacksky/Services/KeychainStore.swift 'kSecClassGenericPassword'
contains blacksky/Services/KeychainStore.swift 'SecItemCopyMatching'
contains blacksky/Services/KeychainStore.swift 'SecItemAdd'
contains blacksky/Services/KeychainStore.swift 'SecItemDelete'
contains blacksky/Services/BlueskyAPI.swift 'app.bsky.feed.getTimeline'
contains blacksky/Services/BlueskyAPI.swift 'app.bsky.graph.getFollows'
contains blacksky/Views/FeedView.swift 'SkeletonPostRow'
contains blacksky/Views/FeedView.swift 'RetryRow'
contains blacksky/Views/FeedView.swift '이 콘텐츠는 현재 앱에서 표시할 수 없습니다.'
contains blacksky/Views/FeedView.swift 'post.accessibilitySummary'
contains blacksky/Views/FeedView.swift '.frame(maxWidth: 640)'
contains blacksky/Views/FollowingView.swift 'FollowingEmptyState'
contains blacksky/Views/FollowingView.swift 'RetryRow'
contains blacksky/Views/FollowingView.swift 'lineLimit(1)'
contains blacksky/Services/ImageLoader.swift 'task?.cancel()'
contains blacksky/Services/ImageLoader.swift '.onDisappear { model.cancel() }'

if grep -Eiq 'password|비밀번호' blacksky/Views/LoginView.swift; then
    echo '검증 실패: 로그인 화면에서 비밀번호 입력/문구를 찾았습니다.' >&2
    exit 1
fi

if grep -R -E 'UserDefaults|AppStorage' blacksky >/dev/null; then
    echo '검증 실패: OAuth/앱 구현에서 UserDefaults 또는 AppStorage 사용을 찾았습니다.' >&2
    exit 1
fi
if grep -R -E 'print\([^)]*(accessToken|refreshToken)|NSLog\([^)]*(accessToken|refreshToken)' blacksky >/dev/null; then
    echo '검증 실패: 인증 토큰 로그 출력을 찾았습니다.' >&2
    exit 1
fi
if grep -R -E 'app\.bsky\.(feed\.post\.create|feed\.like|feed\.repost|graph\.follow|graph\.unfollow)' blacksky >/dev/null; then
    echo '검증 실패: 읽기 전용 범위를 벗어난 Bluesky API 호출을 찾았습니다.' >&2
    exit 1
fi
if grep -R -E 'https://bsky\.social/oauth/(authorize|token|par)' blacksky >/dev/null; then
    echo '검증 실패: OAuth endpoint를 하드코딩했습니다.' >&2
    exit 1
fi
if grep -Fq 'setValue("Bearer ' blacksky/Services/BlueskyAPI.swift; then
    echo '검증 실패: PDS 요청이 Bearer 인증을 사용합니다.' >&2
    exit 1
fi
contains blacksky/Services/BlueskyAPI.swift 'setValue("DPoP \(session.accessToken)'

printf '%s\n' '== SQLite issue-store architecture checks =='
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
node "$ISSUE_STORE" list --root "$ROOT" > "$tmp_dir/issues.json"
node "$ISSUE_STORE" list-architecture --root "$ROOT" > "$tmp_dir/architecture.json"

ISSUES_JSON="$tmp_dir/issues.json" ARCHITECTURE_JSON="$tmp_dir/architecture.json" node <<'NODE'
const fs = require('fs');

const issues = JSON.parse(fs.readFileSync(process.env.ISSUES_JSON, 'utf8')).issues ?? [];
const architecture = JSON.parse(fs.readFileSync(process.env.ARCHITECTURE_JSON, 'utf8')).documents ?? [];
const issueByID = new Map(issues.map(issue => [issue.issue_id, issue]));
const requiredIssues = ['T-001', 'T-002', 'T-003', 'T-004', 'T-005', 'T-006', 'T-007', 'T-008', 'T-009', 'T-010', 'T-011'];
const missingIssues = requiredIssues.filter(id => !issueByID.has(id));
if (missingIssues.length) {
    throw new Error(`필수 issue-store 이슈 누락: ${missingIssues.join(', ')}`);
}
for (const id of requiredIssues.slice(1)) {
    if (!issueByID.get(id).body.includes('Acceptance criteria')) {
        throw new Error(`${id} acceptance criteria가 없습니다.`);
    }
}
if (issueByID.get('T-008').status !== 'done') {
    throw new Error(`T-008 상태가 done이 아닙니다: ${issueByID.get('T-008').status}`);
}
if (issueByID.get('T-009').status !== 'done') {
    throw new Error(`T-009 상태가 done이 아닙니다: ${issueByID.get('T-009').status}`);
}
for (const id of ['T-010', 'T-011']) {
    if (issueByID.get(id).status !== 'done') {
        throw new Error(`${id} 상태가 done이 아닙니다: ${issueByID.get(id).status}`);
    }
}

const documentByPath = new Map(architecture.map(document => [document.source_path, document]));
const adr = documentByPath.get('adr/0001-oauth-callback-and-client-config');
const context = documentByPath.get('context/main');
if (!adr || !context) {
    throw new Error('필수 architecture 문서(ADR/context)가 누락되었습니다.');
}
for (const term of ['client metadata', 'Keychain']) {
    if (!adr.body.includes(term)) throw new Error(`ADR에 '${term}' 근거가 없습니다.`);
}
const dpopADR = documentByPath.get('adr/0002-dpop-key-protection');
if (!dpopADR) throw new Error('DPoP 보호 ADR이 누락되었습니다.');
const callbackADR = documentByPath.get('adr/0003-atproto-native-callback-uri');
if (!callbackADR) throw new Error('atproto callback URI ADR이 누락되었습니다.');
for (const term of ['io.github.breezymind:/oauth/callback', 'breezymind.github.io', 'superseded']) {
    if (!callbackADR.body.includes(term)) throw new Error(`callback ADR에 '${term}' 근거가 없습니다.`);
}
for (const term of ['Secure Enclave', 'Keychain', 'nonce']) {
    if (!dpopADR.body.includes(term)) throw new Error(`DPoP ADR에 '${term}' 근거가 없습니다.`);
}
for (const term of ['읽기 전용 MVP', 'app.bsky.feed.getTimeline', 'app.bsky.graph.getFollows', 'URI', 'DID', 'DPoP', 'io.github.breezymind:/oauth/callback']) {
    if (!context.body.includes(term)) throw new Error(`context/main에 '${term}' 용어가 없습니다.`);
}
NODE

printf '%s\n' '검증 성공: build, test, 앱 계약, 읽기 전용/보안 정적 검사, issue-store architecture 검사를 모두 통과했습니다.'
