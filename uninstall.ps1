# WEBHOST uninstaller for Windows.
#   irm https://brizzad.github.io/webhost-site/uninstall.ps1 | iex
# Removes the background service, its firewall rule and the program files.
# It asks whether to keep this computer's ID and owner account (kept, a later
# install reuses them) or delete them. It asks for administrator rights once.
#
# Unattended: RC_PURGE=1 deletes the ID and account, RC_PURGE=0 keeps them.
$ErrorActionPreference = 'Stop'

function Say($m) { Write-Host "==> $m" -ForegroundColor Cyan }
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

$userDir = Join-Path $env:LOCALAPPDATA 'WEBHOST'
$configDir = Join-Path $env:APPDATA 'WEBHOST'
$programDir = Join-Path $env:ProgramFiles 'WEBHOST'
$dataDir = Join-Path $env:ProgramData 'WEBHOST'

if ($env:RC_PURGE) {
  $purge = $env:RC_PURGE -eq '1'
} elseif (Test-Path (Join-Path $configDir 'agent.json')) {
  Write-Host 'Keep this computer''s ID and owner account, so a later install can reuse them?'
  $answer = Read-Host 'Keep them? [Y/n]'
  $purge = $answer -match '^\s*n'
} else {
  $purge = $false
}

# Elevated PowerShell that deletes the program and service data folders,
# retrying while helpers in the signed-in session exit after the service.
$removeDirs = @'
foreach ($d in @(__DIRS__)) {
  for ($i = 0; $i -lt 10 -and (Test-Path $d); $i++) {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $d
    if (Test-Path $d) { Start-Sleep 1 }
  }
  if (Test-Path $d) { "could not remove $d" } else { "removed $d" }
}
'@
$removeDirs = $removeDirs.Replace('__DIRS__', "$(Quote $programDir), $(Quote $dataDir)")
$log = Join-Path ([IO.Path]::GetTempPath()) "webhost-uninstall-$PID.log"

Say 'Removing the background service (Windows asks for administrator rights)'
# The service is removed by webhost itself, preferably the installed copy
# (only administrators can change that one).
$source = @((Join-Path $programDir 'webhost.exe'), (Join-Path $userDir 'webhost.exe')) | Where-Object { Test-Path $_ } | Select-Object -First 1
try {
  if ($source) {
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash.ToLowerInvariant()
    [void](Invoke-AsAdmin $source $hash 'service uninstall --purge' $log $removeDirs)
  } else {
    # No program left to ask: remove the service and its firewall rule directly.
    $body = @'
& {
  sc.exe stop WEBHOST | Out-Null
  Start-Sleep 2
  sc.exe delete WEBHOST
  netsh advfirewall firewall delete rule name='WEBHOST Agent' | Out-Null
  __REMOVE__
} *>&1 | Set-Content -Encoding UTF8 -LiteralPath __LOG__
'@
    $body = $body.Replace('__REMOVE__', $removeDirs).Replace('__LOG__', (Quote $log))
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
    Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) -Verb RunAs -WindowStyle Hidden -Wait | Out-Null
    if (Test-Path $log) { Get-Content $log | ForEach-Object { Write-Host "    $_" }; Remove-Item -ErrorAction SilentlyContinue $log }
  }
} catch {
  throw "Nothing was removed: administrator rights were not granted ($($_.Exception.Message))."
}

Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $userDir
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -and ((($userPath -split ';') -contains $userDir) -or (($userPath -split ';') -contains $programDir))) {
  [Environment]::SetEnvironmentVariable('Path', (($userPath -split ';') | Where-Object { $_ -and $_ -ne $userDir -and $_ -ne $programDir }) -join ';', 'User')
}
if ($purge) {
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $configDir
  Say 'Deleted this computer''s ID and owner account.'
} elseif (Test-Path $configDir) {
  Say "Kept this computer's ID and owner account in $configDir (delete that folder to remove them)."
}

$left = @($programDir, $dataDir, $userDir) | Where-Object { Test-Path $_ }
# A deleted service disappears once nothing has it open any more.
for ($i = 0; $i -lt 20 -and (Get-Service -Name WEBHOST -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 500 }
if (Get-Service -Name WEBHOST -ErrorAction SilentlyContinue) { $left += 'the WEBHOST service' }
if ($left) { throw "WEBHOST was not completely removed; still present: $($left -join ', ')" }
Write-Host 'WEBHOST is uninstalled.' -ForegroundColor Green
