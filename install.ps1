# WEBHOST installer for Windows.
#   irm https://brizzad.github.io/webhost-site/install.ps1 | iex
# Run it in a normal PowerShell window. It asks for administrator rights once,
# to install the background service (so WEBHOST runs at startup, even
# before anyone signs in). Running it again updates the agent and keeps this
# computer's ID and owner account.
#
# Unattended (scripts, tests): set RC_USERNAME, RC_PASSWORD and RC_TOTP_SECRET
# (base32) to set up without questions. RC_DOWNLOAD_ONLY=1 only downloads and
# verifies. RC_RELEASE_URL overrides where the release is downloaded from.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Repo = if ($env:RC_RELEASE_URL) { $env:RC_RELEASE_URL } else { 'https://github.com/brizzad/webhost-site/releases/latest/download' }
$Site = 'https://brizzad.github.io/webhost-site/'
$App = "${Site}app/"
$Asset = 'webhost-windows-x86_64.exe'

function Say($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Fail($m) { throw $m }
# A PowerShell string literal for $s.
function Quote($s) { "'" + ($s -replace "'", "''") + "'" }

# Runs `webhost <arguments>` as administrator (one UAC prompt) and returns its
# exit code, showing its output (the elevated window closes when done, so the
# output goes through $log). The elevated side copies the program into a new
# folder only administrators can write, checks it is the file verified here
# ($hash), and runs that copy: nothing running as this user can swap it in
# between. $extra is more elevated PowerShell to run afterwards.
function Invoke-AsAdmin($source, $hash, $arguments, $log, $extra = '') {
  $body = @'
$global:code = 1
$dir = Join-Path $env:ProgramData ('WEBHOST-run-' + [guid]::NewGuid().ToString('N'))
& {
  try {
    New-Item -ItemType Directory -Path $dir -ErrorAction Stop | Out-Null
    & icacls.exe $dir /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "could not make $dir private" }
    $exe = Join-Path $dir 'webhost.exe'
    Copy-Item -LiteralPath __SOURCE__ -Destination $exe -ErrorAction Stop
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash.ToLowerInvariant() -ne __HASH__) {
      throw 'webhost.exe changed on disk before it could run as administrator; not running it'
    }
    & $exe __ARGS__ 2>&1 | ForEach-Object { "$_" }
    $global:code = $LASTEXITCODE
    __EXTRA__
  } catch {
    "error: $($_.Exception.Message)"
  } finally {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $dir
  }
} *>&1 | Set-Content -Encoding UTF8 -LiteralPath __LOG__
exit $global:code
'@
  $body = $body.Replace('__SOURCE__', (Quote $source)).Replace('__HASH__', (Quote $hash)).Replace('__ARGS__', $arguments).Replace('__EXTRA__', $extra).Replace('__LOG__', (Quote $log))
  Remove-Item -ErrorAction SilentlyContinue $log
  $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
  $p = Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) -Verb RunAs -WindowStyle Hidden -Wait -PassThru
  if (Test-Path $log) { Get-Content $log | ForEach-Object { Write-Host "    $_" }; Remove-Item -ErrorAction SilentlyContinue $log }
  $p.ExitCode
}

if (-not [Environment]::Is64BitOperatingSystem) { Fail 'WEBHOST needs 64-bit Windows.' }
if ([Environment]::OSVersion.Version.Major -lt 10) { Fail 'WEBHOST needs Windows 10 or 11.' }

$dir = Join-Path $env:LOCALAPPDATA 'WEBHOST'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$exe = Join-Path $dir 'webhost.exe'
$download = Join-Path $dir "$Asset.download"

Say 'Downloading WEBHOST'
try {
  $sums = (Invoke-WebRequest -UseBasicParsing -Uri "$Repo/SHA256SUMS").Content
} catch {
  Fail "Could not download the release checksums from $Repo. Check your internet connection; if it works, there may be no release published yet. ($($_.Exception.Message))"
}
if ($sums -is [byte[]]) { $sums = [Text.Encoding]::ASCII.GetString($sums) }
try {
  Invoke-WebRequest -UseBasicParsing -Uri "$Repo/$Asset" -OutFile $download
} catch {
  Fail "Could not download WEBHOST from $Repo ($($_.Exception.Message))"
}
$line = ($sums -split "`n") | Where-Object { $_ -match "^([0-9a-f]{64})  $([regex]::Escape($Asset))\s*$" } | Select-Object -First 1
if (-not $line) { Remove-Item $download; Fail "$Asset is not listed in the release checksums." }
$expected = ($line -split '\s+')[0]
$actual = (Get-FileHash -Algorithm SHA256 $download).Hash.ToLowerInvariant()
if ($actual -ne $expected) { Remove-Item $download; Fail "$Asset failed its checksum (expected $expected, got $actual); not installing it." }
try {
  Move-Item -Force $download $exe
} catch {
  Remove-Item -ErrorAction SilentlyContinue $download
  Fail "Could not replace $exe; it is probably running. Close any window running webhost and run this again."
}
Unblock-File $exe
$version = & $exe --version
if ($LASTEXITCODE -ne 0) { Fail "webhost.exe does not run on this computer (exit code $LASTEXITCODE)." }
Write-Host "    $version"
# Tests stop here (download and checksum only).
if ($env:RC_DOWNLOAD_ONLY) { Say "Downloaded and verified $Asset"; return }

$config = Join-Path $env:APPDATA 'WEBHOST\agent.json'
Say 'Setting up this computer'
# An existing setup is kept (webhost setup --force replaces the account).
if ($env:RC_USERNAME -and $env:RC_PASSWORD -and $env:RC_TOTP_SECRET) {
  & $exe --config $config setup --username $env:RC_USERNAME --password-env RC_PASSWORD --totp-secret $env:RC_TOTP_SECRET
} else {
  & $exe --config $config setup
}
if ($LASTEXITCODE -ne 0) { Fail 'Setup did not finish. Run the installer again to retry.' }

Say 'Installing the background service'
Write-Host '    Windows now asks for administrator rights: the service starts WEBHOST at'
Write-Host '    startup and lets you reach the sign-in screen. Nothing else needs them.'
$log = Join-Path $dir 'service-install.log'
try {
  $code = Invoke-AsAdmin $exe $expected "--config $(Quote $config) service install" $log
} catch {
  Fail "The service was not installed: administrator rights were not granted ($($_.Exception.Message)). Run the installer again and choose Yes; your setup is kept."
}
if ($code -ne 0) { Fail "Service installation failed (exit code $code); see the messages above." }

# `webhost` in new terminals is the service's copy, which updates itself
# (this download is only used to install it, and then removed).
$programDir = Join-Path $env:ProgramFiles 'WEBHOST'
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$parts = @(($userPath -split ';') | Where-Object { $_ -and $_ -ne $dir -and $_ -ne $programDir }) + $programDir
[Environment]::SetEnvironmentVariable('Path', $parts -join ';', 'User')

$status = & $exe --config $config status
$id = ($status | Select-String '^id:\s*([0-9 ]+?)\s{2}').Matches | ForEach-Object { $_.Groups[1].Value } | Select-Object -First 1
$owner = ($status | Select-String '^owner:\s*(.+)$').Matches | ForEach-Object { $_.Groups[1].Value } | Select-Object -First 1
Write-Host ''
Write-Host 'WEBHOST is installed and running.' -ForegroundColor Green
Write-Host ''
Write-Host "  Computer ID:  $id"
Write-Host "  Username:     $owner"
Write-Host "  Connect from: $App"
Write-Host ''
Write-Host '  Sign in there with this username, your password and a code from your authenticator app.'
Write-Host '  Updates:      automatic (signed; installed when nobody is connected). Nothing to do.'
Write-Host ''
Write-Host '  Check it any time:  webhost status       (in a new terminal)'
Write-Host "  Service log:        $env:ProgramData\WEBHOST\logs\agent.log (administrators)"
Write-Host "  Uninstall:          irm ${Site}uninstall.ps1 | iex"
Remove-Item -ErrorAction SilentlyContinue $exe
