<?php
// 아이폰 UDID를 알려 주는 일회용 프로필 (설치하면 아이폰이 udid.php 로 기기 정보를 보내고 끝남 — 남지 않음)
require __DIR__ . '/lib.php';
$url = kt_base_url() . '/udid.php';
$uuid = sprintf('%04X%04X-%04X-%04X-%04X-%04X%04X%04X', mt_rand(0, 65535), mt_rand(0, 65535), mt_rand(0, 65535),
    mt_rand(16384, 20479), mt_rand(32768, 49151), mt_rand(0, 65535), mt_rand(0, 65535), mt_rand(0, 65535));
header('Content-Type: application/x-apple-aspen-config');
header('Content-Disposition: attachment; filename="ktube-register.mobileconfig"');
header('Cache-Control: no-store');
echo <<<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>PayloadContent</key>
  <dict>
    <key>URL</key>
    <string>{$url}</string>
    <key>DeviceAttributes</key>
    <array>
      <string>UDID</string>
      <string>PRODUCT</string>
      <string>VERSION</string>
    </array>
  </dict>
  <key>PayloadOrganization</key>
  <string>K-TUBE</string>
  <key>PayloadDisplayName</key>
  <string>K-TUBE 기기 등록</string>
  <key>PayloadDescription</key>
  <string>K-TUBE 앱을 이 아이폰에 설치할 수 있도록 기기 식별번호(UDID)를 등록합니다. 설치 후 남는 설정은 없습니다.</string>
  <key>PayloadVersion</key>
  <integer>1</integer>
  <key>PayloadUUID</key>
  <string>{$uuid}</string>
  <key>PayloadIdentifier</key>
  <string>me.synology.mistylake.ktube.register</string>
  <key>PayloadType</key>
  <string>Profile Service</string>
</dict>
</plist>
XML;
