Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Vlang {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Arch,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

  $version = $Toolchain["VLANG_VERSION"]
  $asset = "v_windows.zip"
  $vlangVersionRoot = Join-Path $Root "vlang/$version"
  $extractDir = Join-Path $vlangVersionRoot "v"
  $vExe = Join-Path $extractDir "v.exe"

  if (Test-Path -LiteralPath $vExe -PathType Leaf) {
    $currentVersion = ""
    try {
      $versionOutput = & $vExe version 2>&1
      if ($versionOutput -match '([0-9]+\.[0-9]+\.[0-9]+)') {
        $currentVersion = $Matches[1]
      }
    } catch {}

    if ($currentVersion -eq $version) {
      Write-Host "V $version already installed at $extractDir"
      return
    }
  }

  New-Item -ItemType Directory -Force -Path $vlangVersionRoot | Out-Null
  $downloadUrl = "https://github.com/vlang/v/releases/download/$version/$asset"

  $tempZip = Join-Path $env:TEMP "vlang-$version-$asset"
  Download-File -Url $downloadUrl -OutFile $tempZip

  try {
    Ensure-CleanDirectory -Path $vlangVersionRoot
    Expand-Archive -Path $tempZip -DestinationPath $vlangVersionRoot -Force
  } finally {
    Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
  }

  if (-not (Test-Path -LiteralPath $vExe -PathType Leaf)) {
    throw "V extraction did not produce '$vExe'."
  }

  Write-Host "Installed V $version to $extractDir"
}
