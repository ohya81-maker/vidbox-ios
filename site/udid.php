<?php
// 아이폰이 프로필 설치 중에 기기 정보(서명된 plist)를 보내는 곳.
// UDID를 저장하고 GitHub 「Register device」 작업을 시작한 뒤, 진행 화면으로 보낸다 (301 필수).
require __DIR__ . '/lib.php';

$body = file_get_contents('php://input') ?: '';
preg_match('/<key>UDID<\/key>\s*<string>([^<]+)<\/string>/', $body, $m);
preg_match('/<key>PRODUCT<\/key>\s*<string>([^<]+)<\/string>/', $body, $p);
$udid = trim($m[1] ?? '');
$product = trim($p[1] ?? 'iPhone');

if (!kt_valid_udid($udid)) {
    header('Location: ' . kt_base_url() . '/register.html?error=udid', true, 301);
    exit;
}

$db = kt_load();
$entry = $db['devices'][$udid] ?? null;
$recent = $entry && in_array($entry['state'], ['requested'], true) && time() - $entry['requested'] < 1800;
if (!$entry || ($entry['state'] !== 'ready' && !$recent)) {
    $name = 'K-TUBE ' . preg_replace('/[^A-Za-z0-9,._ -]/', '', $product) . ' ' . substr($udid, -6);
    [$code] = kt_github('POST', '/actions/workflows/' . KT_WORKFLOW . '/dispatches',
        ['ref' => 'main', 'inputs' => ['udid' => $udid, 'name' => $name]]);
    $db['devices'][$udid] = [
        'state' => $code === 204 ? 'requested' : 'error',
        'product' => $product,
        'requested' => time(),
        'dispatch' => $code,
    ];
    kt_save($db);
}
header('Location: ' . kt_base_url() . '/register.html?udid=' . rawurlencode($udid), true, 301);
