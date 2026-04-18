Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Gnat {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

  # GNAT FSF builds from the Alire project provide a standalone GNAT (Ada
  # compiler) built on top of GCC.  We pin the GNAT version to the same GCC
  # major.minor so that object files are ABI-compatible with the WinLibs GCC
  # used for C/C++.
  #
  # The GNAT FSF distribution ships its own gcc.exe (with Ada front-end
  # enabled).  We do NOT put its bin/ on PATH globally because that would
  # shadow the WinLibs GCC.  Instead, only a `gnatmake` shim is created that
  # temporarily prepends the GNAT bin directory so gnatmake's child processes
  # (gcc, gnatbind, gnatlink) resolve to the GNAT-aware copies.

  $version = $Toolchain["GNAT_VERSION"]
  if ([string]::IsNullOrWhiteSpace($version)) {
    # Fall back to GCC_VERSION when GNAT_VERSION is not explicitly pinned.
    $version = $Toolchain["GCC_VERSION"]
  }

  $gnatRoot = Join-Path $Root "gnat/$version"
  $gnatBinDir = Join-Path $gnatRoot "bin"
  $gnatmakeExe = Join-Path $gnatBinDir "gnatmake.exe"

  if (Test-Path -LiteralPath $gnatmakeExe -PathType Leaf) {
    $currentVersion = ""
    try {
      $versionOutput = & $gnatmakeExe --version 2>&1 | Select-Object -First 1
      if ($versionOutput -match '([0-9]+\.[0-9]+\.[0-9]+)') {
        $currentVersion = $Matches[1]
      }
    } catch {}

    if ($currentVersion -eq $version) {
      Write-Host "GNAT $version already installed at $gnatRoot"
      return
    }
  }

  # Download the GNAT FSF build from the Alire project's GitHub releases.
  $releaseTag = "gnat-$version-1"
  $asset = "gnat-x86_64-windows64-$version-1.tar.gz"
  $downloadUrl = "https://github.com/alire-project/GNAT-FSF-builds/releases/download/$releaseTag/$asset"

  $tempTar = Join-Path $env:TEMP $asset
  Download-File -Url $downloadUrl -OutFile $tempTar

  try {
    Ensure-CleanDirectory -Path $gnatRoot

    # The tarball contains a single top-level directory
    # (gnat-x86_64-windows64-<version>-1/).  Extract with --strip-components
    # so contents land directly in $gnatRoot.
    & tar xzf $tempTar -C $gnatRoot --strip-components=1
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to extract GNAT tarball."
    }
  } finally {
    Remove-Item -LiteralPath $tempTar -Force -ErrorAction SilentlyContinue
  }

  if (-not (Test-Path -LiteralPath $gnatmakeExe -PathType Leaf)) {
    throw "GNAT extraction did not produce gnatmake.exe. Expected '$gnatmakeExe'."
  }

  Write-Host "Installed GNAT $version to $gnatRoot"
}
