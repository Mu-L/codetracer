Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Ttd {
  param(
    [Parameter(Mandatory = $true)][string]$Root
  )

  # TTD and WinDbg are system-level AppX packages installed via winget.
  # After installation, we copy the TTD files to the DIY cache so they
  # are accessible from non-interactive sessions (SSH, CI) where AppX
  # container isolation would otherwise block execution.

  # --- Step 1: Install AppX packages if missing ---
  $ttdPkg = Get-AppxPackage "Microsoft.TimeTravelDebugging" -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending | Select-Object -First 1
  $windbgPkg = Get-AppxPackage "Microsoft.WinDbg" -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending | Select-Object -First 1

  $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
  if ($null -eq $wingetCmd) {
    if ($null -eq $ttdPkg -or $null -eq $windbgPkg) {
      throw "winget is required to install TTD/WinDbg but was not found on PATH. Install winget (App Installer from Microsoft Store) or install TTD/WinDbg manually."
    }
    Write-Host "winget not found; TTD and WinDbg already installed, skipping install step."
  } else {
    if ($null -eq $ttdPkg) {
      Write-Host "Installing Microsoft.TimeTravelDebugging via winget..."
      & winget install --id Microsoft.TimeTravelDebugging --exact --source winget --accept-source-agreements --accept-package-agreements
      if ($LASTEXITCODE -ne 0) {
        throw "Failed to install Microsoft.TimeTravelDebugging via winget (exit code $LASTEXITCODE)."
      }
      $ttdPkg = Get-AppxPackage "Microsoft.TimeTravelDebugging" -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending | Select-Object -First 1
    } else {
      Write-Host "Microsoft.TimeTravelDebugging already installed (version $($ttdPkg.Version))."
    }

    if ($null -eq $windbgPkg) {
      Write-Host "Installing Microsoft.WinDbg via winget..."
      & winget install --id Microsoft.WinDbg --exact --source winget --accept-source-agreements --accept-package-agreements
      if ($LASTEXITCODE -ne 0) {
        throw "Failed to install Microsoft.WinDbg via winget (exit code $LASTEXITCODE)."
      }
      $windbgPkg = Get-AppxPackage "Microsoft.WinDbg" -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending | Select-Object -First 1
    } else {
      Write-Host "Microsoft.WinDbg already installed (version $($windbgPkg.Version))."
    }
  }

  # Validate installation
  if ($null -eq $ttdPkg) {
    throw "Microsoft.TimeTravelDebugging is not installed after attempted install."
  }
  if ($null -eq $windbgPkg) {
    throw "Microsoft.WinDbg is not installed after attempted install."
  }

  Write-Host "TTD version: $($ttdPkg.Version), WinDbg version: $($windbgPkg.Version)"

  # --- Step 2: Copy TTD files to DIY cache for SSH/CI accessibility ---
  # AppX packages live under C:\Program Files\WindowsApps which has
  # container ACLs that prevent execution from SSH sessions. Copying
  # the files to a regular directory solves this.
  $ttdVersion = [string]$ttdPkg.Version
  $ttdCacheDir = Join-Path $Root "ttd/$ttdVersion"
  $ttdCacheExe = Join-Path $ttdCacheDir "TTD.exe"
  $ttdCacheReplayDll = Join-Path $ttdCacheDir "TTDReplay.dll"
  $metaFile = Join-Path $ttdCacheDir "ttd.install.meta"

  $expectedMeta = @{
    ttd_version = $ttdVersion
    ttd_source = [string]$ttdPkg.InstallLocation
  }

  # Check if already cached with correct version
  if ((Test-Path -LiteralPath $ttdCacheExe -PathType Leaf) -and (Test-Path -LiteralPath $metaFile -PathType Leaf)) {
    $cachedMeta = Read-KeyValueFile -Path $metaFile
    if (Test-KeyValueFileMatches -Expected $expectedMeta -Actual $cachedMeta) {
      Write-Host "TTD $ttdVersion already cached at $ttdCacheDir"
      return
    }
  }

  # Copy from AppX install location
  $ttdSource = [string]$ttdPkg.InstallLocation
  if ([string]::IsNullOrWhiteSpace($ttdSource) -or -not (Test-Path -LiteralPath $ttdSource -PathType Container)) {
    throw "TTD AppX InstallLocation is missing or inaccessible: '$ttdSource'"
  }

  Write-Host "Copying TTD files from AppX to DIY cache: $ttdCacheDir"
  if (Test-Path -LiteralPath $ttdCacheDir) {
    Remove-Item -LiteralPath $ttdCacheDir -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $ttdCacheDir | Out-Null

  # Copy all files from the TTD package directory
  # Key files: TTD.exe, TTDReplay.dll, TTDReplayCPU.dll, TTDLoader.dll, etc.
  $sourceFiles = Get-ChildItem -LiteralPath $ttdSource -File -ErrorAction SilentlyContinue
  foreach ($f in $sourceFiles) {
    Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $ttdCacheDir $f.Name) -Force
  }

  # Also copy subdirectories (some TTD versions have arch-specific subdirs)
  $sourceDirs = Get-ChildItem -LiteralPath $ttdSource -Directory -ErrorAction SilentlyContinue
  foreach ($d in $sourceDirs) {
    Copy-Item -LiteralPath $d.FullName -Destination (Join-Path $ttdCacheDir $d.Name) -Recurse -Force
  }

  if (-not (Test-Path -LiteralPath $ttdCacheExe -PathType Leaf)) {
    throw "TTD.exe not found after copying from AppX. Source: $ttdSource, Dest: $ttdCacheDir"
  }

  # Write meta file for cache validation
  Write-KeyValueFile -Path $metaFile -Values $expectedMeta

  Write-Host "TTD $ttdVersion cached successfully at $ttdCacheDir"
}
