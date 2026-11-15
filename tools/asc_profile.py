#!/usr/bin/env python3
"""App Store Connect API로 기기를 등록하고, 등록된 모든 아이폰이 들어간 Ad Hoc 프로필을 새로 만든다.

필요한 환경 변수: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8 (.p8 파일 내용)
사용:
  python3 tools/asc_profile.py --out profile.mobileprovision [--udid UDID --name 이름] [--cert-serial HEX]
외부 패키지 없이 openssl 명령으로 ES256 서명을 만든다.
"""
import argparse
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_ID = "com.mistylake.ktube"
PROFILE_NAMES = {"adhoc": "KTUBE AdHoc Auto", "appstore": "KTUBE AppStore Auto"}


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw(sig: bytes) -> bytes:
    """ECDSA DER 서명(SEQUENCE{r,s}) → JWT용 r||s (각 32바이트)"""
    assert sig[0] == 0x30
    i = 2 if sig[1] < 0x80 else 2 + (sig[1] & 0x7F)
    out = b""
    for _ in range(2):
        assert sig[i] == 0x02
        length = sig[i + 1]
        value = sig[i + 2:i + 2 + length].lstrip(b"\x00")
        out += value.rjust(32, b"\x00")
        i += 2 + length
    return out


def make_token() -> str:
    key_id = os.environ["ASC_KEY_ID"].strip()
    issuer = os.environ["ASC_ISSUER_ID"].strip()
    p8 = os.environ["ASC_KEY_P8"].strip()
    header = b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    now = int(time.time())
    claims = b64url(json.dumps({"iss": issuer, "iat": now, "exp": now + 1000, "aud": "appstoreconnect-v1"}).encode())
    signing_input = f"{header}.{claims}".encode()
    with tempfile.NamedTemporaryFile("w", suffix=".p8", delete=False) as f:
        f.write(p8 if p8.endswith("\n") else p8 + "\n")
        key_path = f.name
    try:
        der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path],
                             input=signing_input, capture_output=True, check=True).stdout
    finally:
        os.unlink(key_path)
    return f"{header}.{claims}.{b64url(der_to_raw(der))}"


TOKEN = None


def call(method, path, body=None):
    url = path if path.startswith("http") else API + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": f"Bearer {TOKEN}",
        "Content-Type": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"raw": raw.decode(errors="replace")}


def get_all(path):
    items, url = [], path
    while url:
        status, js = call("GET", url)
        if status != 200:
            sys.exit(f"GET {path} 실패 {status}: {js}")
        items += js.get("data", [])
        url = js.get("links", {}).get("next")
    return items


def register(udid, name):
    udid = udid.strip()
    for d in get_all("/devices?limit=200&filter[udid]=" + urllib.parse.quote(udid)):
        if d["attributes"]["udid"].lower() == udid.lower():
            if d["attributes"]["status"] != "ENABLED":
                call("PATCH", f"/devices/{d['id']}",
                     {"data": {"type": "devices", "id": d["id"], "attributes": {"status": "ENABLED"}}})
                print(f"기기 다시 사용: {udid}")
            else:
                print(f"이미 등록된 기기: {udid}")
            return
    status, js = call("POST", "/devices", {"data": {"type": "devices", "attributes": {
        "name": name[:50], "udid": udid, "platform": "IOS"}}})
    if status not in (200, 201):
        sys.exit(f"기기 등록 실패 {status}: {js}")
    print(f"기기 등록: {name} ({udid})")


def main():
    global TOKEN
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--udid", default="")
    ap.add_argument("--name", default="K-TUBE device")
    ap.add_argument("--cert-serial", default="")
    ap.add_argument("--type", choices=["adhoc", "appstore"], default="adhoc")
    args = ap.parse_args()
    TOKEN = make_token()
    PROFILE_NAME = PROFILE_NAMES[args.type]

    if args.udid:
        register(args.udid, args.name)

    devices = [d for d in get_all("/devices?limit=200&filter[platform]=IOS&filter[status]=ENABLED")
               if d["attributes"].get("deviceClass") in (None, "IPHONE", "IPAD", "IPOD")]
    print(f"등록된 기기 {len(devices)}대")

    bundles = [b for b in get_all("/bundleIds?limit=200&filter[identifier]=" + BUNDLE_ID)
               if b["attributes"]["identifier"] == BUNDLE_ID]
    if not bundles:
        sys.exit(f"번들 ID {BUNDLE_ID} 를 찾을 수 없습니다")
    bundle_id = bundles[0]["id"]

    certs = [c for c in get_all("/certificates?limit=200")
             if c["attributes"]["certificateType"] in ("DISTRIBUTION", "IOS_DISTRIBUTION")]
    want = args.cert_serial.upper().lstrip("0")
    chosen = [c for c in certs if c["attributes"].get("serialNumber", "").upper().lstrip("0") == want] if want else []
    if not chosen:
        chosen = sorted(certs, key=lambda c: c["attributes"].get("expirationDate", ""), reverse=True)[:1]
    if not chosen:
        sys.exit("배포(Distribution) 인증서를 찾을 수 없습니다")
    print(f"인증서: {chosen[0]['attributes'].get('name')} {chosen[0]['attributes'].get('serialNumber')}")

    # 예전 자동 프로필 지우고 새로 (이름이 같으면 만들 수 없음)
    for p in get_all("/profiles?limit=200&filter[name]=" + urllib.parse.quote(PROFILE_NAME)):
        if p["attributes"]["name"] == PROFILE_NAME:
            call("DELETE", f"/profiles/{p['id']}")

    status, js = call("POST", "/profiles", {"data": {
        "type": "profiles",
        "attributes": {"name": PROFILE_NAME,
                       "profileType": "IOS_APP_ADHOC" if args.type == "adhoc" else "IOS_APP_STORE"},
        "relationships": {
            "bundleId": {"data": {"type": "bundleIds", "id": bundle_id}},
            "certificates": {"data": [{"type": "certificates", "id": chosen[0]["id"]}]},
            **({"devices": {"data": [{"type": "devices", "id": d["id"]} for d in devices]}}
               if args.type == "adhoc" else {}),
        },
    }})
    if status not in (200, 201):
        sys.exit(f"프로필 생성 실패 {status}: {js}")
    content = js["data"]["attributes"]["profileContent"]
    with open(args.out, "wb") as f:
        f.write(base64.b64decode(content))
    print(f"프로필 생성: {PROFILE_NAME} (기기 {len(devices)}대) → {args.out}")


if __name__ == "__main__":
    main()
