# NixOS module for CodeTracer developer BPF setup.
#
# Grants passwordless `sudo setcap` on the ct binary built from a local
# source checkout, so the tup build rule (`!codetracer_bpf` in Tuprules.tup)
# can automatically re-apply BPF capabilities after each recompilation.
#
# Linux file capabilities (xattrs) are stored per-inode and lost whenever
# the binary is overwritten. This module:
#   1. Installs a single-purpose `codetracer-setcap` script on PATH that
#      runs setcap with hardcoded capabilities on the hardcoded ct binary.
#   2. Adds a sudoers rule allowing the developer to run it passwordlessly.
#
# The tup build rule calls `sudo -n codetracer-setcap` after compilation.
#
# Usage in your NixOS configuration (e.g. ~/dotfiles):
#
#   imports = [ codetracer.nixosModules.developer-bpf ];
#
#   programs.codetracer.developer-bpf = {
#     enable = true;
#     user = "myuser";
#     repoPath = "/home/myuser/metacraft/codetracer";
#   };

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.codetracer.developer-bpf;
  ctBinPath = "${cfg.repoPath}/src/build-debug/bin/ct";
  capabilities = "cap_bpf,cap_perfmon,cap_dac_read_search=eip";

  # Single-purpose helper that applies BPF capabilities to the ct binary.
  # Installed on PATH as `codetracer-setcap`. The sudoers rule allows
  # running it via sudo without a password.
  setcapHelper = pkgs.writeShellScriptBin "codetracer-setcap" ''
    exec ${pkgs.libcap}/bin/setcap '${capabilities}' '${ctBinPath}'
  '';
in
{
  options.programs.codetracer.developer-bpf = {
    enable = lib.mkEnableOption "passwordless setcap for CodeTracer developer builds";

    user = lib.mkOption {
      type = lib.types.str;
      description = ''
        Username allowed to run passwordless setcap on the ct binary.
        This is the developer who builds CodeTracer from source.
      '';
      example = "zahary";
    };

    repoPath = lib.mkOption {
      type = lib.types.str;
      description = ''
        Absolute path to the CodeTracer repository checkout.
        The ct binary is expected at <repoPath>/src/build-debug/bin/ct.
      '';
      example = "/home/zahary/metacraft/codetracer";
    };
  };

  config = lib.mkIf cfg.enable {
    # Put codetracer-setcap on PATH so the tup build rule can find it.
    environment.systemPackages = [ setcapHelper ];

    # Scoped sudoers rule: allows ONLY the codetracer-setcap helper.
    # The helper itself only runs setcap with fixed capabilities on the
    # fixed ct binary path — no other binary can be targeted.
    security.sudo.extraRules = [
      {
        users = [ cfg.user ];
        commands = [
          {
            command = "${setcapHelper}/bin/codetracer-setcap";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];
  };
}
