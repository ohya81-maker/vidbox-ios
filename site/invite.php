<?php
// TestFlight 자동 초대: 초대 코드 + Apple ID 이메일 → App Store Connect 팀 초대(최소 권한, 이 앱만)
// 초대를 수락하면 내부 테스트 그룹에 넣어 TestFlight 설치 초대가 가게 한다. 심사 없음, 개발자 모드 불필요.
require __DIR__ . '/lib.php';

if ($_SERVER['REQUEST_METHOD'] !== 'POST') kt_json(['state' => 'error', 'detail' => 'POST only']);
$in = json_decode(file_get_contents('php://input') ?: '[]', true) ?: [];
$in += $_POST;
$action = (string)($in['action'] ?? '');
$code = trim((string)($in['code'] ?? ''));
$email = strtolower(trim((string)($in['email'] ?? '')));
$first = mb_substr(trim((string)($in['first'] ?? '')) ?: 'K-TUBE', 0, 30);
$last = mb_substr(trim((string)($in['last'] ?? '')) ?: '사용자', 0, 30);

$secret = @include KT_PRIVATE . '/invite.php';
if (!is_string($secret) || $secret === '' || !hash_equals(strtoupper($secret), strtoupper($code))) {
    usleep(800000);
    kt_json(['state' => 'badcode']);
}

// 남용 방지: 1시간에 40번까지
$log = @include KT_TESTERS;
if (!is_array($log)) $log = ['hits' => []];
$log['hits'] = array_values(array_filter($log['hits'], fn($t) => $t > time() - 3600));
if (count($log['hits']) >= 40) kt_json(['state' => 'busy']);
$log['hits'][] = time();
file_put_contents(KT_TESTERS, '<?php return ' . var_export($log, true) . ';');

function find_user(string $email): ?array {
    [$c, $js] = kt_asc('GET', '/users?limit=5&filter[username]=' . rawurlencode($email));
    foreach (($js['data'] ?? []) as $u) if (strtolower($u['attributes']['username'] ?? '') === $email) return $u;
    return null;
}

function find_invite(string $email): ?array {
    [$c, $js] = kt_asc('GET', '/userInvitations?limit=5&filter[email]=' . rawurlencode($email));
    foreach (($js['data'] ?? []) as $u) if (strtolower($u['attributes']['email'] ?? '') === $email) return $u;
    return null;
}

function internal_group(): string {
    [$c, $js] = kt_asc('GET', '/apps/' . KT_APP_ID . '/betaGroups?limit=50');
    foreach (($js['data'] ?? []) as $g) if (!empty($g['attributes']['isInternalGroup'])) return $g['id'];
    [$c, $js] = kt_asc('POST', '/betaGroups', ['data' => [
        'type' => 'betaGroups',
        'attributes' => ['name' => KT_GROUP_NAME, 'isInternalGroup' => true, 'hasAccessToAllBuilds' => true],
        'relationships' => ['app' => ['data' => ['type' => 'apps', 'id' => KT_APP_ID]]],
    ]]);
    if ($c >= 300) throw new RuntimeException('group: ' . kt_asc_error($js));
    return $js['data']['id'];
}

// 팀원이 된 사람을 내부 테스트 그룹에 넣는다 (그러면 TestFlight 초대 메일이 간다)
function add_tester(string $email, string $first, string $last): void {
    $gid = internal_group();
    [$c, $js] = kt_asc('GET', '/betaTesters?limit=5&filter[email]=' . rawurlencode($email));
    $tester = null;
    foreach (($js['data'] ?? []) as $t) if (strtolower($t['attributes']['email'] ?? '') === $email) $tester = $t;
    if ($tester) {
        [$c, $js] = kt_asc('POST', '/betaGroups/' . $gid . '/relationships/betaTesters',
                           ['data' => [['type' => 'betaTesters', 'id' => $tester['id']]]]);
        if ($c >= 300 && $c != 409) throw new RuntimeException('add: ' . kt_asc_error($js));
        return;
    }
    [$c, $js] = kt_asc('POST', '/betaTesters', ['data' => [
        'type' => 'betaTesters',
        'attributes' => ['email' => $email, 'firstName' => $first, 'lastName' => $last],
        'relationships' => ['betaGroups' => ['data' => [['type' => 'betaGroups', 'id' => $gid]]]],
    ]]);
    if ($c >= 300 && $c != 409) throw new RuntimeException('tester: ' . kt_asc_error($js));
}

try {
    if ($action === 'ping') {
        [$c, $js] = kt_asc('GET', '/apps/' . KT_APP_ID);
        kt_json(['state' => $c == 200 ? 'ok' : 'error', 'app' => $js['data']['attributes']['name'] ?? kt_asc_error($js)]);
    }
    if (!filter_var($email, FILTER_VALIDATE_EMAIL)) kt_json(['state' => 'bademail']);
    if (find_user($email)) {
        add_tester($email, $first, $last);
        kt_json(['state' => 'tester']);
    }
    $inv = find_invite($email);
    // 메일이 안 왔을 때: 기존 초대를 지우고 새로 보낸다 (Apple이 메일을 다시 보냄)
    if ($inv && $action === 'resend') {
        [$c, $js] = kt_asc('DELETE', '/userInvitations/' . $inv['id']);
        if ($c >= 300 && $c != 404) kt_json(['state' => 'error', 'detail' => kt_asc_error($js)]);
        $inv = null;
    }
    if ($inv) kt_json(['state' => 'invited', 'email' => $email, 'expires' => $inv['attributes']['expirationDate'] ?? null]);
    if ($action === 'check') kt_json(['state' => 'none']);

    [$c, $js] = kt_asc('POST', '/userInvitations', ['data' => [
        'type' => 'userInvitations',
        'attributes' => ['email' => $email, 'firstName' => $first, 'lastName' => $last,
                         'roles' => ['CUSTOMER_SUPPORT'], 'allAppsVisible' => false, 'provisioningAllowed' => false],
        'relationships' => ['visibleApps' => ['data' => [['type' => 'apps', 'id' => KT_APP_ID]]]],
    ]]);
    if ($c >= 300) kt_json(['state' => 'error', 'detail' => kt_asc_error($js)]);
    kt_json(['state' => 'invited', 'email' => $email, 'sent' => true]);
} catch (Throwable $e) {
    kt_json(['state' => 'error', 'detail' => $e->getMessage()]);
}
