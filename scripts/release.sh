#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Blacksky Release Script
# Signs a DMG, creates a GitHub Release, and updates appcast.xml
#
# Prerequisites:
#   - gh CLI installed and authenticated
#   - openssl
#   - Sparkle private key at keys/sparkle-private.pem
#
# Usage:
#   ./scripts/release.sh [dmg_path] [version] [release_notes_file]
#
# Optional environment variable:
#   SPARKLE_BUILD_VERSION  CFBundleVersion used in sparkle:version.
#                          Defaults to version for backwards compatibility.
#
# With no arguments, auto-detects the DMG from ../blacksky/dist/
# ============================================================

show_help() {
  cat <<'HELP'
사용 방법 (새 버전 릴리스)

  # 1. 소스 프로젝트에서 DMG 빌드
  cd ../blacksky
  bash scripts/build-dmg.sh

  # 2. 릴리스 (인자 없이 — DMG/버전 자동 감지)
  cd ../blacksky-release
  ./scripts/release.sh

  # 3. Draft 확인 후 퍼블리시
  gh release edit v1.0 --repo breezymind/blacksky --draft=false

  # 4. Draft 공개 후 asset/appcast 검증과 appcast push
  SPARKLE_BUILD_VERSION=45 ./scripts/publish.sh 1.0

  GitHub Pages가 자동 배포되면 앱이
  https://breezymind.github.io/blacksky/appcast.xml을 통해 새 버전을 감지하고
  업데이트를 제안합니다. 앱 측에서는 SPARKLE_INTEGRATION.md 가이드에 따라 Sparkle
  프레임워크를 통합하면 됩니다.

수동 지정:
  ./scripts/release.sh dist/blacksky-1.0.dmg 1.0 release-notes.md
HELP
  exit 0
}

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PRIVATE_KEY="$REPO_ROOT/keys/sparkle-private.pem"
APPCAST="$REPO_ROOT/public/appcast.xml"
REPO="breezymind/blacksky"

# --- Source dist directory (adjacent blacksky project) ---
SOURCE_DIST_DIRS=(
  "$REPO_ROOT/../blacksky/dist"
  "$REPO_ROOT/dist"
)

# --- Help flag ---
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  show_help
fi

# ============================================================
# 1. Determine DMG path
# ============================================================
if [ $# -ge 1 ] && [ -n "$1" ]; then
  DMG_PATH="$1"
else
  echo "==> DMG 경로가 지정되지 않음 — 소스 디렉토리에서 자동 검색..."
  DMG_PATH=""
  for dir in "${SOURCE_DIST_DIRS[@]}"; do
    if [ -d "$dir" ]; then
      # Find latest DMG (sorted by modification time, newest first)
      FOUND=$(find "$dir" -maxdepth 1 -name "blacksky-*.dmg" -print0 2>/dev/null \
        | xargs -0 ls -t 2>/dev/null | head -1 || true)
      if [ -n "$FOUND" ]; then
        DMG_PATH="$FOUND"
        echo "==> 발견: $DMG_PATH"
        break
      fi
    fi
  done
  if [ -z "$DMG_PATH" ]; then
    echo "오류: blacksky-*.dmg 파일을 찾을 수 없습니다."
    echo "  확인 경로: ${SOURCE_DIST_DIRS[*]}"
    echo ""
    echo "먼저 ../blacksky 에서 DMG를 빌드하세요:"
    echo "  cd ../blacksky"
    echo "  bash scripts/build-dmg.sh"
    exit 1
  fi
fi

if [ ! -f "$DMG_PATH" ]; then
  echo "오류: DMG를 찾을 수 없습니다: $DMG_PATH"
  exit 1
fi

# ============================================================
# 2. Determine version
# ============================================================
DMG_NAME="$(basename "$DMG_PATH")"

if [ $# -ge 2 ] && [ -n "$2" ]; then
  VERSION="$2"
else
  echo "==> DMG 파일명에서 버전 추출..."
  # Extract version from blacksky-X.Y.Z.dmg
  VERSION=$(echo "$DMG_NAME" | sed -n 's/^blacksky-\(.*\)\.dmg$/\1/p')
  if [ -z "$VERSION" ]; then
    echo "오류: DMG 파일명에서 버전을 추출할 수 없습니다: $DMG_NAME"
    echo "  예상 파일명 패턴: blacksky-1.0.dmg, blacksky-1.2.3.dmg"
    echo "  수동 지정: $0 $DMG_PATH <version> [notes_file]"
    exit 1
  fi
  echo "==> 추출된 버전: $VERSION"
fi

# Sparkle compares this machine-readable value with the installed app's
# CFBundleVersion. The pipeline supplies it separately from the display
# version; keep the fallback so older direct invocations still work.
SPARKLE_BUILD_VERSION="${SPARKLE_BUILD_VERSION:-$VERSION}"
if [ -z "$SPARKLE_BUILD_VERSION" ]; then
  echo "오류: Sparkle 빌드 버전이 비어 있습니다."
  exit 1
fi

# ============================================================
# 3. Determine release notes
# ============================================================
if [ $# -ge 3 ] && [ -n "$3" ]; then
  NOTES_FILE="$3"
  RELEASE_NOTES=$(cat "$NOTES_FILE")
else
  # Use a predictable path so the user can edit it before re-running
  NOTES_FILE="$REPO_ROOT/release-notes-${VERSION}.md"

  # If notes file already exists from a prior attempt, just use it
  if [ -f "$NOTES_FILE" ]; then
    echo "==> 기존 릴리스 노트 파일 발견: $NOTES_FILE"
    RELEASE_NOTES=$(cat "$NOTES_FILE")
    if [ -z "$(echo "$RELEASE_NOTES" | tr -d '[:space:]-#')" ]; then
      echo "오류: 릴리스 노트가 비어 있습니다: $NOTES_FILE"
      exit 1
    fi
  elif [ -t 0 ] && [ -t 1 ]; then
    # Interactive terminal — open editor directly
    echo "==> 릴리스 노트 파일이 지정되지 않음 — 에디터로 직접 입력받습니다..."
    cat > "$NOTES_FILE" <<EOF
## What's New in $VERSION

-
-
-
EOF
    ${EDITOR:-vi} "$NOTES_FILE" </dev/tty
    RELEASE_NOTES=$(cat "$NOTES_FILE")
    if [ -z "$(echo "$RELEASE_NOTES" | tr -d '[:space:]-#')" ]; then
      echo "오류: 릴리스 노트가 비어 있습니다."
      rm -f "$NOTES_FILE"
      exit 1
    fi
  else
    # Non-interactive — write template, tell user to edit, and exit
    cat > "$NOTES_FILE" <<EOF
## What's New in $VERSION

-
-
-
EOF
    echo ""
    echo "===== 릴리스 노트 템플릿 생성 ====="
    echo "  파일: $NOTES_FILE"
    echo ""
    echo "비대화형 환경입니다. 위 파일을 수정한 후 다시 실행하세요:"
    echo "  SPARKLE_BUILD_VERSION=$SPARKLE_BUILD_VERSION ./scripts/release.sh $DMG_PATH $VERSION $NOTES_FILE"
    echo "==================================="
    echo ""
    echo "편집하려면: ${EDITOR:-vi} $NOTES_FILE"
    exit 0
  fi
fi

# ============================================================
# 4. Validate prerequisites
# ============================================================
if [ ! -f "$PRIVATE_KEY" ]; then
  echo "오류: Sparkle 개인키를 찾을 수 없습니다: $PRIVATE_KEY"
  echo "  생성: openssl genpkey -algorithm ed25519 -out keys/sparkle-private.pem"
  exit 1
fi

# ============================================================
# 5. Compute metadata
# ============================================================
DMG_SIZE="$(stat -f%z "$DMG_PATH" 2>/dev/null || stat -c%s "$DMG_PATH" 2>/dev/null)"
TAG="v$VERSION"

echo ""
echo "===== 릴리스 정보 ====="
echo "  DMG    : $DMG_NAME ($(numfmt --to=iec $DMG_SIZE 2>/dev/null || echo "${DMG_SIZE} bytes"))"
echo "  버전   : $VERSION"
echo "  빌드   : $SPARKLE_BUILD_VERSION"
echo "  태그   : $TAG"
echo "  저장소 : $REPO"
echo "======================="
echo ""

# ============================================================
# 6. Sign the DMG with EdDSA (Ed25519)
# ============================================================
echo "==> DMG 서명 중 (EdDSA)..."
SIGNATURE_BIN=$(mktemp)
openssl pkeyutl -sign \
  -inkey "$PRIVATE_KEY" \
  -rawin -in "$DMG_PATH" \
  -out "$SIGNATURE_BIN"
ED_SIGNATURE=$(base64 -i "$SIGNATURE_BIN" | tr -d '\n')
rm -f "$SIGNATURE_BIN"
echo "==> 서명: ${ED_SIGNATURE:0:40}..."

# ============================================================
# 7. Create GitHub Release and upload DMG
# ============================================================
echo "==> GitHub Release 생성 중 ($TAG)..."

# 기존 릴리스는 삭제하지 않는다. 중단된 작업은 pipeline의 --resume으로
# 복구해야 하며, 같은 tag를 덮어써서 공개 artifact를 훼손하면 안 된다.
if gh release view "$TAG" --repo "$REPO" &>/dev/null; then
  echo "오류: 이미 존재하는 GitHub Release입니다: $TAG" >&2
  echo "  기존 릴리스는 삭제하지 말고 pipeline-release.sh --resume $VERSION 을 사용하세요." >&2
  exit 1
fi

# Create release (draft first for safety)
gh release create "$TAG" \
  --repo "$REPO" \
  --title "Blacksky $VERSION" \
  --notes "$RELEASE_NOTES" \
  --draft \
  "$DMG_PATH"

# ============================================================
# 8. Build download URL
# ============================================================
DOWNLOAD_URL="https://github.com/$REPO/releases/download/$TAG/$DMG_NAME"
echo "==> 다운로드 URL: $DOWNLOAD_URL"

# ============================================================
# 9. Update appcast.xml
# ============================================================
echo "==> appcast.xml 갱신 중..."

# Minimum system version (default macOS 14 Sonoma)
MIN_OS="14.0"

# Current date in RFC 2822 format
PUB_DATE=$(LC_TIME=en_US.UTF-8 date '+%a, %d %b %Y %H:%M:%S %z')

# Build the new item XML
NEW_ITEM=$(cat <<ITEMEOF
    <item>
      <title>Version $VERSION</title>
      <description><![CDATA[$RELEASE_NOTES]]></description>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$SPARKLE_BUILD_VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <enclosure
        url="$DOWNLOAD_URL"
        length="$DMG_SIZE"
        type="application/octet-stream"
        sparkle:edSignature="$ED_SIGNATURE"
      />
    </item>
ITEMEOF
)

# Write the new item to a temp file (avoids multiline escaping issues with awk -v)
ITEM_FILE=$(mktemp)
printf '%s\n' "$NEW_ITEM" > "$ITEM_FILE"

# Insert new item before </channel>
TMP_APPCAST=$(mktemp)
awk -v itemfile="$ITEM_FILE" '
  /<\/channel>/ {
    while ((getline line < itemfile) > 0) print line
    print ""
    close(itemfile)
  }
  { print }
' "$APPCAST" > "$TMP_APPCAST"
rm -f "$ITEM_FILE"
mv "$TMP_APPCAST" "$APPCAST"

echo "==> appcast.xml 갱신 완료"

# ============================================================
# 10. Update landing page & upload to server
# ============================================================
WEB_INDEX="$REPO_ROOT/../blacksky-web/index.html"
SSH_KEY="$HOME/StudioProjects/Certs/lightsail.pem"
SSH_DEST="bitnami@breezymind.com:/home/bitnami/blacksky"

if [ -f "$WEB_INDEX" ]; then
  echo "==> index.html 버전 갱신 중..."

  # Extract current version from the DMG URL in the HTML
  OLD_VERSION=$(grep -oE 'blacksky-[0-9]+\.[0-9]+\.[0-9]+\.dmg' "$WEB_INDEX" | head -1 | sed 's/blacksky-//;s/\.dmg//')

  if [ -z "$OLD_VERSION" ]; then
    echo "경고: index.html에서 현재 버전을 찾을 수 없습니다. 건너뜁니다."
  elif [ "$OLD_VERSION" = "$VERSION" ]; then
    echo "==> index.html이 이미 $VERSION 입니다. 건너뜁니다."
  else
    echo "==> $OLD_VERSION → $VERSION"

    # Backup
    cp "$WEB_INDEX" "$WEB_INDEX.bak"

    # Replace all occurrences of old version with new version
    sed -i '' "s/$OLD_VERSION/$VERSION/g" "$WEB_INDEX"

    echo "==> index.html 갱신 완료"

    # Upload to server
    if [ -f "$SSH_KEY" ]; then
      echo "==> 서버에 index.html 업로드 중..."
      scp -i "$SSH_KEY" "$WEB_INDEX" "$SSH_DEST/"
      echo "==> 업로드 완료: https://breezymind.com/blacksky/"
    else
      echo "경고: SSH 키를 찾을 수 없습니다: $SSH_KEY"
      echo "  수동 업로드: scp -i <key> $WEB_INDEX $SSH_DEST/"
    fi
  fi
else
  echo "경고: index.html을 찾을 수 없습니다: $WEB_INDEX"
fi

# ============================================================
# 11. Finalize
# ============================================================
echo ""
echo "===== 다음 단계 ====="
echo "1. Draft 릴리스 확인:"
echo "   gh release view $TAG --repo $REPO"
echo ""
echo "2. 릴리스 퍼블리시:"
echo "   gh release edit $TAG --repo $REPO --draft=false"
echo ""
echo "3. 공개 asset/appcast 검증 후 appcast 커밋 & 푸시:"
echo "   SPARKLE_BUILD_VERSION=$SPARKLE_BUILD_VERSION ./scripts/publish.sh $VERSION"
echo ""
echo "GitHub Pages 자동 배포 후 업데이트 URL:"
echo "  https://breezymind.github.io/blacksky/appcast.xml"
