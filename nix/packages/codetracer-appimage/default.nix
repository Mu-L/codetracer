# Nix package for the CodeTracer AppImage distribution.
#
# This wraps the pre-built AppImage with proper desktop integration and
# bundles a copy of bpftrace for capabilities-based BPF process monitoring.
#
# For NixOS systems, use the companion nixos-module.nix to configure
# security.wrappers for bpftrace capabilities instead of manual setcap.
#
# Usage:
#   nix-build -E 'with import <nixpkgs> {}; callPackage ./default.nix {}'
#
# Or via the flake:
#   nix build .#codetracer-appimage

{
  lib,
  fetchurl,
  appimageTools,
  makeWrapper,
  bpftrace,
}:

let
  pname = "codetracer";
  version = "latest"; # Parameterized at build time or by the CI pipeline.

  src = fetchurl {
    url = "https://downloads.codetracer.com/CodeTracer-latest-amd64.AppImage";
    # Hash must be filled in by the build pipeline or manually after download.
    hash = lib.fakeHash;
  };

  extracted = appimageTools.extractType2 { inherit pname version src; };
in
appimageTools.wrapType2 {
  inherit pname version src;

  extraInstallCommands = ''
    # Install desktop file and icons from the extracted AppImage.
    install -Dm644 ${extracted}/codetracer.desktop \
      $out/share/applications/codetracer.desktop

    # Fix Exec path in the desktop file to point to the Nix store binary.
    substituteInPlace $out/share/applications/codetracer.desktop \
      --replace "Exec=ct edit %F" "Exec=$out/bin/codetracer edit %F"

    # Create the ct symlink that users expect.
    ln -s $out/bin/codetracer $out/bin/ct

    # Install bpftrace alongside the package. On NixOS, the nixos-module
    # sets capabilities via security.wrappers. On non-NixOS systems,
    # the user can manually setcap or rely on the ct install --bpf flow.
    mkdir -p $out/libexec
    cp ${bpftrace}/bin/bpftrace $out/libexec/codetracer-bpftrace
  '';

  meta = with lib; {
    description = "Record/replay debugger with CI integration and BPF process monitoring";
    homepage = "https://codetracer.com";
    license = licenses.unfree;
    maintainers = [ ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "ct";
  };
}
