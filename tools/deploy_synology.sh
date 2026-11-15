#!/usr/bin/env bash
# K-TUBE 설치 사이트를 시놀로지(\\NAS\docker\youtube)에 올린다.
#   1) GitHub 최신 릴리스의 IPA를 받고
#   2) 안드로이드 APK와 함께 설치 페이지를 만들고
#   3) 시놀로지 공유 폴더에 복사한 뒤 예전 버전 IPA를 지운다.
# 처음 한 번은 Windows 탐색기에서 \\172.30.1.27\docker 에 로그인(자격 증명 기억)해 두어야 한다.
#
# 사용: bash tools/deploy_synology.sh            (최신 릴리스)
#       bash tools/deploy_synology.sh --local    (지금 있는 KTUBE.ipa 그대로)
set -euo pipefail

NAS_DIR="${KTUBE_NAS_DIR:-//172.30.1.27/docker/youtube}"
BASE_URL="${KTUBE_BASE_URL:-https://mistylake.synology.me/ktube}"
APK="${KTUBE_APK:-../ktube-android/KTUBE.apk}"

cd "$(dirname "$0")/.."

if [ "${1:-}" != "--local" ]; then
  tag=$(gh release list -L 1 --json tagName -q '.[0].tagName')
  echo "최신 릴리스: $tag"
  gh release download "$tag" -p "*.ipa" -O KTUBE.ipa --clobber
fi

rm -rf dist/ktube
apk_args=()
[ -f "$APK" ] && apk_args=(--apk "$APK")
python tools/make_site.py KTUBE.ipa "${apk_args[@]}" --base "$BASE_URL" --out dist/ktube > /dev/null

if [ ! -d "$NAS_DIR" ]; then
  echo "시놀로지 폴더($NAS_DIR)에 접근할 수 없습니다. 탐색기에서 \\\\172.30.1.27\\docker 에 먼저 로그인하세요." >&2
  exit 1
fi

new_ipa=$(cd dist/ktube && ls KTUBE-*.ipa)
cp -f dist/ktube/* "$NAS_DIR/"
# 이번 버전이 아닌 예전 IPA 정리
for old in "$NAS_DIR"/KTUBE-*.ipa; do
  [ "$(basename "$old")" = "$new_ipa" ] || rm -f "$old"
done
echo "배포 완료: $new_ipa → $NAS_DIR"
ls -la "$NAS_DIR"
