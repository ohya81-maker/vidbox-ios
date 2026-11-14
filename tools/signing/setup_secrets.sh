#!/usr/bin/env bash
# Apple 개발자 사이트에서 받은 배포 인증서(.cer)와 Ad Hoc 프로필(.mobileprovision)을
# GitHub 저장소 시크릿으로 등록한다. 이후 GitHub 빌드가 IPA를 자동으로 서명한다.
#
# 사용법 (Git Bash):
#   bash tools/signing/setup_secrets.sh ~/Downloads/distribution.cer ~/Downloads/KTUBE_AdHoc.mobileprovision
#
# 개인키는 C:\Users\<사용자>\KTUBE-signing\ktube_distribution.key 에 있다 (저장소에 올리지 않는다).
set -euo pipefail

CER="${1:?배포 인증서 .cer 파일 경로를 넣어주세요}"
PROFILE="${2:?Ad Hoc .mobileprovision 파일 경로를 넣어주세요}"
SIGN_DIR="${KTUBE_SIGNING_DIR:-$HOME/KTUBE-signing}"
KEY="$SIGN_DIR/ktube_distribution.key"
[ -f "$KEY" ] || { echo "개인키가 없습니다: $KEY"; exit 1; }

# .cer(DER) → PEM, 개인키와 맞는지 확인
openssl x509 -inform DER -in "$CER" -out "$SIGN_DIR/distribution.pem" 2>/dev/null \
  || cp "$CER" "$SIGN_DIR/distribution.pem"
if [ "$(openssl x509 -noout -modulus -in "$SIGN_DIR/distribution.pem" | openssl md5)" != \
     "$(openssl rsa -noout -modulus -in "$KEY" | openssl md5)" ]; then
  echo "이 인증서는 KTUBE.certSigningRequest로 만든 것이 아닙니다 (개인키와 짝이 맞지 않음)."; exit 1
fi
echo "인증서: $(openssl x509 -noout -subject -enddate -in "$SIGN_DIR/distribution.pem")"

# .p12 비밀번호는 직접 정한다 (GitHub 시크릿에만 저장됨)
read -r -s -p "p12 비밀번호를 정해 입력하세요: " P12_PASS; echo
[ -n "$P12_PASS" ] || { echo "비밀번호가 비어 있습니다."; exit 1; }

# macOS 키체인이 읽을 수 있도록 호환 암호화(3DES/SHA1)로 만든다
openssl pkcs12 -export -inkey "$KEY" -in "$SIGN_DIR/distribution.pem" \
  -name "KTUBE Distribution" -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
  -passout "pass:$P12_PASS" -out "$SIGN_DIR/distribution.p12"
echo "p12 생성: $SIGN_DIR/distribution.p12"

cd "$(dirname "$0")/../.."
base64 -w0 "$SIGN_DIR/distribution.p12" | gh secret set IOS_P12_BASE64
printf '%s' "$P12_PASS" | gh secret set IOS_P12_PASSWORD
base64 -w0 "$PROFILE" | gh secret set IOS_PROFILE_BASE64
unset P12_PASS
echo "GitHub 시크릿 등록 완료: IOS_P12_BASE64, IOS_P12_PASSWORD, IOS_PROFILE_BASE64"
echo "이제 GitHub Actions에서 'Build IPA'를 다시 실행하면 서명된 IPA와 설치 사이트가 만들어집니다:"
echo "  gh workflow run build-ios.yml"
