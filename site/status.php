<?php
// 등록 진행 상황 (register.html 이 몇 초마다 묻는다).
// 다시 서명이 끝나면 새 IPA를 GitHub 릴리스에서 받아 설치 파일을 바꿔 놓는다.
require __DIR__ . '/lib.php';
set_time_limit(300);

$udid = $_GET['udid'] ?? '';
if (!kt_valid_udid($udid)) kt_json(['state' => 'invalid']);
$db = kt_load();
$entry = $db['devices'][$udid] ?? null;
if (!$entry) kt_json(['state' => 'unknown']);
if ($entry['state'] === 'ready') kt_json(['state' => 'ready']);
if ($entry['state'] === 'error') kt_json(['state' => 'failed', 'detail' => 'dispatch ' . ($entry['dispatch'] ?? '')]);

// 이 요청 뒤에 시작된 작업 찾기
[$code, $runs] = kt_github('GET', '/actions/workflows/' . KT_WORKFLOW . '/runs?per_page=20');
if ($code !== 200) kt_json(['state' => 'requested']);
$run = null;
foreach (array_reverse($runs['workflow_runs'] ?? []) as $r) {
    if (strtotime($r['created_at']) >= $entry['requested'] - 30) { $run = $r; break; }
}
if (!$run) kt_json(['state' => 'requested']);
if ($run['status'] !== 'completed') kt_json(['state' => 'building', 'since' => time() - strtotime($run['created_at'])]);
if ($run['conclusion'] !== 'success') {
    $db['devices'][$udid]['state'] = 'failed';
    kt_save($db);
    kt_json(['state' => 'failed', 'detail' => $run['conclusion']]);
}

// 새로 서명된 IPA 받아 오기 (한 번에 한 요청만)
$lock = fopen(KT_PRIVATE . '/pull.lock', 'c');
if (!flock($lock, LOCK_EX | LOCK_NB)) kt_json(['state' => 'finishing']);
$db = kt_load();
[$code, $rel] = kt_github('GET', '/releases/latest');
$asset = null;
foreach ($rel['assets'] ?? [] as $a) if ($a['name'] === 'KTUBE-signed.ipa') $asset = $a;
if (!$asset) kt_json(['state' => 'finishing']);
$stamp = $asset['id'] . '@' . $asset['updated_at'];
if ($db['pulled'] !== $stamp) {
    // 설치 매니페스트가 가리키는 IPA 파일 이름
    $manifest = @file_get_contents(__DIR__ . '/manifest.xml') ?: '';
    if (!preg_match('/<string>[^<]*\/(KTUBE-[^<\/]+\.ipa)<\/string>/', $manifest, $mm)) kt_json(['state' => 'failed', 'detail' => 'manifest']);
    $target = __DIR__ . '/' . $mm[1];
    $tmp = $target . '.part';
    $fp = fopen($tmp, 'w');
    $ch = curl_init($asset['browser_download_url']);
    curl_setopt_array($ch, [CURLOPT_FILE => $fp, CURLOPT_FOLLOWLOCATION => true, CURLOPT_TIMEOUT => 280,
        CURLOPT_HTTPHEADER => ['User-Agent: ktube-nas']]);
    $ok = curl_exec($ch) && curl_getinfo($ch, CURLINFO_HTTP_CODE) === 200;
    curl_close($ch);
    fclose($fp);
    if (!$ok || filesize($tmp) < 1000000) { @unlink($tmp); kt_json(['state' => 'finishing']); }
    rename($tmp, $target);
    $db['pulled'] = $stamp;
}
// 이 작업 전에 요청한 기기들은 모두 준비 완료
foreach ($db['devices'] as $id => $d) {
    if ($d['state'] === 'requested' && $d['requested'] <= strtotime($run['created_at']) + 30) {
        $db['devices'][$id]['state'] = 'ready';
    }
}
kt_save($db);
kt_json(['state' => $db['devices'][$udid]['state'] === 'ready' ? 'ready' : 'requested']);
