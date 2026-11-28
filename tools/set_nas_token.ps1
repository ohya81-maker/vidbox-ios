# 시놀로지 등록 페이지가 GitHub 작업을 시작할 때 쓸 토큰을 NAS에 저장한다 (PowerShell용).
# 입력한 토큰은 화면에 보이지 않고 \\mistylake\docker\youtube\.private\config.php 에만 저장된다.
$dir = '\\mistylake\docker\youtube\.private'
New-Item -ItemType Directory -Force $dir | Out-Null
$secure = Read-Host 'GitHub 토큰(github_pat_...)을 붙여넣고 Enter' -AsSecureString
$token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
if ($token -notmatch '^(github_pat_|ghp_)[A-Za-z0-9_]+$') { Write-Host '토큰 형식이 아닙니다 (github_pat_ 로 시작해야 함)'; exit 1 }
$php = "<?php return ['github_token' => '$token', 'repo' => 'ohya81-maker/vidbox-ios'];`n"
[IO.File]::WriteAllText("$dir\config.php", $php, (New-Object Text.UTF8Encoding($false)))
Write-Host "저장 완료: $dir\config.php"
