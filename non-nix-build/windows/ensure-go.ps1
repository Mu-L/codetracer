Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function ConvertTo-GoFileArch {
  param([string]$Arch)
  switch ($Arch) {
    "x64" { return "amd64" }
    "arm64" { return "arm64" }
    default { throw "Unsupported Go arch '$Arch'." }
  }
}

function Ensure-Go {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Arch,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

  $version = $Toolchain["GO_VERSION"]
  $goArch = ConvertTo-GoFileArch -Arch $Arch
  $asset = "go$version.windows-$goArch.zip"
  $goVersionRoot = Join-Path $Root "go/$version"
  $extractDir = Join-Path $goVersionRoot "go"
  $goExe = Join-Path $extractDir "bin/go.exe"

  if (Test-Path -LiteralPath $goExe -PathType Leaf) {
    $currentVersion = ""
    try {
      $versionOutput = & $goExe version 2>&1
      if ($versionOutput -match 'go([0-9]+\.[0-9]+\.[0-9]+)') {
        $currentVersion = $Matches[1]
      }
    } catch {}

    if ($currentVersion -eq $version) {
      Write-Host "Go $version already installed at $extractDir"
      return
    }
  }

  New-Item -ItemType Directory -Force -Path $goVersionRoot | Out-Null
  $downloadUrl = "https://go.dev/dl/$asset"
  $shaUrl = "$downloadUrl.sha256"

  $tempZip = Join-Path $env:TEMP $asset
  Download-File -Url $downloadUrl -OutFile $tempZip

  try {
    $shaText = Download-String -Url $shaUrl
    # Go .sha256 file contains just the hash
    $expected = $shaText.Trim().ToLowerInvariant()
    Assert-FileSha256 -Path $tempZip -Expected $expected

    Ensure-CleanDirectory -Path $goVersionRoot
    Expand-Archive -Path $tempZip -DestinationPath $goVersionRoot -Force
  } finally {
    Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
  }

  if (-not (Test-Path -LiteralPath $goExe -PathType Leaf)) {
    throw "Go extraction did not produce '$goExe'."
  }

  Write-Host "Installed Go $version to $extractDir"
}
