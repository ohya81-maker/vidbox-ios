"""시놀로지(또는 아무 HTTPS 웹서버)에 올릴 KTUBE 설치 사이트를 만든다.

사용법:
    python tools/make_site.py [IPA 경로] [--base https://mistylake.synology.me/ktube] [--notes "변경 내용"]

결과: dist/ktube/ 폴더 (index.html, apps.json, icon.png, KTUBE-<버전>.ipa)
이 폴더를 통째로 시놀로지 Web Station 웹 폴더(예: /web/ktube)에 올리면 된다.
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
parser.add_argument("--base", default="https://mistylake.synology.me/ktube")
parser.add_argument("--notes", default="")
parser.add_argument("--out", default=os.path.join(ROOT, "dist", "ktube"))
args = parser.parse_args()

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
bundle_id = info.get("CFBundleIdentifier", bundle_id)
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
    "name": "KTUBE",
    "identifier": "me.synology.mistylake.ktube",
    "subtitle": "개인용 KTUBE 앱 배포",
    "sourceURL": f"{base}/apps.json",
    "iconURL": f"{base}/icon.png",
    "website": f"{base}/",
    "tintColor": "#E0262B",
    "apps": [
        {
            "name": "KTUBE",
            "bundleIdentifier": bundle_id,
            "developerName": "KTUBE",
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
            "title": "KTUBE",
        },
    }]
}
with open(os.path.join(args.out, "manifest.plist"), "wb") as f:
    plistlib.dump(manifest, f)
itms = "itms-services://?action=download-manifest&url=" + urllib.parse.quote(f"{base}/manifest.plist", safe="")
if signed:
    direct = (f'<a class="btn primary" href="{itms}">이 아이폰에 바로 설치</a>'
              f'<p class="hint">서명된 IPA입니다 (번들 ID <code>{bundle_id}</code>). 설치 후 설정 → 일반 → VPN 및 기기 관리에서 신뢰를 눌러주세요.</p>')
else:
    direct = ('<p class="hint">지금 올린 IPA는 서명되지 않아 바로 설치할 수 없습니다. '
              '서명된 IPA로 이 페이지를 다시 만들면 여기에 「바로 설치」 버튼이 생깁니다.</p>')

page = open(os.path.join(ROOT, "site", "index.html"), encoding="utf-8").read()
page = page.replace("{{DIRECT_INSTALL}}", direct)
source_url = f"{base}/apps.json"
for key, value in {
    "{{VERSION}}": version,
    "{{BUILD}}": build,
    "{{DATE}}": today,
    "{{SIZE}}": f"{size / 1024 / 1024:.1f}MB",
    "{{SOURCE_URL}}": source_url,
    "{{SOURCE_URL_ENC}}": urllib.parse.quote(source_url, safe=""),
    "{{IPA_NAME}}": ipa_name,
    "{{NOTES}}": notes.replace("<", "&lt;"),
}.items():
    page = page.replace(key, value)
with open(os.path.join(args.out, "index.html"), "w", encoding="utf-8") as f:
    f.write(page)

print(f"done: {args.out}  (version {version} build {build}, {size} bytes)")
for name in sorted(os.listdir(args.out)):
    print("  ", name)
