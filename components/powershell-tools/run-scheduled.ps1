# run-scheduled.ps1 - runner for the resident AI's self-scheduled tasks (called by Windows Task Scheduler).
# Reads friend\scheduled\<Id>.md, runs it as an opencode task from the friend home, logs the result.
# Invocation mirrors wake.ps1: Start-Process, stdin from an empty file, her global opencode config
# (local model pinned there, cloud providers disabled there). No explicit model/config overrides.
param([Parameter(Mandatory = $true)][string]$Id)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$friendDir = "$env:AGENT_HOME"
$mdPath = Join-Path $friendDir ('scheduled\' + $Id + '.md')
$logDir = Join-Path $friendDir 'scheduled\logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $logDir ($Id + '-' + $stamp + '.log')
function Log([string]$s) { Add-Content -LiteralPath $log -Value $s -Encoding UTF8 }

if (-not (Test-Path $mdPath)) { Log "instruction file missing: $mdPath"; exit 1 }
$body = [IO.File]::ReadAllText($mdPath, [Text.Encoding]::UTF8)
Log ("START " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

# Mutual exclusion on the single inference server: wait for the lock, or skip
# this firing entirely (a skipped one-shot is NOT disabled; it fires again on
# the next trigger or can be run manually).
$lockTool = "$env:AGENT_HOME\tools\strata-lock.ps1"
$lockToken = $null
if (Test-Path $lockTool) {
    $lk = & powershell -NoProfile -ExecutionPolicy Bypass -File $lockTool -Acquire -Owner ('scheduled-' + $Id) -WaitMinutes 20 -HoldMinutes 150 -HolderPid $PID 2>$null | Out-String
    if ($lk -match 'token=([0-9a-f]+)') { $lockToken = $Matches[1] }
    else { Log ('SKIPPED: inference server busy (' + $lk.Trim() + ')'); exit 0 }
}
function Release-Lock {
    if ($lockToken) {
        try { & powershell -NoProfile -ExecutionPolicy Bypass -File $lockTool -Release -Token $lockToken 2>$null | Out-Null } catch {}
    }
}

$oc = "$env:USERPROFILE\tools\opencode\opencode.exe"
$emptyIn = Join-Path $logDir 'stdin-empty.txt'
if (-not (Test-Path $emptyIn)) { [IO.File]::WriteAllText($emptyIn, '', (New-Object System.Text.UTF8Encoding($false))) }
$outFile = Join-Path $logDir ($Id + '-' + $stamp + '.out.log')
$errFile = Join-Path $logDir ($Id + '-' + $stamp + '.err.log')
$msg = "This is a task you scheduled for yourself earlier. The instruction file is scheduled\$Id.md - read it completely and carry it out. Work from your home folder as usual. If the instruction is a one-time reminder to check something, do the check and write the result into scheduled\logs\$Id-result.md."
$argStr = 'run --auto "' + ($msg -replace '"', '\"') + '"'
# Autonomous-run guard: deny catastrophic shell commands for unattended runs.
$env:OPENCODE_CONFIG = "$env:AGENT_HOME\autonomous-config.json"
$p = Start-Process -FilePath $oc -ArgumentList $argStr -WorkingDirectory $friendDir -PassThru -WindowStyle Hidden -RedirectStandardInput $emptyIn -RedirectStandardOutput $outFile -RedirectStandardError $errFile
if (-not $p.WaitForExit(2 * 60 * 60 * 1000)) {
    try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
    try { & taskkill /F /T /PID $p.Id 2>$null | Out-Null } catch {}
    Log 'TIMEOUT after 2h'
    Release-Lock
    exit 2
}
Log ("opencode exit: " + $p.ExitCode + ' (output: ' + $outFile + ')')
if ($p.ExitCode -ne 0) { Log ("stderr: " + $errFile) }

# one-shot tasks disable themselves afterwards
if ($body -match 'RepeatHours:\s*0') {
    Disable-ScheduledTask -TaskName ('AgentSelf-' + $Id) -ErrorAction SilentlyContinue | Out-Null
    Log 'one-shot: task disabled'
}
Release-Lock
Log ("END " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
