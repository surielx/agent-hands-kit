# schedule-self.ps1 - The resident AI schedules its own future work (one-shot or repeating).
# Usage:
#   ...\schedule-self.ps1 -Add -Text <instruction> (-At 'yyyy-MM-dd HH:mm' | -InMinutes <n>) [-RepeatHours <n>]
#   ...\schedule-self.ps1 -List
#   ...\schedule-self.ps1 -Remove -Id <id>
# Jobs live in $env:AGENT_HOME\scheduled\<id>.md and run via the Windows task AgentSelf-<id>,
# which invokes scripts\run-scheduled.ps1 (opencode run, local model pinned). Logs: scheduled\logs\.
# Final lines: SCHEDULED <id> at=<when> | SCHEDULE_LIST <n> | SCHEDULE_REMOVED <id> | SCHEDULE_FAILED <reason>
param(
    [switch]$Add, [switch]$List, [switch]$Remove,
    [string]$Text, [string]$TextFile,
    [string]$At, [int]$InMinutes = 0, [int]$RepeatHours = 0,
    [string]$Id, [string]$Purpose = ''
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$utf8 = New-Object System.Text.UTF8Encoding($false)
function Fail([string]$r) { Write-Output "SCHEDULE_FAILED $r"; exit 1 }

$dir = "$env:AGENT_HOME\scheduled"
$logDir = Join-Path $dir 'logs'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$runner = "$env:AGENT_HOME\scripts\run-scheduled.ps1"

if ($List) {
    $jobs = Get-ChildItem $dir -Filter '*.md' -File -ErrorAction SilentlyContinue
    foreach ($j in $jobs) {
        $jid = [IO.Path]::GetFileNameWithoutExtension($j.Name)
        $t = Get-ScheduledTask -TaskName ('AgentSelf-' + $jid) -ErrorAction SilentlyContinue
        $state = if ($t) { $t.State } else { 'no-task' }
        $first = ([IO.File]::ReadAllText($j.FullName, [Text.Encoding]::UTF8) -split "`n")[0]
        $purposeLine = ([IO.File]::ReadAllText($j.FullName, [Text.Encoding]::UTF8) -split "`n" | Where-Object { $_ -like 'Purpose:*' } | Select-Object -First 1)
        if ($purposeLine) { $first = $purposeLine }
        Write-Output ("JOB {0} state={1} :: {2}" -f $jid, $state, $first)
    }
    Write-Output "SCHEDULE_LIST $(@($jobs).Count)"
    exit 0
}

if ($Remove) {
    if (-not $Id) { Fail 'give -Id' }
    Unregister-ScheduledTask -TaskName ('AgentSelf-' + $Id) -Confirm:$false -ErrorAction SilentlyContinue
    $f = Join-Path $dir ($Id + '.md')
    if (Test-Path $f) { Remove-Item $f -Force }
    Write-Output "SCHEDULE_REMOVED $Id"
    exit 0
}

if ($Add) {
    $body = $null
    if ($TextFile) {
        try { $body = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $TextFile).Path, [Text.Encoding]::UTF8) }
        catch { Fail "text file not found: $TextFile" }
    } elseif ($Text) { $body = $Text } else { Fail 'give -Text or -TextFile' }

    $when = $null
    if ($At) {
        try { $when = [datetime]::ParseExact($At, 'yyyy-MM-dd HH:mm', $null) } catch { Fail 'bad -At format, use yyyy-MM-dd HH:mm' }
    } elseif ($InMinutes -gt 0) { $when = (Get-Date).AddMinutes($InMinutes) }
    else { Fail 'give -At or -InMinutes' }
    if ($when -lt (Get-Date).AddMinutes(-1)) { Fail 'time is in the past' }

    # Runaway prevention: cap concurrent reservations.
    $existing = @(Get-ChildItem $dir -Filter '*.md' -File -ErrorAction SilentlyContinue)
    if ($existing.Count -ge 10) { Fail 'too many scheduled jobs already (max 10). List them and remove finished ones first. next: run -List, then -Remove the stale ids' }

    if (-not $Purpose) { $Purpose = ($body.Trim() -split "`n")[0] }
    $id = Get-Date -Format 'yyyyMMdd-HHmmss'
    $md = "# Scheduled task $id`nRun at: $($when.ToString('yyyy-MM-dd HH:mm'))`nRepeatHours: $RepeatHours`nPurpose: $Purpose`n`n$($body.Trim())`n"
    [IO.File]::WriteAllText((Join-Path $dir ($id + '.md')), $md, $utf8)

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ("-NoProfile -ExecutionPolicy Bypass -File `"$runner`" -Id $id")
    if ($RepeatHours -gt 0) {
        $trigger = New-ScheduledTaskTrigger -Once -At $when -RepetitionInterval (New-TimeSpan -Hours $RepeatHours)
    } else {
        $trigger = New-ScheduledTaskTrigger -Once -At $when
    }
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType S4U -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2)
    Register-ScheduledTask -TaskName ('AgentSelf-' + $id) -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Output ("SCHEDULED {0} at={1}" -f $id, $when.ToString('yyyy-MM-dd HH:mm'))
    exit 0
}

Fail 'specify -Add, -List or -Remove'
