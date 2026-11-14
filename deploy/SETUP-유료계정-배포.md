# KTUBE 웹 설치 배포 (유료 Apple Developer 계정 · Ad Hoc)

목표: 아이폰 Safari에서 `https://mistylake.synology.me:8443` 을 열고 **「이 아이폰에 바로 설치」** 한 번으로 설치.
서명은 1년 유효. 새 버전은 GitHub 빌드가 자동으로 서명합니다.

---

## 1. Apple Developer Program 가입 (연 $99)
- https://developer.apple.com/programs/ → Enroll (아이폰의 *Apple Developer* 앱으로 하면 간단)
- 승인까지 보통 1~2일

## 2. Apple 개발자 사이트에서 4가지 만들기 (https://developer.apple.com/account/resources)

| 순서 | 메뉴 | 입력값 |
|---|---|---|
| ① 인증서 | Certificates → **+** → **Apple Distribution** | CSR 파일: `C:\Users\misty\KTUBE-signing\KTUBE.certSigningRequest` → 만든 뒤 `.cer` 다운로드 |
| ② 기기 | Devices → **+** → iOS | 이름: `SeoAs Daddy` · UDID: `00008130-000515D83E12001C` |
| ③ 앱 ID | Identifiers → **+** → App IDs → App | Description: `KTUBE` · Bundle ID(Explicit): `com.mistylake.ktube` · Capabilities: 체크 없음 |
| ④ 프로필 | Profiles → **+** → **Ad Hoc** | App ID: `com.mistylake.ktube` · 인증서: ①에서 만든 것 · 기기: ② 체크 · 이름: `KTUBE AdHoc` → `.mobileprovision` 다운로드 |

> 가족 아이폰을 추가하려면 ②에 기기를 더 등록하고 ④ 프로필을 다시 만들어 3단계를 반복합니다 (1년에 최대 100대).

## 3. 인증서·프로필을 GitHub에 등록 (이 PC, Git Bash)
```bash
cd "/c/Claude Project/youtube/ios-app"
bash tools/signing/setup_secrets.sh ~/Downloads/distribution.cer ~/Downloads/KTUBE_AdHoc.mobileprovision
```
- p12 비밀번호를 직접 정해 입력합니다 (GitHub 시크릿에만 저장).
- 개인키(`C:\Users\misty\KTUBE-signing\ktube_distribution.key`)는 **절대 공유하지 마세요.**

그다음 빌드 실행:
```bash
gh workflow run build-ios.yml
```
완료되면 GitHub Releases에 `KTUBE-signed.ipa` 와 `ktube-site.zip` 이 생깁니다.

## 4. 시놀로지 설정 (처음 한 번)

### 4-1. 파일 올리기
`ktube-site.zip` 압축을 풀면 아래 구조입니다. 그대로 **File Station → docker/youtube** 에 올립니다.
```
docker/youtube/
├── docker-compose.yml
├── nginx.conf
└── site/
    ├── index.html  manifest.plist  apps.json  icon.png
    └── KTUBE-x.y.z.ipa
```

### 4-2. 컨테이너 실행
Container Manager → 프로젝트 → 생성 → 이름 `ktube` · 경로 `/docker/youtube` · 기존 docker-compose.yml 사용 → 완료
(nginx가 `http://시놀로지IP:8090` 에서 사이트를 제공)

### 4-3. HTTPS 연결 (리버스 프록시)
제어판 → 로그인 포털 → 고급 → 리버스 프록시 → 생성
- 소스: 프로토콜 `HTTPS` · 호스트 이름 `mistylake.synology.me` · 포트 `8443`
- 대상: 프로토콜 `HTTP` · 호스트 이름 `localhost` · 포트 `8090`

제어판 → 보안 → 인증서 → 설정에서 이 리버스 프록시 항목에 `mistylake.synology.me` 인증서가 지정됐는지 확인.
공유기에서 **8443 포트**를 시놀로지로 포트포워딩합니다.

### 4-4. 아이폰에서 설치
Safari로 `https://mistylake.synology.me:8443` → **이 아이폰에 바로 설치** → 홈 화면에 KTUBE 설치
(설정 → 일반 → VPN 및 기기 관리 → 신뢰 가 필요할 수 있음)

## 5. 이후 업데이트
- 코드가 바뀌어 GitHub 빌드가 끝날 때마다 `ktube-site.zip` 이 새로 생깁니다 → `site/` 폴더만 덮어쓰기.
- 자동 업로드를 원하면 시놀로지 **WebDAV Server** 패키지를 켜고 GitHub 시크릿 3개를 등록:
  `SYNOLOGY_WEBDAV_URL` (예: `https://mistylake.synology.me:5006/docker/youtube/site`),
  `SYNOLOGY_WEBDAV_USER`, `SYNOLOGY_WEBDAV_PASSWORD` (업로드 전용 계정 권장)
