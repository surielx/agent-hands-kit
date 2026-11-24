# delegate.ps1 - delegate a bounded sub-task to a fresh session of the resident AI and always get a report back.
# The pattern mirrors the outer harness: fixed premises in a scaffold folder, work confined to that
# folder, and a closing report (REPORT.md) that is enforced, not requested.
# Invocation mirrors wake.ps1 (the proven pattern for her own tasks): Start-Process with stdin
# redirected from an empty file, her global opencode config (which pins the local model and disables
# cloud providers). Do NOT run this as SYSTEM - the global config lives in her user profile.
# Usage: powershell -ExecutionPolicy Bypass -File tools\delegate.ps1 -Slug <name> -TaskFile <file> [-Task <text>] [-Minutes 60]
#   -TaskFile is preferred: write the task text to a file first (UTF-8), then point here.
# Final line: DELEGATE_DONE <workdir> | DELEGATE_FAILED <reason>
# The full REPORT.md is printed above the final line.
param(
    [Parameter(Mandatory = $true)][string]$Slug,
    [string]$TaskFile,
    [string]$Task,
    [int]$Minutes = 60,
    [string]$Model = 'local/your-model-id',
    [switch]$ReadOnly
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$utf8 = New-Object System.Text.UTF8Encoding($false)
$script:lockToken = $null
$lockTool = "$env:AGENT_HOME\tools\strata-lock.ps1"
function Release-Lock {
    if ($script:lockToken) {
        try { & powershell -NoProfile -ExecutionPolicy Bypass -File $lockTool -Release -Token $script:lockToken 2>$null | Out-Null } catch {}
        $script:lockToken = $null
    }
}
function Fail([string]$r) { Release-Lock; Write-Output "DELEGATE_FAILED $r"; exit 1 }

if ($Slug -notmatch '^[a-z0-9][a-z0-9\-]*$') { Fail 'slug must be lowercase letters, digits, hyphens' }
$friendDir = "$env:AGENT_HOME"
$workDir = Join-Path $friendDir ('work\' + $Slug)
$doneMark = Join-Path $workDir 'delegate-done.json'
if (Test-Path $doneMark) { Fail "slug already completed: $Slug (pick a new slug, or delete delegate-done.json to rerun)" }

$taskText = $null
if ($TaskFile) {
    try { $taskText = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $TaskFile).Path, [Text.Encoding]::UTF8) }
    catch { Fail "task file not found: $TaskFile" }
} elseif ($Task) { $taskText = $Task } else { Fail 'give -TaskFile or -Task' }
if ($taskText.Trim().Length -lt 10) { Fail 'task text too short' }

# Preflight: the local model server must be up (fail clearly instead of cryptically).
try {
    $h = Invoke-WebRequest -Uri 'http://127.0.0.1:8080/health' -TimeoutSec 10 -UseBasicParsing
    if ($h.StatusCode -ne 200) { Fail 'local model server health check did not return 200' }
} catch { Fail ('local model server is not reachable: ' + $_.Exception.Message) }

# Mutual exclusion: one inference session at a time on the single GPU server.
if (Test-Path $lockTool) {
    $lk = & powershell -NoProfile -ExecutionPolicy Bypass -File $lockTool -Acquire -Owner ('delegate-' + $Slug) -WaitMinutes 30 -HoldMinutes ($Minutes + 45) -HolderPid $PID 2>$null | Out-String
    if ($lk -match 'token=([0-9a-f]+)') { $script:lockToken = $Matches[1] }
    elseif ($lk -match 'LOCK_BUSY owner=(\S+)') { Fail ('server busy: the inference lock is held by ' + $Matches[1] + '; try again later') }
    else { Fail ('could not acquire the inference lock: ' + $lk.Trim()) }
}

New-Item -ItemType Directory -Force -Path $workDir | Out-Null

# --- scaffold: fixed premises + report skeleton ---
$taskMd = @"
# Delegated task: $Slug
Created: $(Get-Date -Format 'yyyy-MM-dd HH:mm')

## Premises (fixed)
- Work only inside this folder: $workDir
- The task below is the whole assignment. Do not expand its scope.
- When finished (or when you judge you cannot proceed), write REPORT.md in this folder
  following its skeleton, in Japanese, honestly including failures.
- Keep REPORT.md under about 1200 characters in total. The Conclusion section comes
  first and must state the outcome in 1-3 lines; details follow in the other sections.
- If a step fails twice, write what failed into REPORT.md and finish.

## Task
$($taskText.Trim())
"@
[IO.File]::WriteAllText((Join-Path $workDir 'task.md'), $taskMd, $utf8)
if ($ReadOnly) {
    Add-Content -LiteralPath (Join-Path $workDir 'task.md') -Value "`n- READ-ONLY delegation: writes are restricted to this folder by configuration. Put all findings in REPORT.md." -Encoding UTF8
}

$reportPath = Join-Path $workDir 'REPORT.md'
$skeleton = @"
# Report: $Slug

## Conclusion

## What was made / changed

## How it was verified

## Open items / failures
"@
if (-not (Test-Path $reportPath)) { [IO.File]::WriteAllText($reportPath, $skeleton, $utf8) }
$skeletonLen = $skeleton.Length

$oc = "$env:USERPROFILE\tools\opencode\opencode.exe"
if (-not (Test-Path $oc)) { Fail 'opencode.exe not found' }
$modelId = 'strata/' + ($Model -replace '^strata/', '')
$emptyIn = Join-Path $workDir 'stdin-empty.txt'
if (-not (Test-Path $emptyIn)) { [IO.File]::WriteAllText($emptyIn, '', $utf8) }

function Invoke-OpenCode([string]$msg, [int]$timeoutSec, [string]$logName) {
    $outFile = Join-Path $workDir ($logName + '.out.log')
    $errFile = Join-Path $workDir ($logName + '.err.log')
    # Launch via ProcessStartInfo (UseShellExecute=false), the same pattern the
    # harness uses: Start-Process in this S4U context returned a process whose
    # ExitCode stayed null after exit, so completed runs were misjudged as
    # failures. With ProcessStartInfo the exit code is reliable.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $oc
    $psi.Arguments = 'run --auto --model ' + $modelId + ' "' + ($msg -replace '"', '\"') + '"'
    $psi.WorkingDirectory = $friendDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    try { $p.StandardInput.Close() } catch {}
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        try { & taskkill /F /T /PID $p.Id 2>$null | Out-Null } catch {}
        try { $p.WaitForExit(5000) | Out-Null } catch {}
        return @{ ok = $false; why = "timeout ${timeoutSec}s" }
    }
    $p.WaitForExit()
    $outText = ''; $errText = ''
    try { $outText = $outTask.Result } catch {}
    try { $errText = $errTask.Result } catch {}
    [IO.File]::WriteAllText($outFile, [string]$outText, $utf8)
    [IO.File]::WriteAllText($errFile, [string]$errText, $utf8)
    if ($p.ExitCode -ne 0) {
        $errTail = ''
        if ($errText -and $errText.Length -gt 0) { $errTail = $errText.Substring([Math]::Max(0, $errText.Length - 300)) }
        return @{ ok = $false; why = "exit $($p.ExitCode): $errTail" }
    }
    return @{ ok = $true }
}

# Autonomous-run guard: deny catastrophic shell commands for unattended runs.
$env:OPENCODE_CONFIG = "$env:AGENT_HOME\autonomous-config.json"
if ($ReadOnly) {
    # Read-only delegation (research / investigation): the child may look but
    # not modify anything outside its own report. Combine the autonomous guard
    # with edit/write denies into one overlay config.
    $roCfg = [IO.File]::ReadAllText("$env:AGENT_HOME\autonomous-config.json", [Text.Encoding]::UTF8) | ConvertFrom-Json
    $rel = "work/$Slug/**"
    $rel2 = "**/work/$Slug/**"
    $roPerm = [ordered]@{ '*' = 'deny'; $rel = 'allow'; $rel2 = 'allow' }
    $roCfg.permission | Add-Member -NotePropertyName edit -NotePropertyValue $roPerm -Force
    $roCfg.permission | Add-Member -NotePropertyName write -NotePropertyValue $roPerm -Force
    $roPath = Join-Path $workDir 'delegate-config.json'
    $roCfg | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $roPath -Encoding UTF8
    $env:OPENCODE_CONFIG = $roPath
}
$prompt1 = "You have a delegated task. Read the file work\$Slug\task.md completely, then do exactly that task. Work only inside work\$Slug. When done, fill in work\$Slug\REPORT.md following its skeleton."
$r1 = Invoke-OpenCode $prompt1 ($Minutes * 60) 'delegate-run1'
if (-not $r1.ok) { Fail ("run1 failed: " + $r1.why) }

# --- enforced report phase ---
$reportLen = 0
if (Test-Path $reportPath) { $reportLen = ([IO.File]::ReadAllText($reportPath, [Text.Encoding]::UTF8)).Length }
if ($reportLen -lt ($skeletonLen + 40)) {
    $files = (Get-ChildItem $workDir -File | ForEach-Object { $_.Name }) -join ', '
    $prompt2 = "Closing step for the delegated task in work\$Slug. Files currently in the folder: $files. Read task.md and whatever outputs exist, then write the final REPORT.md in that folder following its skeleton (Conclusion first, then What was made / How it was verified / Open items), in Japanese, honestly, under about 1200 characters in total. Do not start new work in this step."
    $r2 = Invoke-OpenCode $prompt2 900 'delegate-run2'
    if (-not $r2.ok) { Fail ("report phase failed: " + $r2.why) }
    if (Test-Path $reportPath) { $reportLen = ([IO.File]::ReadAllText($reportPath, [Text.Encoding]::UTF8)).Length }
    if ($reportLen -lt ($skeletonLen + 40)) { Fail 'REPORT.md still empty after the report phase' }
}

Remove-Item Env:OPENCODE_CONFIG -ErrorAction SilentlyContinue
$done = @{ slug = $Slug; finished = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); reportChars = $reportLen } | ConvertTo-Json
[IO.File]::WriteAllText($doneMark, $done, $utf8)
$reportOut = [IO.File]::ReadAllText($reportPath, [Text.Encoding]::UTF8)
Release-Lock
Write-Output $reportOut
Write-Output "DELEGATE_DONE $workDir"
