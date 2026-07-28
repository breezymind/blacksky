#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPCAST="$ROOT/public/appcast.xml"

python3 - "$APPCAST" <<'PY'
import sys, xml.etree.ElementTree as ET
ns = {'s': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
root = ET.parse(sys.argv[1]).getroot()
items = root.findall('./channel/item')
stable = [i for i in items if i.findtext('s:shortVersionString', namespaces=ns) == '1.0.44']
assert len(stable) == 1, '1.0.44 appcast 항목이 정확히 하나여야 합니다.'
item = stable[0]
assert item.find('s:channel', ns) is None, '1.0.44는 기본 채널이어야 합니다.'
assert item.findtext('s:version', namespaces=ns) == '45'
enclosure = item.find('enclosure')
assert enclosure.get('url') == 'https://github.com/breezymind/blacksky/releases/download/v1.0.44/blacksky-1.0.44.dmg'
assert enclosure.get('length') == '214236599'
assert enclosure.get('{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature') == 'ZE8kG0AqDGf/ASCsXc+X+UQz3uUplG9Ze+vKEPp/NWiTisnFlR5QCKLgFvgKJNS0WiUvJi3v2Ramn9FD9gPuDw=='
PY

if grep -q '<sparkle:channel>release</sparkle:channel>' "$ROOT/scripts/release.sh"; then
  echo 'release.sh가 안정 항목에 명시 채널을 생성합니다.' >&2
  exit 1
fi
if ! grep -q 'publish.sh' "$ROOT/../blacksky/scripts/pipeline-release.sh"; then
  echo 'pipeline-release.sh가 publish 단계를 안내하지 않습니다.' >&2
  exit 1
fi
bash -c "grep -q -- '--resume' '$ROOT/../blacksky/scripts/pipeline-release.sh'"
bash -c "grep -q -- '--allow-dirty' '$ROOT/../blacksky/scripts/pipeline-release.sh'"
bash -c "grep -q 'origin/main' '$ROOT/../blacksky/scripts/pipeline-release.sh'"
bash -c "grep -q 'release-state' '$ROOT/../blacksky/scripts/pipeline-release.sh'"
bash -c "grep -q 'xcodebuild' '$ROOT/../blacksky/scripts/pipeline-release.sh'"
bash -c "grep -q 'source-committed' '$ROOT/../blacksky/scripts/pipeline-release.sh'"
bash -c "grep -q 'PIPELINE_ROOT' '$ROOT/scripts/publish.sh'"
python3 - "$ROOT/scripts/publish.sh" "$ROOT/../blacksky/.gitignore" "$ROOT/.gitignore" <<'PY'
import sys
publish = open(sys.argv[1], encoding='utf-8').read()
push = publish.index('git -C "$REPO_ROOT" push')
remote_poll = publish.index('# The public Pages copy may lag')
assert push < remote_poll, 'publish는 appcast push 후 공개 URL을 검증해야 합니다.'
assert '.release-state/' in open(sys.argv[2], encoding='utf-8').read()
assert '.release-state/' in open(sys.argv[3], encoding='utf-8').read()
PY
bash -n "$ROOT/scripts/release.sh" "$ROOT/scripts/publish.sh" "$ROOT/../blacksky/scripts/pipeline-release.sh"
echo 'release script tests passed'
