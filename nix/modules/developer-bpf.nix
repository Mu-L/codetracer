# NixOS module for CodeTracer developer BPF setup.
#
# Grants passwordless `sudo setcap` on the ct binary built from a local
# source checkout, so the tup build rule (`!codetracer_bpf` in Tuprules.tup)
# can automatically re-apply BPF capabilities after each recompilation.
#
# Linux file capabilities (xattrs) are stored per-inode and lost whenever
# the binary is overwritten. This module creates a scoped sudoers rule
# that allows the developer to run setcap without a password, but ONLY
# on the specific ct binary path — no wildcards, no other binaries.
#
# Usage in your NixOS configuration (e.g. ~/dotfiles):
#
#   imports = [ /path/to/codetracer/nix/modules/developer-bpf.nix ];
#   # Or via the flake:
#   #   imports = [ codetracer.nixosModules.developer-bpf ];
#
#   programs.codetracer.developer-bpf = {
#     enable = true;
#     user = "myuser";
#     repoPath = "/home/myuser/metacraft/codetracer";
#   };
#
# This is separate from the end-user NixOS module (nixos-module.nix) which
# manages the installed package and bpftrace security.wrappers.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.codetracer.developer-bpf;
  setcapBin = "${pkgs.libcap}/bin/setcap";
  ctBinPath = "${cfg.repoPath}/src/build-debug/bin/ct";
  capabilities = "cap_bpf,cap_perfmon,cap_dac_read_search=eip";
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
    # Scoped sudoers rule: allows ONLY this exact setcap invocation.
    # The tup build rule runs `sudo -n setcap '...' <path>` after
    # compiling ct. With this rule, that sudo call succeeds without
    # a password prompt.
    security.sudo.extraRules = [
      {
        users = [ cfg.user ];
        commands = [
          {
            command = "${setcapBin} ${capabilities} ${ctBinPath}";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];
  };
}
