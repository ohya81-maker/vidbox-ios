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

// ---- App Store Connect API (TestFlight 자동 초대) ----
// .private/asc.php: <?php return ['key_id' => '...', 'issuer' => '...', 'p8' => "-----BEGIN PRIVATE KEY-----\n..."];
// .private/invite.php: <?php return '초대코드';
const KT_APP_ID = '6835250148';           // K-TUBE Player (com.mistylake.ktube)
const KT_GROUP_NAME = 'K-TUBE 테스터';
const KT_TESTERS = KT_PRIVATE . '/testers.php';

function kt_b64url(string $s): string { return rtrim(strtr(base64_encode($s), '+/', '-_'), '='); }

function kt_asc_token(): string {
    static $tok = null;
    if ($tok !== null) return $tok;
    $k = @include KT_PRIVATE . '/asc.php';
    if (!is_array($k)) throw new RuntimeException('asc key missing');
    $now = time();
    $input = kt_b64url(json_encode(['alg' => 'ES256', 'kid' => $k['key_id'], 'typ' => 'JWT'])) . '.' .
             kt_b64url(json_encode(['iss' => $k['issuer'], 'iat' => $now, 'exp' => $now + 900, 'aud' => 'appstoreconnect-v1']));
    $pkey = openssl_pkey_get_private($k['p8']);
    if (!$pkey || !openssl_sign($input, $der, $pkey, OPENSSL_ALGO_SHA256)) throw new RuntimeException('sign failed');
    // DER SEQUENCE{INTEGER r, INTEGER s} → r||s (각 32바이트)
    $i = 2 + ((ord($der[1]) & 0x80) ? (ord($der[1]) & 0x7F) : 0);
    $raw = '';
    for ($n = 0; $n < 2; $n++) {
        $len = ord($der[$i + 1]);
        $raw .= str_pad(ltrim(substr($der, $i + 2, $len), "\x00"), 32, "\x00", STR_PAD_LEFT);
        $i += 2 + $len;
    }
    return $tok = $input . '.' . kt_b64url($raw);
}

function kt_asc(string $method, string $path, $body = null): array {
    $ch = curl_init(str_starts_with($path, 'http') ? $path : 'https://api.appstoreconnect.apple.com/v1' . $path);
    curl_setopt_array($ch, [
        CURLOPT_CUSTOMREQUEST => $method,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT => 30,
        CURLOPT_HTTPHEADER => ['Authorization: Bearer ' . kt_asc_token(), 'Content-Type: application/json'],
    ]);
    if ($body !== null) curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($body, JSON_UNESCAPED_UNICODE));
    $resp = curl_exec($ch);
    $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    return [$code, $resp ? json_decode($resp, true) : null];
}

function kt_asc_error(?array $js): string {
    $e = $js['errors'][0] ?? null;
    return $e ? trim(($e['title'] ?? '') . ' ' . ($e['detail'] ?? '')) : 'unknown';
}
