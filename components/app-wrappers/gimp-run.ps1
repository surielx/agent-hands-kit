# gimp-run.ps1 -- run a Script-Fu or Python batch in GIMP console (headless)
#
# Judgment model:
# - Script-Fu batches: the process exits by itself via the appended (gimp-quit 0);
#   success = exit code 0 and no 'execution error' in the log.
# - Python batches (GIMP 3.0.4): python-fu-eval has no return value, so GIMP marks
#   the batch as failed and stops processing any further -b commands; a chained
#   quit therefore never runs, and Gimp.quit() called inside the job does not end
#   the process either. The process lingers after the work is done, so the exit
#   code / process exit cannot judge a Python job. Declare the expected results
#   instead (-ExpectFile and/or -ResultFile + -DoneMarker): once every declared
#   file exists (written during this run, size stable) and the result file
#   contains the marker, the wrapper terminates the lingering process itself and
#   judges by the files. A Python traceback in the GIMP log fails the run fast,
#   and so does the fail marker (-FailMarker, default 'JOB FAILED') appearing in
#   the result file. Note that PDB-level failures (e.g. Gimp.file_load on a
#   missing file) do NOT raise in the Python bindings -- they only print a GIMP
#   error to the log and return None -- so a Python job must check its results
#   itself and write the fail marker (or withhold the done marker) on failure.
param(
  [Parameter(Mandatory=$true)][string]$Batch,
  [string]$LogFile,
  [switch]$Python,
  [switch]$NoQuit,
  [int]$TimeoutSec = 600,
  [string[]]$ExpectFile,
  [string]$ResultFile,
  [string]$DoneMarker = 'JOB_DONE',
  [string]$FailMarker = 'JOB FAILED',
  [int]$KillGraceSec = 15
)
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

function Resolve-Gimp {
  $known = 'C:\Program Files\GIMP 3\bin\gimp-console-3.0.exe'
  if (Test-Path $known) { return $known }
  $dirs = Get-ChildItem 'C:\Program Files' -Directory -ErrorAction SilentlyContinue
  $dirs = $dirs | Where-Object { $_.Name -like 'GIMP *' } | Sort-Object Name -Descending
  foreach ($d in $dirs) {
    $binDir = Join-Path $d.FullName 'bin'
    $hit = Get-ChildItem $binDir -Filter 'gimp-console-*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hit) { return $hit.FullName }
  }
  $cmd = Get-Command gimp -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

function Read-SharedRaw([string]$Path) {
  if (-not (Test-Path $Path)) { return '' }
  try {
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
      $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::Default)
      return $sr.ReadToEnd()
    } finally { $fs.Dispose() }
  } catch { return '' }
}

$exe = Resolve-Gimp
if (-not $exe) { Write-Output 'GIMP_FAILED gimp console exe not found'; exit 1 }

if (-not $LogFile) {
  $workDir = if ($env:AGENT_HOME) { Join-Path $env:AGENT_HOME 'work' } else { [IO.Path]::GetTempPath() }
  if (-not (Test-Path $workDir)) { New-Item -ItemType Directory -Path $workDir -Force | Out-Null }
  $LogFile = Join-Path $workDir 'gimp-batch.log'
}
$errFile = "$LogFile.err"

$interp = 'plug-in-script-fu-eval'
if ($Python) { $interp = 'python-fu-eval' }
$argList = @('-i', '--batch-interpreter', $interp, '-b', $Batch)
if (-not $NoQuit -and -not $Python) { $argList += @('-b', '(gimp-quit 0)') }
# NOTE: for Python no quit command is appended. Gimp.quit(True) raises TypeError on
# this build, Gimp.quit() inside the job does not end the process, and any second
# -b never runs (see header). The wrapper ends the process itself once the
# declared outputs are established (or on timeout).

$quoted = @()
foreach ($a in $argList) {
  if ($a -match '\s') { $quoted += '"' + ($a -replace '"', '\"') + '"' } else { $quoted += $a }
}
$argString = $quoted -join ' '

$hasExpect = ($ExpectFile -and $ExpectFile.Count -gt 0) -or ($ResultFile)
$runStart = Get-Date
$procName = [IO.Path]::GetFileNameWithoutExtension($exe)

function Stop-RunProcesses {
  $n = 0
  Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
  $targets = Get-Process -Name $procName -ErrorAction SilentlyContinue | Where-Object { $_.StartTime -ge $runStart.AddSeconds(-5) }
  foreach ($tp in $targets) { Stop-Process -Id $tp.Id -Force -ErrorAction SilentlyContinue; $n++ }
  $sf = Get-Process -Name 'script-fu' -ErrorAction SilentlyContinue | Where-Object { $_.StartTime -ge $runStart.AddSeconds(-5) }
  foreach ($tp in $sf) { Stop-Process -Id $tp.Id -Force -ErrorAction SilentlyContinue; $n++ }
  return $n
}

function Test-Expectations([hashtable]$PrevSizes) {
  # returns $true when every declared output is established
  if ($ExpectFile) {
    foreach ($f in $ExpectFile) {
      if (-not (Test-Path $f)) { return $false }
      $item = Get-Item $f -ErrorAction SilentlyContinue
      if (-not $item -or $item.Length -le 0) { return $false }
      if ($item.LastWriteTime -lt $runStart.AddSeconds(-5)) { return $false }
      if (-not $PrevSizes.ContainsKey($f) -or $PrevSizes[$f] -ne $item.Length) { return $false }
    }
  }
  if ($ResultFile) {
    if (-not (Test-Path $ResultFile)) { return $false }
    $ritem = Get-Item $ResultFile -ErrorAction SilentlyContinue
    if (-not $ritem -or $ritem.LastWriteTime -lt $runStart.AddSeconds(-5)) { return $false }
    $txt = Read-SharedRaw $ResultFile
    if ($txt -notmatch [regex]::Escape($DoneMarker)) { return $false }
  }
  return $true
}

$p = Start-Process -FilePath $exe -ArgumentList $argString -PassThru -NoNewWindow -RedirectStandardOutput $LogFile -RedirectStandardError $errFile
# Pin the process handle now: with Start-Process + redirection on PS 5.1 the
# ExitCode is lost (returns $null) unless the handle is touched while the
# process is alive or WaitForExit is the very first wait. Verified empirically.
try { $null = $p.Handle } catch {}

$naturalExit = $false
$expectMet = $false
$killedAfterDone = $false
$tracebackFail = $false
$sfError = $false
$jobFailed = $false
$timedOut = $false
$prevSizes = @{}
$tracePolls = 0
$sfErrPolls = 0
$sw = [Diagnostics.Stopwatch]::StartNew()

while ($true) {
  if ($p.HasExited) { $naturalExit = $true; break }
  if ($sw.Elapsed.TotalSeconds -ge $TimeoutSec) { $timedOut = $true; break }

  if ($hasExpect) {
    # record sizes for the stability check on the next poll
    if ($ExpectFile) {
      foreach ($f in $ExpectFile) {
        if (Test-Path $f) { $prevSizes[$f] = (Get-Item $f -ErrorAction SilentlyContinue).Length }
      }
    }
    Start-Sleep -Seconds 2
    if ($p.HasExited) { $naturalExit = $true; break }
    if (Test-Expectations $prevSizes) {
      $expectMet = $true
      # give the process a short grace period to exit on its own anyway
      $graceEnd = $sw.Elapsed.TotalSeconds + $KillGraceSec
      while (-not $p.HasExited -and $sw.Elapsed.TotalSeconds -lt $graceEnd) { Start-Sleep -Seconds 1 }
      if ($p.HasExited) { $naturalExit = $true } else {
        $null = Stop-RunProcesses
        $killedAfterDone = $true
      }
      break
    }
  } else {
    Start-Sleep -Seconds 2
  }

  # fail fast when the job itself reports failure in its result file
  if ($ResultFile -and (Test-Path $ResultFile)) {
    $ritem = Get-Item $ResultFile -ErrorAction SilentlyContinue
    if ($ritem -and $ritem.LastWriteTime -ge $runStart.AddSeconds(-5)) {
      $rtxt = Read-SharedRaw $ResultFile
      if ($rtxt -match [regex]::Escape($FailMarker)) { $jobFailed = $true; break }
    }
  }

  # fail fast: an unhandled Python traceback means the job is dead; do not sit
  # out the whole timeout. Require it to persist across two polls so a job that
  # logs a traceback and recovers has a chance to establish its outputs first.
  if ($Python -and -not $expectMet) {
    $logSoFar = (Read-SharedRaw $LogFile) + (Read-SharedRaw $errFile)
    if ($logSoFar -match 'Traceback \(most recent call last\)') {
      $tracePolls++
      if ($tracePolls -ge 2) { $tracebackFail = $true; break }
    } else { $tracePolls = 0 }
  }

  # fail fast: a Script-Fu execution error stops batch processing, so the
  # appended (gimp-quit 0) never runs and the process would linger until the
  # timeout. The log line is unambiguous; fail as soon as it persists.
  if (-not $Python) {
    $logSoFar = (Read-SharedRaw $LogFile) + (Read-SharedRaw $errFile)
    if ($logSoFar -match 'execution error') {
      $sfErrPolls++
      if ($sfErrPolls -ge 2) { $sfError = $true; break }
    } else { $sfErrPolls = 0 }
  }
}

if ($timedOut -or $tracebackFail -or $jobFailed -or $sfError) {
  $null = Stop-RunProcesses
}

# the process may have exited on its own before a poll could verify the outputs
if ($hasExpect -and -not $expectMet -and $naturalExit) {
  $prevSizes = @{}
  if ($ExpectFile) {
    foreach ($f in $ExpectFile) {
      if (Test-Path $f) { $prevSizes[$f] = (Get-Item $f -ErrorAction SilentlyContinue).Length }
    }
  }
  Start-Sleep -Seconds 2
  if (Test-Expectations $prevSizes) { $expectMet = $true }
}

# gimp-console may leave a detached child process behind after the batch ends; clean up only our own leftovers
Start-Sleep -Seconds 2
$leftovers = Get-Process -Name $procName -ErrorAction SilentlyContinue | Where-Object { $_.StartTime -ge $runStart.AddSeconds(-5) }
$killed = 0
foreach ($lp in $leftovers) { Stop-Process -Id $lp.Id -Force -ErrorAction SilentlyContinue; $killed++ }
if ($killed -gt 0) { Write-Output "GIMP_CLEANUP killed=$killed" }
if ($killedAfterDone) { Write-Output 'GIMP_NOTE outputs verified; terminated lingering gimp process' }

if (Test-Path $errFile) {
  if ((Get-Item $errFile).Length -gt 0) {
    $merged = $false
    for ($try = 0; $try -lt 5 -and -not $merged; $try++) {
      try { Add-Content -Path $LogFile -Value (Get-Content $errFile) -ErrorAction Stop; $merged = $true }
      catch { Start-Sleep -Milliseconds 600 }
    }
  }
  Remove-Item $errFile -Force -ErrorAction SilentlyContinue
}
$logText = ''
if (Test-Path $LogFile) { $logText = Get-Content $LogFile -Raw -ErrorAction SilentlyContinue }
if ($logText) { Get-Content $LogFile -Tail 5 | ForEach-Object { Write-Output $_ } }

if ($timedOut) { Write-Output "GIMP_FAILED timeout after ${TimeoutSec}s log=$LogFile"; exit 1 }
if ($jobFailed) { Write-Output "GIMP_FAILED job reported failure in result file log=$LogFile"; exit 1 }
if ($tracebackFail) { Write-Output "GIMP_FAILED python traceback in log=$LogFile"; exit 1 }
if ($sfError) { Write-Output "GIMP_FAILED script-fu execution error in log=$LogFile"; exit 1 }
if ($hasExpect -and -not $expectMet) { Write-Output "GIMP_FAILED expected outputs not established log=$LogFile"; exit 1 }
if (-not $Python -and $logText -match 'execution error') { Write-Output "GIMP_FAILED script-fu execution error in log=$LogFile"; exit 1 }
if ($Python -and -not $hasExpect -and $logText -match 'Traceback \(most recent call last\)') { Write-Output "GIMP_FAILED python traceback in log=$LogFile"; exit 1 }
if ($naturalExit) { try { $p.WaitForExit() } catch {} }
$exitCode = $null
try { $exitCode = $p.ExitCode } catch {}
if (-not $killedAfterDone) {
  if (-not $naturalExit) { Write-Output "GIMP_FAILED process did not exit log=$LogFile"; exit 1 }
  if ($exitCode -ne 0) { Write-Output "GIMP_FAILED exit=$exitCode log=$LogFile"; exit 1 }
}
Write-Output "GIMP_OK $LogFile"
exit 0
