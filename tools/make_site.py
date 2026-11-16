"""시놀로지(또는 아무 HTTPS 웹서버)에 올릴 KTUBE 설치 사이트를 만든다.

사용법:
    python tools/make_site.py [IPA 경로] [--apk KTUBE.apk] [--base https://mistylake.synology.me:8443] [--notes "변경 내용"]

결과: dist/youtube/ 폴더
    index.html, manifest.xml(+.plist), apps.json, icon.png, KTUBE-<버전>.ipa [, KTUBE.apk]
이 파일들을 시놀로지 /docker/youtube 에 올리고 Web Station 별칭(youtube)으로 연결하면
https://mistylake.synology.me/youtube 로 열린다.  (--docker 를 주면 nginx 컨테이너용 파일도 함께 만든다)
"""
import argparse
import datetime
import json
import os
import re
import shutil
import urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

parser = argparse.ArgumentParser()
parser.add_argument("ipa", nargs="?", default=os.path.join(ROOT, "KTUBE.ipa"))
parser.add_argument("--base", default="https://mistylake.synology.me/youtube")
parser.add_argument("--notes", default="")
parser.add_argument("--apk", default="", help="안드로이드 APK 경로 (있으면 사이트에 함께 올림)")
parser.add_argument("--out", default=os.path.join(ROOT, "dist", "youtube"))
parser.add_argument("--docker", action="store_true", help="nginx 컨테이너용 설정 파일도 함께 만든다")
args = parser.parse_args()

os.makedirs(args.out, exist_ok=True)
# (선택) 사이트 폴더 옆에 시놀로지 Docker(nginx) 설정 파일
if args.docker:
    bundle_dir = os.path.dirname(os.path.abspath(args.out))
    for name in ("docker-compose.yml", "nginx.conf", "compose-snippet.yaml"):
        shutil.copyfile(os.path.join(ROOT, "deploy", "synology", name), os.path.join(bundle_dir, name))
# 이전 버전 IPA는 지운다 (사이트에는 최신 하나만)
if os.path.isdir(args.out):
    for old in os.listdir(args.out):
        if old.endswith(".ipa") or (args.apk and old.endswith(".apk")):
            os.remove(os.path.join(args.out, old))

project = open(os.path.join(ROOT, "project.yml"), encoding="utf-8").read()
version = re.search(r'MARKETING_VERSION: "([^"]+)"', project).group(1)
build = re.search(r'CURRENT_PROJECT_VERSION: "([^"]+)"', project).group(1)
bundle_id = re.search(r"PRODUCT_BUNDLE_IDENTIFIER: (\S+)", project).group(1)
min_os = re.search(r'iOS: "([^"]+)"', project).group(1)

# IPA 안의 Info.plist / 서명 여부를 직접 읽는다.
# (Sideloadly 등으로 서명하면 번들 ID가 바뀌므로 manifest.plist에는 IPA 안의 값을 써야 설치된다)
import plistlib
import zipfile
with zipfile.ZipFile(args.ipa) as z:
    names = z.namelist()
    info_name = next(n for n in names if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n))
    app_dir = info_name.rsplit("/", 1)[0]
    info = plistlib.loads(z.read(info_name))
    signed = f"{app_dir}/embedded.mobileprovision" in names and any(n.startswith(f"{app_dir}/_CodeSignature/") for n in names)
    # 서명된 IPA라면 프로비저닝 프로필(만료일, 등록된 기기 수, 팀)을 읽어 보여준다
    profile = {}
    if signed:
        raw = z.read(f"{app_dir}/embedded.mobileprovision")
        start, end = raw.find(b"<?xml"), raw.find(b"</plist>")
        if start >= 0 and end > start:
            profile = plistlib.loads(raw[start:end + len(b"</plist>")])
bundle_id = info.get("CFBundleIdentifier", bundle_id)
expires = profile.get("ExpirationDate")
if signed:
    print(f"서명됨: 팀={profile.get('TeamName')} 번들ID={info.get('CFBundleIdentifier')} "
          f"기기 {len(profile.get('ProvisionedDevices', []))}대 만료={expires} "
          f"개발용={profile.get('Entitlements', {}).get('get-task-allow')}")
else:
    print("서명되지 않은 IPA입니다 (plist 바로 설치 불가, SideStore/Sideloadly용)")
version = info.get("CFBundleShortVersionString", version)
build = info.get("CFBundleVersion", build)

base = args.base.rstrip("/")
os.makedirs(args.out, exist_ok=True)

ipa_name = f"KTUBE-{version}.ipa"
shutil.copyfile(args.ipa, os.path.join(args.out, ipa_name))
shutil.copyfile(os.path.join(ROOT, "Vidbox", "Assets.xcassets", "AppIcon.appiconset", "icon-1024.png"),
                os.path.join(args.out, "icon.png"))
size = os.path.getsize(args.ipa)
today = datetime.date.today().isoformat()
notes = args.notes or f"KTUBE {version}"

source = {
    "name": "K-TUBE",
    # 예전 소스(/youtube/apps.json, 지금은 없음)와 같은 identifier면 SideStore가
    # 다시 추가해도 예전 주소의 소스를 그대로 써서 1.7.5에 멈춰 있었다 → 새 identifier
    "identifier": "me.synology.mistylake.ktube.v2",
    "subtitle": "개인용 KTUBE 앱 배포",
    "sourceURL": f"{base}/apps.json",
    "iconURL": f"{base}/icon.png",
    "website": f"{base}/",
    "tintColor": "#E0262B",
    "apps": [
        {
            "name": "K-TUBE",
            "bundleIdentifier": bundle_id,
            "developerName": "K-TUBE",
            "subtitle": "광고 없는 동영상·음악 플레이어",
            "localizedDescription": "홈·쇼츠·음악·KIDS, 백그라운드 재생, 잠금화면 컨트롤을 지원하는 개인용 동영상 앱.",
            "iconURL": f"{base}/icon.png",
            "tintColor": "#E0262B",
            "category": "entertainment",
            "screenshots": [],
            "versions": [
                {
                    "version": version,
                    "buildVersion": build,
                    "date": today,
                    "localizedDescription": notes,
                    "downloadURL": f"{base}/{ipa_name}",
                    "size": size,
                    "minOSVersion": min_os,
                }
            ],
            "appPermissions": {"entitlements": [], "privacy": {}},
        }
    ],
    "news": [],
}
with open(os.path.join(args.out, "apps.json"), "w", encoding="utf-8") as f:
    json.dump(source, f, ensure_ascii=False, indent=2)

# itms-services 직접 설치용 manifest.plist (서명된 IPA일 때만 실제로 설치됨)
manifest = {
    "items": [{
        "assets": [
            {"kind": "software-package", "url": f"{base}/{ipa_name}"},
            {"kind": "display-image", "url": f"{base}/icon.png"},
            {"kind": "full-size-image", "url": f"{base}/icon.png"},
        ],
        "metadata": {
            "bundle-identifier": bundle_id,
            "bundle-version": version,
            "kind": "software",
            "title": "K-TUBE",
        },
    }]
}
# Web Station 등은 .plist 를 XML 형식으로 알려주지 않을 수 있어 .xml 로도 만들고 그쪽을 쓴다
for name in ("manifest.plist", "manifest.xml"):
    with open(os.path.join(args.out, name), "wb") as f:
        plistlib.dump(manifest, f)
itms = "itms-services://?action=download-manifest&url=" + urllib.parse.quote(f"{base}/manifest.xml", safe="")
if signed:
    # 버튼 하나: 이 기기에서 등록을 마친 적이 있으면 바로 설치, 처음이면 등록(프로필) → 자동 설치
    direct = ('<a class="btn primary" href="testflight.html"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 4v11M7 10l5 5 5-5M5 20h14"/></svg>TestFlight로 설치 (추천)</a>'
              '<p class="hint">개발자 모드가 필요 없어요. 초대 코드와 Apple ID 이메일로 한 번 신청하면 TestFlight 앱에서 설치·업데이트해요.</p>'
              f'<a class="btn secondary" id="ios-install" href="register.html?auto=1" data-itms="{itms}" style="margin-top:14px">개발자 모드로 바로 설치</a>'
              '<p class="hint" id="ios-hint">개발자 모드를 켠 아이폰용이에요. 처음이면 등록 프로필을 한 번 설치하면 몇 분 뒤 설치 창이 자동으로 떠요.</p>'
              f'<p class="hint"><a href="{itms}" style="color:inherit">이미 등록된 아이폰이면 여기를 눌러 바로 설치</a></p>'
              '<script>(function(){var b=document.getElementById("ios-install");'
              'try{if(localStorage.getItem("ktube.registered")==="1"){b.href=b.dataset.itms;'
              'document.getElementById("ios-hint").textContent="등록된 아이폰이에요. 누르면 바로 설치돼요.";}}catch(e){}})();</script>')
else:
    direct = ('<p class="hint">지금 올린 IPA는 서명되지 않아 바로 설치할 수 없습니다. '
              '서명된 IPA로 이 페이지를 다시 만들면 여기에 「바로 설치」 버튼이 생깁니다.</p>')

# 안드로이드 APK (있으면)
apk_block = ('<p class="hint" style="margin:0">안드로이드 앱은 준비 중이에요. 완성되면 이 자리에 설치 버튼이 생깁니다.</p>')
if args.apk and os.path.exists(args.apk):
    apk_name = "KTUBE.apk"
    shutil.copyfile(args.apk, os.path.join(args.out, apk_name))
    apk_mb = os.path.getsize(args.apk) / 1024 / 1024
    apk_block = (
        f'<a class="btn primary" href="{apk_name}" download><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 4v11M7 10l5 5 5-5M5 20h14"/></svg>KTUBE.apk 내려받기 ({apk_mb:.1f}MB)</a>'
        '<ol class="steps">'
        '<li>내려받기가 끝나면 알림이나 「다운로드」에서 <b>KTUBE.apk</b>를 엽니다.</li>'
        '<li>「출처를 알 수 없는 앱」 경고가 나오면 <b>설정 → 이 출처 허용</b>을 켜고 돌아와 <b>설치</b>를 누릅니다.</li>'
        '<li>업데이트할 때도 같은 방법으로 덮어 설치하면 됩니다 (데이터 유지).</li>'
        '</ol>')
    print(f"APK 포함: {apk_name} ({apk_mb:.1f}MB)")

page = open(os.path.join(ROOT, "site", "index.html"), encoding="utf-8").read()
page = page.replace("{{DIRECT_INSTALL}}", direct).replace("{{APK_INSTALL}}", apk_block)
source_url = f"{base}/apps.json"
for key, value in {
    "{{VERSION}}": version,
    "{{BUILD}}": build,
    "{{DATE}}": today,
    "{{SIZE}}": f"{size / 1024 / 1024:.1f}MB",
    "{{SOURCE_URL}}": source_url,
    "{{SOURCE_URL_ENC}}": urllib.parse.quote(source_url, safe=""),
    "{{IPA_NAME}}": ipa_name,
    "{{BASE_URL}}": base,
    "{{NOTES}}": notes.replace("<", "&lt;"),
    "{{MIN_OS}}": min_os,
}.items():
    page = page.replace(key, value)
with open(os.path.join(args.out, "index.html"), "w", encoding="utf-8") as f:
    f.write(page)

# 기기 등록(PHP) 파일들
for name in ("register.html", "enroll.php", "udid.php", "status.php", "lib.php", "invite.php", "testflight.html"):
    shutil.copyfile(os.path.join(ROOT, "site", name), os.path.join(args.out, name))

# 설치 페이지 QR (외부 스크립트 없이 이미지로)
try:
    import qrcode
    qrcode.make(f"{base}/", border=1, box_size=10).save(os.path.join(args.out, "qr.png"))
except ImportError:
    print("qrcode 모듈이 없어 qr.png를 만들지 못했습니다 (pip install qrcode[pil])")

print(f"done: {args.out}  (version {version} build {build}, {size} bytes)")
for name in sorted(os.listdir(args.out)):
    print("  ", name)
