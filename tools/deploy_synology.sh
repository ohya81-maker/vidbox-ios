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
  # 여러 빌드가 동시에 끝나도 빌드 번호가 가장 큰 릴리스를 고른다 (만든 순서가 아니라)
  tag=$(gh release list -L 15 --json tagName -q '.[].tagName' | grep -E '^build-[0-9]+$' | sort -t- -k2 -n | tail -1)
  echo "최신 릴리스: $tag"
  # 유료 계정 서명본이 있으면 그것을(Safari에서 바로 설치), 없으면 서명 안 된 IPA(SideStore용)
  if gh release view "$tag" --json assets -q '.assets[].name' | grep -qx "KTUBE-signed.ipa"; then
    gh release download "$tag" -p "KTUBE-signed.ipa" -O KTUBE.ipa --clobber
    echo "서명된 IPA 사용"
  else
    gh release download "$tag" -p "*.ipa" -O KTUBE.ipa --clobber
  fi
fi

rm -rf dist/ktube
apk_args=()
[ -f "$APK" ] && apk_args=(--apk "$APK")
notes_args=()
[ -f site/whatsnew.txt ] && notes_args=(--notes "$(cat site/whatsnew.txt)")
python tools/make_site.py KTUBE.ipa "${apk_args[@]}" "${notes_args[@]}" --base "$BASE_URL" --out dist/ktube > /dev/null

if [ ! -d "$NAS_DIR" ]; then
  echo "시놀로지 폴더($NAS_DIR)에 접근할 수 없습니다. 탐색기에서 \\\\172.30.1.27\\docker 에 먼저 로그인하세요." >&2
  exit 1
fi

new_ipa=$(cd dist/ktube && ls KTUBE-*.ipa)
cp -f dist/ktube/* "$NAS_DIR/"
# 예전 IPA는 최근 5개까지 남긴다 — SideStore가 예전 목록(apps.json)을 기억하고 있어도
# 그 주소의 파일이 있어야 설치가 되고, 목록을 새로 받으면 최신 버전으로 업데이트된다
ls -1t "$NAS_DIR"/KTUBE-*.ipa 2>/dev/null | tail -n +6 | while read -r old; do rm -f "$old"; done
ls -1t "$NAS_DIR"/KTUBE-android-*.apk 2>/dev/null | tail -n +4 | while read -r old; do rm -f "$old"; done
echo "배포 완료: $new_ipa → $NAS_DIR"
ls -la "$NAS_DIR"
