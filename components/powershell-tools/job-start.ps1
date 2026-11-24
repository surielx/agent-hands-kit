# job-start.ps1 - start a long-running command in the background and return immediately.
# The job is launched through WMI (Win32_Process.Create) so it fully detaches from
# the caller's console/pipes; its output goes to a log you can check with
# job-status / job-tail.
# Usage: powershell -File tools\job-start.ps1 -Name <label> -File <script.ps1> [-ArgumentList '<args>']
#        powershell -File tools\job-start.ps1 -Name <label> -Command '<powershell code>'
# Final line: JOB_STARTED id=<id> pid=<n> log=<path> | JOB_FAILED <reason>
param(
    [Parameter(Mandatory = $true)][string]$Name,
    [string]$File,
    [string]$ArgumentList = '',
    [string]$Command = ''
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$utf8 = New-Object System.Text.UTF8Encoding($false)
if (-not $File -and -not $Command) { Write-Output 'JOB_FAILED give -File or -Command'; exit 1 }
$id = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + ($Name -replace '[^a-zA-Z0-9\-]', '-')
$jobDir = Join-Path "$env:AGENT_HOME\jobs" $id
New-Item -ItemType Directory -Force -Path $jobDir | Out-Null
$outLog = Join-Path $jobDir 'out.log'
$errLog = Join-Path $jobDir 'err.log'
$exitFile = Join-Path $jobDir 'exit.txt'
$pidFile = Join-Path $jobDir 'pid.txt'
$runner = Join-Path $jobDir 'runner.ps1'
if ($File) {
    $resolved = (Resolve-Path -LiteralPath $File).Path
    $inner = "& '$($resolved -replace "'", "''")' $ArgumentList"
} else {
    $inner = $Command
}
$q = "'"
$runnerText = @"
`$ErrorActionPreference = 'Continue'
if (-not `$env:AGENT_JOB_REDIR) {
    `$env:AGENT_JOB_REDIR = '1'
    `$p = Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + `$PSCommandPath + '"') -WindowStyle Hidden -PassThru -RedirectStandardOutput $($q)$($outLog)$($q) -RedirectStandardError $($q)$($errLog)$($q)
    [IO.File]::WriteAllText($($q)$($pidFile)$($q), [string]`$p.Id, (New-Object System.Text.UTF8Encoding(`$false)))
    exit 0
}
try {
    $inner
    `$code = `$LASTEXITCODE
    if (`$null -eq `$code) { `$code = 0 }
} catch {
    Write-Output ('job error: ' + `$_.Exception.Message)
    `$code = 1
}
[IO.File]::WriteAllText($($q)$($exitFile)$($q), [string]`$code, (New-Object System.Text.UTF8Encoding(`$false)))
"@
[IO.File]::WriteAllText($runner, $runnerText, $utf8)
$meta = @{ id = $id; name = $Name; started = (Get-Date).ToString('s'); file = $File; command = $Command } | ConvertTo-Json
[IO.File]::WriteAllText((Join-Path $jobDir 'job.json'), $meta, $utf8)
$cmdLine = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $runner + '"'
$res = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmdLine }
if ($res.ReturnValue -ne 0) { Write-Output ('JOB_FAILED wmi create returned ' + $res.ReturnValue); exit 1 }
$jobPid = $null
for ($i = 0; $i -lt 25; $i++) {
    if (Test-Path $pidFile) { $jobPid = ([IO.File]::ReadAllText($pidFile)).Trim(); break }
    Start-Sleep -Milliseconds 200
}
if (-not $jobPid) { $jobPid = [string]$res.ProcessId }
Write-Output ("JOB_STARTED id=" + $id + " pid=" + $jobPid + " log=" + $outLog)
