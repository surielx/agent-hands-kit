# job-status.ps1 - check a background job started by job-start.ps1.
# Usage: powershell -File tools\job-status.ps1 [-Id <job id>]   (no -Id: list recent jobs)
# Final line: JOB_RUNNING id=<id> | JOB_DONE id=<id> exit=<n> | JOB_LISTED count=<n> | JOB_FAILED <reason>
param([string]$Id = '')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$jobsRoot = "$env:AGENT_HOME\jobs"
if (-not (Test-Path $jobsRoot)) { Write-Output 'JOB_FAILED no jobs directory yet'; exit 1 }
if (-not $Id) {
    $dirs = Get-ChildItem $jobsRoot -Directory | Sort-Object Name -Descending | Select-Object -First 10
    foreach ($d in $dirs) {
        $done = Test-Path (Join-Path $d.FullName 'exit.txt')
        $state = if ($done) { 'done exit=' + ([IO.File]::ReadAllText((Join-Path $d.FullName 'exit.txt'))).Trim() } else { 'running?' }
        Write-Output ($d.Name + ' ' + $state)
    }
    Write-Output ("JOB_LISTED count=" + $dirs.Count)
    exit 0
}
$jobDir = Join-Path $jobsRoot $Id
if (-not (Test-Path $jobDir)) { Write-Output ("JOB_FAILED unknown id: " + $Id); exit 1 }
$exitPath = Join-Path $jobDir 'exit.txt'
if (Test-Path $exitPath) {
    Write-Output ("JOB_DONE id=" + $Id + " exit=" + ([IO.File]::ReadAllText($exitPath)).Trim())
    exit 0
}
$pidPath = Join-Path $jobDir 'pid.txt'
$alive = $false
if (Test-Path $pidPath) {
    $jobPid = [int]([IO.File]::ReadAllText($pidPath)).Trim()
    if (Get-Process -Id $jobPid -ErrorAction SilentlyContinue) { $alive = $true }
}
if ($alive) { Write-Output ("JOB_RUNNING id=" + $Id) }
else { Write-Output ("JOB_DONE id=" + $Id + " exit=unknown (process gone, no exit file)") }
