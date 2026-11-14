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

page = open(os.path.join(ROOT, "site", "index.html"), encoding="utf-8").read()
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
