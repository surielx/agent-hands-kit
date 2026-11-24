# ltspice-run.ps1 -- run LTspice in batch mode on a netlist (.net/.cir)
# Usage: powershell -File tools\ltspice-run.ps1 -Netlist <path to .net> [-TimeoutSec 600]
param(
  [Parameter(Mandatory=$true)][string]$Netlist,
  [int]$TimeoutSec = 600
)
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

function Resolve-LTspice {
  $cands = @(
    "$env:LOCALAPPDATA\Programs\ADI\LTspice\LTspice.exe",
    'C:\Program Files\ADI\LTspice\LTspice.exe',
    'C:\Program Files\LTC\LTspiceXVII\XVIIx64.exe'
  )
  foreach ($c in $cands) { if (Test-Path $c) { return $c } }
  $cmd = Get-Command LTspice -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

$exe = Resolve-LTspice
if (-not $exe) { Write-Output 'LTSPICE_FAILED LTspice.exe not found'; exit 1 }
if (-not (Test-Path $Netlist)) { Write-Output "LTSPICE_FAILED netlist not found: $Netlist"; exit 1 }

$netFull = (Resolve-Path $Netlist).Path
$workDir = [IO.Path]::GetDirectoryName($netFull)
$base = [IO.Path]::GetFileNameWithoutExtension($netFull)
$rawFile = Join-Path $workDir "$base.raw"
$logFile = Join-Path $workDir "$base.log"
$rawBefore = if (Test-Path $rawFile) { (Get-Item $rawFile).LastWriteTime } else { $null }

$p = Start-Process -FilePath $exe -ArgumentList '-b', $netFull -WorkingDirectory $workDir -PassThru
$ok = $p.WaitForExit($TimeoutSec * 1000)
if (-not $ok) {
  $p.Kill(); $p.WaitForExit()
  Write-Output "LTSPICE_FAILED timeout after ${TimeoutSec}s"
  exit 1
}
if ($p.ExitCode -ne 0) { Write-Output "LTSPICE_FAILED exit=$($p.ExitCode)"; exit 1 }
if (-not (Test-Path $rawFile)) { Write-Output "LTSPICE_FAILED no .raw produced (see $logFile)"; exit 1 }
if ($rawBefore -and ((Get-Item $rawFile).LastWriteTime -le $rawBefore)) { Write-Output "LTSPICE_FAILED .raw not updated (see $logFile)"; exit 1 }
Write-Output "LTSPICE_OK $rawFile"
exit 0
