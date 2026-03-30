# NixOS module for CodeTracer with BPF process monitoring.
#
# Provides declarative configuration for the CodeTracer package and optional
# BPF capabilities setup via NixOS's security.wrappers mechanism.
#
# When ``programs.codetracer.bpf.enable`` is true (the default), a
# capabilities-aware bpftrace wrapper is installed at
# ``/run/wrappers/bin/codetracer-bpftrace`` with ``cap_bpf``,
# ``cap_perfmon``, and ``cap_dac_read_search`` capabilities.
# Only members of the configured group (default: ``codetracer-bpf``)
# can execute it.
#
# Usage in configuration.nix:
#   imports = [ ./path/to/nixos-module.nix ];
#   programs.codetracer.enable = true;
#   # Optionally add users to the BPF group:
#   users.users.myuser.extraGroups = [ "codetracer-bpf" ];
#
# See also:
#   https://www.kernel.org/doc/html/latest/bpf/bpf_design_QA.html#q-what-is-cap-bpf
#   https://nixos.wiki/wiki/Security#Wrappers

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.codetracer;
  codetracerPkg = cfg.package;
in
{
  options.programs.codetracer = {
    enable = lib.mkEnableOption "CodeTracer record/replay debugger";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.codetracer or (throw "codetracer package not found in pkgs; add it to your overlay");
      defaultText = lib.literalExpression "pkgs.codetracer";
      description = "The CodeTracer package to install.";
    };

    bpf.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Enable BPF process monitoring support via security.wrappers.

        When enabled, a capabilities-aware bpftrace binary is installed at
        /run/wrappers/bin/codetracer-bpftrace. Members of the configured
        group can run it without sudo.
      '';
    };

    bpf.group = lib.mkOption {
      type = lib.types.str;
      default = "codetracer-bpf";
      description = ''
        Unix group allowed to use the BPF monitoring wrapper.
        Users must be added to this group to use process monitoring
        without sudo.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ codetracerPkg ];

    users.groups.${cfg.bpf.group} = lib.mkIf cfg.bpf.enable { };

    # Install a capabilities-aware bpftrace wrapper via NixOS's
    # security.wrappers mechanism. This is the NixOS-idiomatic way
    # to grant capabilities without setuid or manual setcap.
    # See: https://nixos.org/manual/nixos/stable/#sec-security-wrappers
    security.wrappers.codetracer-bpftrace = lib.mkIf cfg.bpf.enable {
      source = "${pkgs.bpftrace}/bin/bpftrace";
      capabilities = "cap_bpf,cap_perfmon,cap_dac_read_search+ep";
      owner = "root";
      group = cfg.bpf.group;
      permissions = "u+rx,g+rx,o-rwx";
    };
  };
}
