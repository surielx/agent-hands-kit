# freecad-run.ps1 -- run a Python script in FreeCAD headless mode (FreeCADCmd)
# The script runs in FreeCAD's own Python environment (FreeCAD / Part / Mesh modules available).
# Success is judged by the declared -ExpectFile outputs (created or updated in this run,
# size > 0), the process exit code, and the absence of a Python traceback in the log.
param(
  [Parameter(Mandatory=$true)][string]$Script,
  [string[]]$ExpectFile,
  [string]$LogFile,
  [int]$TimeoutSec = 600,
  [string[]]$ExtraArgs
)
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

function Resolve-FreeCADCmd {
  $cands = foreach ($d in (Get-ChildItem 'C:\Program Files' -Directory -ErrorAction SilentlyContinue)) {
    if ($d.Name -match '^FreeCAD\s+(\d+)\.(\d+)') {
      $exe = Join-Path $d.FullName 'bin\FreeCADCmd.exe'
      if (Test-Path $exe) {
        [PSCustomObject]@{ Ver = [version]("$($Matches[1]).$($Matches[2])"); Exe = $exe }
      }
    }
  }
  $best = $cands | Sort-Object Ver -Descending | Select-Object -First 1
  if ($best) { return $best.Exe }
  $flat = 'C:\Program Files\FreeCAD 1.0\bin\FreeCADCmd.exe'
  if (Test-Path $flat) { return $flat }
  $cmd = Get-Command FreeCADCmd -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

# Normalize -ExpectFile: when the wrapper is invoked via "powershell -File ... -ExpectFile a,b"
# the comma list can arrive as ONE string, while an in-session call passes a real array.
if ($ExpectFile) {
  $ExpectFile = @($ExpectFile | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

$exe = Resolve-FreeCADCmd
if (-not $exe) { Write-Output 'FREECAD_FAILED FreeCADCmd.exe not found'; exit 1 }
if (-not (Test-Path $Script)) { Write-Output "FREECAD_FAILED script not found: $Script"; exit 1 }

$scriptFull = (Resolve-Path $Script).Path
if (-not $LogFile) {
  $dir = [IO.Path]::GetDirectoryName($scriptFull)
  $base = [IO.Path]::GetFileNameWithoutExtension($scriptFull)
  $LogFile = Join-Path $dir "$base.freecad.log"
}
# Snapshot the expected outputs before the run so stale files cannot pass as success.
$expectState = @{}
if ($ExpectFile) {
  foreach ($f in $ExpectFile) {
    if (Test-Path $f) {
      $fi = Get-Item $f
      $expectState[$f] = @{ Exists = $true; Time = $fi.LastWriteTime; Len = $fi.Length }
    } else {
      $expectState[$f] = @{ Exists = $false; Time = $null; Len = 0 }
    }
  }
}

$argList = @($scriptFull)
if ($ExtraArgs) { $argList += $ExtraArgs }
$argString = ($argList | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '

# NOTE: launched via System.Diagnostics.Process instead of Start-Process on purpose:
# on PowerShell 5.1, Start-Process with redirected output can return a null ExitCode
# even after the child has finished, which would misreport a good run as a failure.
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $exe
$psi.Arguments = $argString
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.StandardOutputEncoding = [Text.Encoding]::UTF8
$psi.StandardErrorEncoding = [Text.Encoding]::UTF8

$runStart = Get-Date
$p = [System.Diagnostics.Process]::Start($psi)
$outTask = $p.StandardOutput.ReadToEndAsync()
$errTask = $p.StandardError.ReadToEndAsync()
$finished = $p.WaitForExit($TimeoutSec * 1000)
if (-not $finished) {
  try { $p.Kill() } catch {}
  try { $p.WaitForExit(5000) | Out-Null } catch {}
  Write-Output "FREECAD_FAILED timeout after ${TimeoutSec}s log=$LogFile"
  exit 1
}
$p.WaitForExit()
[IO.File]::WriteAllText($LogFile, $outTask.Result, (New-Object Text.UTF8Encoding($false)))
if ($errTask.Result) { Add-Content -Path $LogFile -Value $errTask.Result }
$exitCode = $p.ExitCode
$logText = ''
if (Test-Path $LogFile) { $logText = Get-Content $LogFile -Raw -ErrorAction SilentlyContinue }
if ($logText) { Get-Content $LogFile -Tail 5 | ForEach-Object { Write-Output $_ } }

if ($exitCode -ne 0) { Write-Output "FREECAD_FAILED exit=$exitCode log=$LogFile"; exit 1 }
if ($logText -match 'Traceback \(most recent call last\)') { Write-Output "FREECAD_FAILED python traceback in log=$LogFile"; exit 1 }

$outDetail = @()
if ($ExpectFile) {
  foreach ($f in $ExpectFile) {
    $st = $expectState[$f]
    if (-not (Test-Path $f)) { Write-Output "FREECAD_FAILED expected output not created: $f log=$LogFile"; exit 1 }
    $fi = Get-Item $f
    if ($fi.Length -le 0) { Write-Output "FREECAD_FAILED expected output is empty: $f log=$LogFile"; exit 1 }
    $fresh = (-not $st.Exists) -or ($fi.LastWriteTime -ge $runStart.AddSeconds(-2))
    if (-not $fresh) { Write-Output "FREECAD_FAILED expected output was not updated in this run: $f log=$LogFile"; exit 1 }
    $outDetail += "$f ($($fi.Length) bytes)"
  }
}
if ($outDetail) {
  Write-Output "FREECAD_OK $LogFile outputs=$($outDetail -join ', ')"
} else {
  Write-Output "FREECAD_OK $LogFile"
}
exit 0
