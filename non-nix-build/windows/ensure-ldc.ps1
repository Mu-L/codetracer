Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function ConvertTo-LdcFileArch {
  param([string]$Arch)
  switch ($Arch) {
    "x64" { return "x64" }
    default { throw "LDC bootstrap currently supports Windows x64 only. No pinned official asset is configured for '$Arch'." }
  }
}

function Ensure-Ldc {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Arch,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

  $version = $Toolchain["LDC_VERSION"]
  $ldcArch = ConvertTo-LdcFileArch -Arch $Arch
  $assetBase = "ldc2-$version-windows-$ldcArch"
  $asset = "$assetBase.zip"
  $ldcVersionRoot = Join-Path $Root "ldc/$version"
  $extractDir = Join-Path $ldcVersionRoot $assetBase
  $ldcExe = Join-Path $extractDir "bin/ldc2.exe"

  if (Test-Path -LiteralPath $ldcExe -PathType Leaf) {
    $currentVersion = ""
    try {
      $versionOutput = & $ldcExe --version 2>&1 | Select-Object -First 1
      if ($versionOutput -match 'LDC.*\(([0-9]+\.[0-9]+\.[0-9]+)\)') {
        $currentVersion = $Matches[1]
      } elseif ($versionOutput -match '([0-9]+\.[0-9]+\.[0-9]+)') {
        $currentVersion = $Matches[1]
      }
    } catch {}

    if ($currentVersion -eq $version) {
      Write-Host "LDC $version already installed at $extractDir"
      return
    }
  }

  New-Item -ItemType Directory -Force -Path $ldcVersionRoot | Out-Null
  $downloadUrl = "https://github.com/ldc-developers/ldc/releases/download/v$version/$asset"

  $tempZip = Join-Path $env:TEMP $asset
  Download-File -Url $downloadUrl -OutFile $tempZip

  try {
    Ensure-CleanDirectory -Path $ldcVersionRoot
    Expand-Archive -Path $tempZip -DestinationPath $ldcVersionRoot -Force
  } finally {
    Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
  }

  if (-not (Test-Path -LiteralPath $ldcExe -PathType Leaf)) {
    throw "LDC extraction did not produce '$ldcExe'."
  }

  Write-Host "Installed LDC $version to $extractDir"
}
