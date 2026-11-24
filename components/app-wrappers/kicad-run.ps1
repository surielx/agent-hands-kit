# kicad-run.ps1 -- run kicad-cli with arbitrary subcommand arguments
# Usage: powershell -File tools\kicad-run.ps1 pcb drc --output report.txt board.kicad_pcb
#        powershell -File tools\kicad-run.ps1 version
# Optional: -LogFile <path> as the FIRST argument pair changes the log location.
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$CliArgs = @($args)
$LogFile = $null
if ($CliArgs.Count -ge 2 -and $CliArgs[0] -eq '-LogFile') {
  $LogFile = $CliArgs[1]
  $CliArgs = $CliArgs[2..($CliArgs.Count - 1)]
}

function Resolve-KicadCli {
  $roots = @("$env:LOCALAPPDATA\Programs\KiCad", 'C:\Program Files\KiCad')
  $cands = foreach ($r in $roots) {
    if (Test-Path $r) {
      Get-ChildItem $r -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $exe = Join-Path $_.FullName 'bin\kicad-cli.exe'
        if ((Test-Path $exe) -and ($_.Name -match '(\d+)\.(\d+)')) {
          [PSCustomObject]@{ Ver = [version]("$($Matches[1]).$($Matches[2])"); Exe = $exe }
        }
      }
    }
  }
  $best = $cands | Sort-Object Ver -Descending | Select-Object -First 1
  if ($best) { return $best.Exe }
  $flat = "$env:LOCALAPPDATA\Programs\KiCad\bin\kicad-cli.exe"
  if (Test-Path $flat) { return $flat }
  $cmd = Get-Command kicad-cli -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

$exe = Resolve-KicadCli
if (-not $exe) { Write-Output 'KICAD_FAILED kicad-cli.exe not found'; exit 1 }
if (-not $CliArgs -or $CliArgs.Count -eq 0) { Write-Output 'KICAD_FAILED no arguments (pass kicad-cli subcommand and options)'; exit 1 }

if (-not $LogFile) {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $LogFile = Join-Path $PWD "kicad-run-$stamp.log"
}
$errFile = "$LogFile.err"
$argString = ($CliArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
$p = Start-Process -FilePath $exe -ArgumentList $argString -Wait -PassThru -NoNewWindow `
      -RedirectStandardOutput $LogFile -RedirectStandardError $errFile
if (Test-Path $errFile) {
  if ((Get-Item $errFile).Length -gt 0) { Add-Content -Path $LogFile -Value (Get-Content $errFile) }
  Remove-Item $errFile -Force -ErrorAction SilentlyContinue
}
if (Test-Path $LogFile) { Get-Content $LogFile -Tail 5 | ForEach-Object { Write-Output $_ } }
if ($p.ExitCode -ne 0) { Write-Output "KICAD_FAILED exit=$($p.ExitCode) log=$LogFile"; exit 1 }
Write-Output "KICAD_OK $LogFile"
exit 0
