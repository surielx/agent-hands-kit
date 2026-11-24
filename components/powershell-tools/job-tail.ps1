# job-tail.ps1 - show the tail of a background job's output log.
# Usage: powershell -File tools\job-tail.ps1 -Id <job id> [-Lines 30]
# Final line: JOB_TAIL id=<id> shown=<n> | JOB_FAILED <reason>
param([Parameter(Mandatory = $true)][string]$Id, [int]$Lines = 30)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$outLog = Join-Path (Join-Path "$env:AGENT_HOME\jobs" $Id) 'out.log'
if (-not (Test-Path $outLog)) { Write-Output ("JOB_FAILED no log for id: " + $Id); exit 1 }
$all = [IO.File]::ReadAllLines($outLog, [Text.Encoding]::UTF8)
$take = [Math]::Min($Lines, $all.Count)
if ($take -gt 0) { Write-Output ($all[($all.Count - $take)..($all.Count - 1)] -join "`n") }
Write-Output ("JOB_TAIL id=" + $Id + " shown=" + $take + " total=" + $all.Count)
