<?php
// 앱이 재생에 실패했을 때 보내는 짧은 진단 기록 (원인 파악용). .private/diag.log 에 쌓는다 (최근 200KB)
require __DIR__ . '/lib.php';
if ($_SERVER['REQUEST_METHOD'] !== 'POST') { http_response_code(405); exit; }
$raw = file_get_contents('php://input', false, null, 0, 20000);
$j = json_decode($raw ?: 'null', true);
if (!is_array($j)) { http_response_code(400); exit; }
$line = date('c') . ' ' . json_encode($j, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES) . "\n";
$f = KT_PRIVATE . '/diag.log.php';   // PHP 파일이라 웹에서 내용이 보이지 않는다
if (!file_exists($f)) file_put_contents($f, "<?php exit; ?>
");
if (@filesize($f) > 200000) { $old = file_get_contents($f); file_put_contents($f, "<?php exit; ?>
" . substr($old, -100000)); }
file_put_contents($f, $line, FILE_APPEND | LOCK_EX);
http_response_code(204);
