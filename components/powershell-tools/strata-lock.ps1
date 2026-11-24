# strata-lock.ps1 - mutual exclusion for the single local inference server (Strata, 127.0.0.1:8080).
# Entry points that start an inference session (harness run-task, wake, delegate, run-scheduled)
# acquire this lock first so two sessions never collide on the single GPU server.
# Lock file: $env:AGENT_HOME\state\strata.lock (JSON: owner, token, pid, started, expires).
# A lock is stale when its expiry passed or its owner PID is gone; stale locks are broken automatically.
# Usage:
#   strata-lock.ps1 -Acquire -Owner <name> [-WaitMinutes 0] [-HoldMinutes 150]
#       -> LOCK_ACQUIRED token=<t> | LOCK_BUSY owner=<o> (exit 3 when busy after waiting)
#   strata-lock.ps1 -Release -Token <t>   -> LOCK_RELEASED | LOCK_NOT_OWNER | LOCK_FREE
#   strata-lock.ps1 -Status               -> LOCK_FREE | LOCK_HELD owner=<o> expires=<iso>
param(
    [switch]$Acquire,
    [switch]$Release,
    [switch]$Status,
    [string]$Owner = 'unknown',
    [string]$Token = '',
    [int]$WaitMinutes = 0,
    [int]$HoldMinutes = 150,
    [int]$HolderPid = 0
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$utf8 = New-Object System.Text.UTF8Encoding($false)
$stateDir = "$env:AGENT_HOME\state"
$lockPath = Join-Path $stateDir 'strata.lock'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

function Read-Lock {
    if (-not (Test-Path $lockPath)) { return $null }
    try {
        $raw = [IO.File]::ReadAllText($lockPath, [Text.Encoding]::UTF8)
        return ($raw | ConvertFrom-Json)
    } catch { return $null }
}
function Test-Stale($lk) {
    if ($null -eq $lk) { return $true }
    try {
        $exp = [DateTime]::Parse($lk.expires)
        if ((Get-Date) -gt $exp) { return $true }
    } catch { return $true }
    if ($lk.pid -and [int]$lk.pid -gt 0) {
        if (-not (Get-Process -Id ([int]$lk.pid) -ErrorAction SilentlyContinue)) { return $true }
    }
    return $false
}

if ($Status) {
    $lk = Read-Lock
    if (($null -eq $lk) -or (Test-Stale $lk)) { Write-Output 'LOCK_FREE'; exit 0 }
    Write-Output ("LOCK_HELD owner=" + $lk.owner + " expires=" + $lk.expires)
    exit 0
}
if ($Release) {
    $lk = Read-Lock
    if ($null -eq $lk) { Write-Output 'LOCK_FREE'; exit 0 }
    if ($lk.token -ne $Token) { Write-Output ("LOCK_NOT_OWNER owner=" + $lk.owner); exit 3 }
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    Write-Output 'LOCK_RELEASED'
    exit 0
}
if ($Acquire) {
    $myToken = [guid]::NewGuid().ToString('N')
    $deadline = (Get-Date).AddMinutes($WaitMinutes)
    while ($true) {
        $lk = Read-Lock
        if (($null -eq $lk) -or (Test-Stale $lk)) {
            $obj = @{
                owner   = $Owner
                token   = $myToken
                pid     = $(if ($HolderPid -gt 0) { $HolderPid } else { $PID })
                started = (Get-Date).ToString('s')
                expires = (Get-Date).AddMinutes($HoldMinutes).ToString('s')
            } | ConvertTo-Json
            # Write via temp + move so a concurrent reader never sees a partial file.
            $tmp = $lockPath + '.tmp-' + $myToken.Substring(0, 8)
            [IO.File]::WriteAllText($tmp, $obj, $utf8)
            Move-Item -LiteralPath $tmp -Destination $lockPath -Force
            Start-Sleep -Milliseconds 300
            $chk = Read-Lock
            if ($chk -and $chk.token -eq $myToken) {
                Write-Output ("LOCK_ACQUIRED token=" + $myToken)
                exit 0
            }
            # Lost a race; fall through and retry until the deadline.
        }
        if ((Get-Date) -ge $deadline) {
            $lk2 = Read-Lock
            $o = if ($lk2) { $lk2.owner } else { 'unknown' }
            Write-Output ("LOCK_BUSY owner=" + $o)
            exit 3
        }
        Start-Sleep -Seconds 20
    }
}
Write-Output 'LOCK_FAILED specify -Acquire, -Release or -Status'
exit 1
