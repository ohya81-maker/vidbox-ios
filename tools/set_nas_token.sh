#!/usr/bin/env bash
# 시놀로지 등록 페이지가 GitHub 작업을 시작할 때 쓸 토큰을 NAS에 저장한다.
# 토큰은 화면에 보이지 않게 입력받아 \\NAS\docker\youtube\.private\config.php 에만 쓴다 (웹에서는 실행만 되고 내용은 안 보임).
set -euo pipefail
NAS_DIR="${KTUBE_NAS_DIR:-//172.30.1.27/docker/youtube}"
mkdir -p "$NAS_DIR/.private"
printf 'GitHub 토큰(github_pat_...)을 붙여넣고 Enter: '
read -rs TOKEN
echo
case "$TOKEN" in
  github_pat_*|ghp_*) ;;
  *) echo "토큰 형식이 아닙니다 (github_pat_ 로 시작해야 함)"; exit 1 ;;
esac
printf "<?php return ['github_token' => '%s', 'repo' => 'ohya81-maker/vidbox-ios'];\n" "$TOKEN" > "$NAS_DIR/.private/config.php"
echo "저장 완료: $NAS_DIR/.private/config.php"
