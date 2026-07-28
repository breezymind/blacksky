#!/usr/bin/env bash
set -euo pipefail

# Validate a reviewed GitHub Release and the public appcast before publishing
# the appcast commit. This script intentionally leaves local changes intact on
# failure so the diagnostics can be fixed and the command re-run.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPCAST="$REPO_ROOT/public/appcast.xml"
PIPELINE_ROOT="${PIPELINE_ROOT:-$REPO_ROOT/../blacksky}"
REPO="${GITHUB_REPOSITORY:-breezymind/blacksky}"
PUBLIC_APPCAST_URL="${PUBLIC_APPCAST_URL:-https://breezymind.github.io/blacksky/appcast.xml}"
PUBLIC_VERIFY_TIMEOUT_SECONDS="${PUBLIC_VERIFY_TIMEOUT_SECONDS:-600}"
PUBLIC_VERIFY_INTERVAL_SECONDS="${PUBLIC_VERIFY_INTERVAL_SECONDS:-10}"

usage() {
  echo "사용법: SPARKLE_BUILD_VERSION=<build> $0 <version> [--remote <origin>] [--branch <main>]"
  echo "예: SPARKLE_BUILD_VERSION=45 $0 1.0.44"
}

if [[ $# -lt 1 || "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  [[ $# -lt 1 ]] && exit 1 || exit 0
fi
VERSION="$1"
shift
REMOTE="origin"
BRANCH="main"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote) REMOTE="${2:?--remote 뒤에 remote 이름이 필요합니다.}"; shift 2 ;;
    --branch) BRANCH="${2:?--branch 뒤에 branch 이름이 필요합니다.}"; shift 2 ;;
    *) echo "알 수 없는 옵션: $1" >&2; usage >&2; exit 1 ;;
  esac
done
TAG="v$VERSION"
SPARKLE_BUILD_VERSION="${SPARKLE_BUILD_VERSION:-}"

fail() {
  echo "publish 실패: $*" >&2
  echo "원격 Release와 로컬 appcast 변경은 유지했습니다. 수정 후 다음 명령으로 재시도하세요:" >&2
  echo "  cd $PIPELINE_ROOT && bash scripts/pipeline-release.sh --resume $VERSION --remote $REMOTE --branch $BRANCH" >&2
  exit 1
}

command -v gh >/dev/null || fail "gh CLI가 필요합니다."
command -v curl >/dev/null || fail "curl이 필요합니다."
[[ -f "$APPCAST" ]] || fail "appcast를 찾을 수 없습니다: $APPCAST"
git -C "$REPO_ROOT" remote get-url "$REMOTE" >/dev/null 2>&1 || fail "release repo remote가 없습니다: $REMOTE"
[[ "$(git -C "$REPO_ROOT" branch --show-current)" == "$BRANCH" ]] || fail "release repo branch가 $BRANCH가 아닙니다."
git -C "$REPO_ROOT" ls-remote --exit-code "$REMOTE" "refs/heads/$BRANCH" >/dev/null 2>&1 || fail "원격 branch가 없습니다: $REMOTE/$BRANCH"
while IFS= read -r changed; do
  [[ -z "$changed" ]] && continue
  [[ "$changed" == "public/appcast.xml" || "$changed" == release-notes-*.md ]] && continue
  fail "release repo에 unrelated 변경이 있습니다: $changed"
done < <(git -C "$REPO_ROOT" status --porcelain | sed -E 's/^.. //')

RELEASE_JSON="$(gh release view "$TAG" --repo "$REPO" --json isDraft,tagName,assets 2>&1)" || fail "GitHub Release 조회 실패: $RELEASE_JSON"
export RELEASE_JSON VERSION TAG APPCAST SPARKLE_BUILD_VERSION
python3 <<'PY' || exit 1
import json, os, sys, xml.etree.ElementTree as ET

try:
    release = json.loads(os.environ['RELEASE_JSON'])
except json.JSONDecodeError as e:
    print(f"GitHub Release JSON이 유효하지 않습니다: {e}", file=sys.stderr)
    sys.exit(1)
if release.get('isDraft'):
    print('Release가 아직 Draft입니다. 검토 후 공개한 뒤 다시 실행하세요.', file=sys.stderr)
    sys.exit(1)
if release.get('tagName') != os.environ['TAG']:
    print(f"Release tag가 예상값과 다릅니다: {release.get('tagName')}", file=sys.stderr)
    sys.exit(1)
expected_name = f"blacksky-{os.environ['VERSION']}.dmg"
assets = {a.get('name'): a for a in release.get('assets', [])}
asset = assets.get(expected_name)
if not asset:
    print(f"공개 Release asset을 찾을 수 없습니다: {expected_name}", file=sys.stderr)
    sys.exit(1)

ns = {'s': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
root = ET.parse(os.environ['APPCAST']).getroot()
items = root.findall('./channel/item')
item = next((i for i in items if i.findtext('s:shortVersionString', namespaces=ns) == os.environ['VERSION']), None)
if item is None:
    print(f"appcast에서 버전을 찾을 수 없습니다: {os.environ['VERSION']}", file=sys.stderr)
    sys.exit(1)
if item.find('s:channel', ns) is not None:
    print(f"안정 버전 {os.environ['VERSION']}에는 sparkle:channel이 없어야 합니다.", file=sys.stderr)
    sys.exit(1)
enclosure = item.find('enclosure')
if enclosure is None:
    print('appcast 항목에 enclosure가 없습니다.', file=sys.stderr)
    sys.exit(1)
expected_url = f"https://github.com/{os.environ.get('GITHUB_REPOSITORY', 'breezymind/blacksky')}/releases/download/{os.environ['TAG']}/{expected_name}"
checks = {
    'sparkle:version': item.findtext('s:version', namespaces=ns),
    'url': enclosure.get('url'),
    'length': enclosure.get('length'),
    'edSignature': enclosure.get('{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature'),
}
expected = {
    'url': expected_url,
    'length': str(asset.get('size')),
}
# Build number is supplied explicitly because it is the app's machine-readable
# version and cannot be inferred from the human-readable version.
expected['sparkle:version'] = os.environ.get('SPARKLE_BUILD_VERSION') or checks['sparkle:version']
for key, value in expected.items():
    if checks[key] != value:
        print(f"appcast {key} 불일치: {checks[key]!r} != {value!r}", file=sys.stderr)
        sys.exit(1)
if not checks['edSignature']:
    print('appcast EdDSA 서명이 비어 있습니다.', file=sys.stderr)
    sys.exit(1)
print(f"검증 완료: {expected_name}, {asset.get('size')} bytes, build {checks['sparkle:version']}")
PY

# Publish the locally validated appcast before polling Pages. A first publish
# must not require the old public copy to already contain the new item.
git -C "$REPO_ROOT" diff --check || fail "appcast 공백 검증에 실패했습니다."
git -C "$REPO_ROOT" add public/appcast.xml
if git -C "$REPO_ROOT" diff --cached --quiet; then
  echo "==> appcast 변경은 이미 commit된 상태입니다. push와 원격 검증을 계속합니다."
else
  git -C "$REPO_ROOT" commit -m "Publish appcast for $TAG" || fail "appcast commit 실패"
fi
git -C "$REPO_ROOT" push "$REMOTE" "HEAD:$BRANCH" || fail "appcast push 실패"

# The public Pages copy may lag the push. Retry for at most ten minutes;
# never rewrite or roll back the local appcast while waiting.
elapsed=0
last_error=""
verified=false
while (( elapsed <= PUBLIC_VERIFY_TIMEOUT_SECONDS )); do
  remote_appcast="$(mktemp)"
  if curl --fail --silent --show-error --location --max-time 30 "$PUBLIC_APPCAST_URL" -o "$remote_appcast"; then
    if VERSION="$VERSION" LOCAL_APPCAST="$APPCAST" REMOTE_APPCAST="$remote_appcast" python3 <<'PY'
import os, sys, xml.etree.ElementTree as ET
ns = {'s': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
version = os.environ['VERSION']
root = ET.parse(os.environ['REMOTE_APPCAST']).getroot()
item = next((i for i in root.findall('./channel/item') if i.findtext('s:shortVersionString', namespaces=ns) == version), None)
if item is None or item.find('s:channel', ns) is not None:
    sys.exit(1)
local = ET.parse(os.environ['LOCAL_APPCAST']).getroot()
local_item = next(i for i in local.findall('./channel/item') if i.findtext('s:shortVersionString', namespaces=ns) == version)
for attr in ('url', 'length', '{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature'):
    if item.find('enclosure').get(attr) != local_item.find('enclosure').get(attr):
        sys.exit(1)
if item.findtext('s:version', namespaces=ns) != local_item.findtext('s:version', namespaces=ns):
    sys.exit(1)
PY
    then
      rm -f "$remote_appcast"
      verified=true
      break
    fi
    last_error="공개 appcast의 버전/메타데이터가 로컬과 다릅니다."
  else
    last_error="공개 appcast URL에 접근하지 못했습니다."
  fi
  rm -f "$remote_appcast"
  if (( elapsed == PUBLIC_VERIFY_TIMEOUT_SECONDS )); then break; fi
  sleep "$PUBLIC_VERIFY_INTERVAL_SECONDS"
  elapsed=$((elapsed + PUBLIC_VERIFY_INTERVAL_SECONDS))
done
if [[ "$verified" != true ]]; then
  fail "$last_error (최대 ${PUBLIC_VERIFY_TIMEOUT_SECONDS}초 대기)"
fi
echo "publish 완료: $TAG appcast를 검증·commit·push했습니다."
