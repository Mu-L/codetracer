Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Fpc {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Arch,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

  $version = $Toolchain["FPC_VERSION"]
  $fpcVersionRoot = Join-Path $Root "fpc/$version"
  $fpcExe = Join-Path $fpcVersionRoot "bin/x86_64-win64/fpc.exe"

  if (Test-Path -LiteralPath $fpcExe -PathType Leaf) {
    $currentVersion = ""
    try {
      $versionOutput = & $fpcExe -iV 2>&1
      $currentVersion = ([string]$versionOutput).Trim()
    } catch {}

    if ($currentVersion -eq $version) {
      Write-Host "FreePascal $version already installed at $fpcVersionRoot"
      return
    }
  }

  New-Item -ItemType Directory -Force -Path $fpcVersionRoot | Out-Null
  $asset = "fpc-$version.i386-win32.cross.x86_64-win64.zip"
  $downloadUrl = "https://sourceforge.net/projects/freepascal/files/Win32/$version/$asset/download"

  $tempZip = Join-Path $env:TEMP "fpc-$version-x86_64-win64.zip"
  Download-File -Url $downloadUrl -OutFile $tempZip

  try {
    Ensure-CleanDirectory -Path $fpcVersionRoot
    Expand-Archive -Path $tempZip -DestinationPath $fpcVersionRoot -Force
  } finally {
    Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
  }

  # The zip may extract into a nested directory; try to locate fpc.exe.
  if (-not (Test-Path -LiteralPath $fpcExe -PathType Leaf)) {
    # Search for fpc.exe within the extraction root.
    $candidates = Get-ChildItem -LiteralPath $fpcVersionRoot -Recurse -Filter "fpc.exe" -ErrorAction SilentlyContinue
    if ($candidates.Count -gt 0) {
      Write-Host "FreePascal fpc.exe found at $($candidates[0].FullName) (expected at $fpcExe)."
    } else {
      throw "FreePascal extraction did not produce fpc.exe. Expected '$fpcExe'."
    }
  }

  Write-Host "Installed FreePascal $version to $fpcVersionRoot"
}
