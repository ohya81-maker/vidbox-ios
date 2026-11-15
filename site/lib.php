<?php
// K-TUBE 기기 등록 공통 함수
// 비밀 설정은 .private/config.php (저장소에 없음, 시놀로지에만):
//   <?php return ['github_token' => 'github_pat_...', 'repo' => 'ohya81-maker/vidbox-ios'];
if (basename($_SERVER['SCRIPT_FILENAME'] ?? '') === 'lib.php') { http_response_code(404); exit; }

const KT_PRIVATE = __DIR__ . '/.private';
const KT_DB = KT_PRIVATE . '/devices.php';
const KT_WORKFLOW = 'register-device.yml';

function kt_config(): array {
    static $c = null;
    if ($c === null) {
        $c = @include KT_PRIVATE . '/config.php';
        if (!is_array($c)) $c = [];
        $c += ['repo' => 'ohya81-maker/vidbox-ios', 'github_token' => ''];
    }
    return $c;
}

function kt_base_url(): string {
    return 'https://' . ($_SERVER['HTTP_HOST'] ?? 'mistylake.synology.me') . rtrim(dirname($_SERVER['SCRIPT_NAME']), '/');
}

function kt_valid_udid(string $u): bool {
    return (bool)preg_match('/^([0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9a-fA-F]{40})$/', $u);
}

// 웹에서 바로 읽히지 않도록 PHP 파일 안에 JSON을 넣어 둔다
function kt_load(): array {
    $raw = @file_get_contents(KT_DB);
    if ($raw === false) return ['devices' => [], 'pulled' => ''];
    $json = substr($raw, strpos($raw, "\n") + 1);
    $db = json_decode($json, true);
    return is_array($db) ? $db + ['devices' => [], 'pulled' => ''] : ['devices' => [], 'pulled' => ''];
}

function kt_save(array $db): void {
    if (!is_dir(KT_PRIVATE)) @mkdir(KT_PRIVATE, 0770, true);
    file_put_contents(KT_DB . '.tmp', "<?php exit; ?>\n" . json_encode($db, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));
    rename(KT_DB . '.tmp', KT_DB);
}

function kt_github(string $method, string $path, $body = null): array {
    $cfg = kt_config();
    $url = str_starts_with($path, 'http') ? $path : 'https://api.github.com/repos/' . $cfg['repo'] . $path;
    $ch = curl_init($url);
    $headers = ['Accept: application/vnd.github+json', 'User-Agent: ktube-nas', 'X-GitHub-Api-Version: 2022-11-28'];
    if ($cfg['github_token'] !== '') $headers[] = 'Authorization: Bearer ' . $cfg['github_token'];
    curl_setopt_array($ch, [
        CURLOPT_CUSTOMREQUEST => $method,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT => 20,
        CURLOPT_HTTPHEADER => array_merge($headers, $body !== null ? ['Content-Type: application/json'] : []),
    ]);
    if ($body !== null) curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($body));
    $resp = curl_exec($ch);
    $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    return [$code, $resp ? json_decode($resp, true) : null];
}

function kt_json($data): void {
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store');
    echo json_encode($data, JSON_UNESCAPED_UNICODE);
    exit;
}
