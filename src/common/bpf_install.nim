## BPF installation and capability setup for CodeTracer process monitoring.
##
## This module handles the one-time setup of bpftrace with Linux capabilities
## so that BPF-based process monitoring can run without requiring sudo at
## runtime. The setup creates a dedicated copy of bpftrace under
## ``/usr/local/lib/codetracer/`` with ``cap_bpf,cap_perfmon,cap_dac_read_search``
## capabilities, owned by a ``codetracer-bpf`` group.
##
## On NixOS, bpftrace is instead managed via ``security.wrappers`` and lives at
## ``/run/wrappers/bin/codetracer-bpftrace``. When that path exists, all
## local installation steps are skipped.
##
## Kernel >= 5.8 is required for the ``CAP_BPF`` capability. Older kernels
## will receive a warning and BPF setup will be skipped gracefully.

import
  std/[os, osproc, strutils, strformat],
  results,
  strings

const
  BpfInstallDir* = "/usr/local/lib/codetracer"
    ## Directory where the capabilities-aware bpftrace binary is installed.

  BpfBpftracePath* = BpfInstallDir / "bpftrace"
    ## Full path to the local bpftrace copy with capabilities set.

  BpfGroupName* = "codetracer-bpf"
    ## Unix group that grants access to the capabilities-aware bpftrace.

  NixBpfWrapperPath* = "/run/wrappers/bin/codetracer-bpftrace"
    ## Path where the NixOS security.wrappers module places the
    ## capabilities-aware bpftrace binary.

  ## Minimum kernel version required for CAP_BPF support.
  ## See: https://lwn.net/Articles/820560/
  MinKernelMajor = 5
  MinKernelMinor = 8

# ---------------------------------------------------------------------------
# Query helpers
# ---------------------------------------------------------------------------

proc isNixManagedBpf*(): bool =
  ## Returns true if bpftrace is managed by the NixOS package
  ## (via ``security.wrappers``). When true, local installation is unnecessary.
  fileExists(NixBpfWrapperPath)

proc isLocalBpfInstalled*(): bool =
  ## Returns true if the local capabilities-aware bpftrace exists at
  ## ``/usr/local/lib/codetracer/bpftrace``.
  fileExists(BpfBpftracePath)

proc findSystemBpftrace*(): string =
  ## Locate bpftrace on the system. Checks PATH first, then common
  ## installation directories. Returns an empty string if not found.
  result = findExe("bpftrace")
  if result.len > 0:
    return

  # Check common locations where bpftrace may be installed but not on PATH.
  const commonPaths = [
    "/usr/bin/bpftrace",
    "/usr/sbin/bpftrace",
    "/usr/local/bin/bpftrace",
    "/snap/bin/bpftrace",
  ]
  for path in commonPaths:
    if fileExists(path):
      return path

  return ""

proc getBpftracePath*(): string =
  ## Returns the best available bpftrace path, preferring managed/capable
  ## binaries over the raw system binary:
  ##
  ## 1. NixOS wrapper (``/run/wrappers/bin/codetracer-bpftrace``)
  ## 2. Local capabilities-aware copy (``/usr/local/lib/codetracer/bpftrace``)
  ## 3. System bpftrace from PATH / common locations
  ##
  ## Returns an empty string if no bpftrace binary is found anywhere.
  if isNixManagedBpf():
    return NixBpfWrapperPath

  if isLocalBpfInstalled():
    return BpfBpftracePath

  return findSystemBpftrace()

proc needsSudo*(): bool =
  ## Returns true if BPF setup requires sudo (i.e., not nix-managed and the
  ## local copy is not yet installed).
  not isNixManagedBpf() and not isLocalBpfInstalled()

# ---------------------------------------------------------------------------
# Kernel version check
# ---------------------------------------------------------------------------

proc parseKernelVersion(): tuple[major: int, minor: int] =
  ## Parses the running kernel version from ``uname -r``.
  ## Returns (0, 0) on any parsing failure.
  try:
    let output = execProcess("uname", args = ["-r"],
                             options = {poUsePath}).strip()
    # Kernel version strings look like "5.15.0-91-generic" or "6.1.0".
    let parts = output.split({'.', '-'})
    if parts.len >= 2:
      return (parseInt(parts[0]), parseInt(parts[1]))
  except CatchableError:
    discard
  return (0, 0)

proc isKernelCapBpfCapable*(): bool =
  ## Returns true if the running kernel version is >= 5.8, which is
  ## the minimum version that supports ``CAP_BPF``.
  ## See: https://lwn.net/Articles/820560/
  let (major, minor) = parseKernelVersion()
  if major == 0:
    # Could not determine kernel version; assume capable to avoid
    # false negatives on unusual systems.
    return true
  return major > MinKernelMajor or
         (major == MinKernelMajor and minor >= MinKernelMinor)

# ---------------------------------------------------------------------------
# Package manager detection
# ---------------------------------------------------------------------------

proc suggestBpftraceInstall(): string =
  ## Returns a human-readable suggestion for installing bpftrace on the
  ## current system, based on detected package manager.
  if findExe("apt").len > 0:
    return "sudo apt install bpftrace"
  elif findExe("dnf").len > 0:
    return "sudo dnf install bpftrace"
  elif findExe("yum").len > 0:
    return "sudo yum install bpftrace"
  elif findExe("pacman").len > 0:
    return "sudo pacman -S bpftrace"
  elif findExe("zypper").len > 0:
    return "sudo zypper install bpftrace"
  elif findExe("emerge").len > 0:
    return "sudo emerge dev-debug/bpftrace"
  elif findExe("snap").len > 0:
    return "sudo snap install bpftrace"
  else:
    return "Install bpftrace using your distribution's package manager"

# ---------------------------------------------------------------------------
# Installation
# ---------------------------------------------------------------------------

proc installBpf*(sudoCommand: string = "sudo"): Result[void, string] =
  ## Sets up BPF process monitoring support by creating a capabilities-aware
  ## copy of bpftrace. All privileged operations are batched into a single
  ## ``sudo sh -c '...'`` invocation to minimize password prompts.
  ##
  ## Steps performed:
  ## 1. Skip if NixOS wrapper exists (managed by ``security.wrappers``)
  ## 2. Verify kernel >= 5.8 for ``CAP_BPF`` support
  ## 3. Locate system bpftrace
  ## 4. Create ``/usr/local/lib/codetracer/`` directory
  ## 5. Copy bpftrace there
  ## 6. Create ``codetracer-bpf`` group (if not exists)
  ## 7. Add current user to the group
  ## 8. Set ownership ``root:codetracer-bpf``, mode 750
  ## 9. Set capabilities ``cap_bpf,cap_perfmon,cap_dac_read_search+ep``
  ##
  ## Returns ``ok()`` on success or if setup was skipped (Nix-managed).
  ## Returns ``err(message)`` if any step fails.

  # 1. Skip if Nix-managed
  if isNixManagedBpf():
    echo "BPF support is managed by the Nix package (security.wrappers). Skipping local setup."
    return ok()

  # 2. Check kernel version
  if not isKernelCapBpfCapable():
    let (major, minor) = parseKernelVersion()
    return err(fmt2"Kernel {major}.{minor} is too old for CAP_BPF (requires >= {MinKernelMajor}.{MinKernelMinor})")

  # 3. Find system bpftrace
  let systemBpftrace = findSystemBpftrace()
  if systemBpftrace.len == 0:
    let suggestion = suggestBpftraceInstall()
    return err("bpftrace not found on the system. " & suggestion)

  # 4. Already installed check
  if isLocalBpfInstalled():
    echo "BPF support is already set up at " & BpfBpftracePath
    return ok()

  # 5. Run all privileged operations in a single sudo invocation.
  #    Using $USER inside the shell script picks up the invoking user
  #    (sudo preserves it by default).
  let currentUser = getEnv("USER", "")
  if currentUser.len == 0:
    return err("Cannot determine current user (USER environment variable is empty)")

  # Validate inputs before interpolating into a shell script run as root.
  # Only allow characters that are safe in POSIX paths and usernames.
  proc isShellSafe(s: string): bool =
    for c in s:
      if c notin {'a'..'z', 'A'..'Z', '0'..'9', '_', '-', '.', '/'}:
        return false
    return s.len > 0

  if not isShellSafe(currentUser):
    return err("USER contains unsafe characters: " & currentUser)
  if not isShellSafe(systemBpftrace):
    return err("bpftrace path contains unsafe characters: " & systemBpftrace)

  # Build the privileged setup script. Each step is joined with '&&' so
  # the script aborts on the first failure.
  let script = fmt2"""
mkdir -p {BpfInstallDir} && \
cp {systemBpftrace} {BpfBpftracePath} && \
(getent group {BpfGroupName} >/dev/null 2>&1 || groupadd {BpfGroupName}) && \
usermod -aG {BpfGroupName} {currentUser} && \
chown root:{BpfGroupName} {BpfBpftracePath} && \
chmod 750 {BpfBpftracePath} && \
setcap 'cap_bpf,cap_perfmon,cap_dac_read_search+ep' {BpfBpftracePath}
"""

  if not isShellSafe(sudoCommand):
    return err("sudo command contains unsafe characters: " & sudoCommand)

  echo "Setting up BPF process monitoring (requires " & sudoCommand & " access)..."

  try:
    let exitCode = execCmd(sudoCommand & " sh -c '" & script.strip() & "'")
    if exitCode != 0:
      return err(fmt2"BPF setup script failed with exit code {exitCode}")
  except OSError as e:
    return err("Failed to execute BPF setup: " & e.msg)

  echo "BPF process monitoring set up successfully."
  echo "Note: You may need to log out and back in for the group membership to take effect."
  return ok()
