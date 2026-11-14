# KTUBE — 개인용 iOS 동영상 플레이어

YouTube 콘텐츠를 광고 없이 보고, **화면이 꺼져도 / 다른 앱으로 가도 계속 재생**되는 개인용 iPhone 앱입니다.
앱스토어 배포용이 아니며, 본인 아이폰에 직접 설치(사이드로딩)해서 사용합니다.

> ⚠️ 이 앱은 YouTube 스트림을 직접 추출합니다(YouTubeKit). 이는 YouTube 이용약관에 어긋나며,
> YouTube 측 변경으로 재생이 갑자기 안 될 수 있습니다. 그럴 땐 `project.yml`의 YouTubeKit 버전을 올려 다시 빌드하세요.

## 기능
- 홈: 카테고리 칩(전체/음악/K-POP/뉴스/게임…) + 무한 스크롤 피드
- 검색: 자동완성, 최근 검색어
- 플레이어: 유튜브 스타일 상단 영상 + 제목/채널 + 다음 동영상 목록, 아래로 끌어 최소화
- 미니 플레이어: 탭바 위에 고정, 탭하면 다시 펼침
- **백그라운드 재생 / 화면 꺼짐 재생 / 잠금화면·제어센터 컨트롤**(재생/일시정지/10초 이동/다음 곡/탐색)
- 오디오 전용 모드(데이터·배터리 절약), 다음 동영상 자동재생
- 보관함: 시청 기록, 나중에 볼 동영상 (기기 안에만 저장, 로그인 없음)

## 제약
- 영상 화질: 영상+소리가 합쳐진 스트림은 YouTube가 360p까지만 제공합니다. (음악 감상용 오디오 전용 모드는 고음질)
- 로그인/구독 피드/댓글 없음

---

## 빌드 (Mac 없이, GitHub Actions)
1. 이 폴더를 GitHub 저장소(private 권장)에 push 하면 `.github/workflows/build-ios.yml`이 macOS 서버에서 자동 빌드합니다.
2. 완료되면 저장소의 **Releases**에 `Vidbox.ipa`가 올라옵니다. (Actions 탭 → 실행 결과 → Artifacts에도 있음)
3. 수동 재빌드: Actions 탭 → *Build IPA* → *Run workflow*

## iPhone에 설치 (Windows + 무료 Apple ID, 개발자 등록 불필요)
1. Windows에 **iTunes**와 **iCloud**를 설치 — Microsoft Store 버전이 아닌 **apple.com 웹 설치판**이어야 합니다.
2. **Sideloadly**(sideloadly.io) 설치.
3. iPhone을 USB로 연결하고 "이 컴퓨터를 신뢰" 허용.
4. Sideloadly에 `Vidbox.ipa`를 끌어놓고, Apple ID 입력 → **Start**. (2단계 인증 코드는 iPhone에 뜹니다)
5. iPhone 설정:
   - 설정 → 개인정보 보호 및 보안 → **개발자 모드** 켜기 (재부팅됨)
   - 설정 → 일반 → **VPN 및 기기 관리** → 내 Apple ID → **신뢰**
6. 실행!

### 7일마다 재서명
무료 Apple ID로 설치한 앱은 **7일 후 실행이 안 됩니다**(데이터는 유지). Sideloadly로 같은 IPA를 다시 설치하면 됩니다.
Sideloadly의 *Automatic Refresh* 옵션을 켜두면 PC와 iPhone이 같은 Wi-Fi일 때 자동으로 갱신됩니다.
