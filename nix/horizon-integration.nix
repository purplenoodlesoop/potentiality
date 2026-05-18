{ config, lib, pkgs, ... }:

let
  cfg = config.services.potentiality.horizon;
  allowlistFragment = ./horizon/allowlist.yaml;
  capabilityFile = ./horizon/capabilities/pot-tasks.md;
in
{
  options.services.potentiality.horizon = {
    enable = lib.mkEnableOption ''
      Pot ↔ Horizon integration: ship the task_* tool surface
      to Horizon via --extra-allowlist and (optionally) place the
      pot-tasks capability into Horizon's vault.
    '';

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = config.services.potentiality.package or null;
      defaultText = lib.literalExpression "config.services.potentiality.package";
      description = ''
        The Pot package to make available on Horizon's PATH. Defaults
        to `services.potentiality.package` so the daemon and the
        chat-side bash tools resolve to the same binary. Required —
        the integration is non-functional without `pot` reachable
        from Horizon's service.
      '';
    };

    installCapability = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Place `pot-tasks.md` into Horizon's vault on activation via
        a systemd-tmpfiles symlink to the store path. The symlink is
        created only if the destination does not exist, so user
        edits (a regular file at the same path) take precedence and
        survive rebuilds.

        Set to false to manage the capability file yourself (e.g.
        copy a customized version into the vault by hand).
      '';
    };

    vault = lib.mkOption {
      type = lib.types.str;
      default = config.services.horizon.vault or "/var/lib/horizon/vault";
      defaultText = lib.literalExpression ''config.services.horizon.vault'';
      description = ''
        Vault path where the capability file should be placed. Defaults
        to `services.horizon.vault` so the two modules stay in sync.
      '';
    };

    capabilityOwner = lib.mkOption {
      type = lib.types.str;
      default = config.services.horizon.user or "horizon";
      defaultText = lib.literalExpression ''config.services.horizon.user'';
      description = "User the capability symlink is created as.";
    };

    capabilityGroup = lib.mkOption {
      type = lib.types.str;
      default = config.services.horizon.group or "horizon";
      defaultText = lib.literalExpression ''config.services.horizon.group'';
      description = "Group the capability symlink is created as.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.services.horizon.enable or false;
        message = ''
          services.potentiality.horizon.enable requires
          services.horizon.enable. Enable Horizon's NixOS module
          (inputs.horizon.nixosModules.default) and set
          services.horizon.enable = true; first.
        '';
      }
      {
        assertion = cfg.package != null;
        message = ''
          services.potentiality.horizon.package must be set so the
          `pot` binary is on Horizon's service PATH. Set it
          explicitly, or enable services.potentiality so its
          .package option provides a default.
        '';
      }
    ];

    # Ship the task_* tool surface to Horizon. The fragment is
    # store-resident so it survives vault edits, and is hot-reloaded
    # by Horizon per event like any other allowlist.
    services.horizon.extraAllowlists = [ allowlistFragment ];

    # Make `pot` reachable from Horizon's bash subprocesses so the
    # task_* tools can shell out. NixOS service paths default to a
    # set of standard utilities only — `pot` is in the system
    # profile but not the service's PATH unless we add it here.
    services.horizon.extraPath = [ cfg.package ];

    # Drop the pot-tasks capability into the vault as a symlink to
    # the store. Type `L` means "create only if missing", so user
    # overrides (a regular file replacing the symlink) survive
    # rebuilds. To bump the capability prose, remove the file and
    # rebuild — the symlink reappears pointing at the new store
    # path.
    #
    # Cross-user filesystem-permissions note: when pot's spawn user
    # differs from Horizon's service user (the common setup — pot
    # spawns Claude as the operator's login user so credentials like
    # `gh auth` and `wrangler` are inherited, while Horizon runs as
    # the `horizon` service user that owns the vault), the spawned
    # agent will be unable to write to vault subdirectories that are
    # owned by the Horizon group without group-write. See
    # `spec/08-chat-client-integration.md` §5 — the recommended
    # convention is a shared group with `chmod g+ws` on subdirs the
    # agent is expected to modify (e.g. `todos/`, `people/`,
    # `journal/`). This module does not configure those permissions
    # itself because the right set is deployment-specific.
    systemd.tmpfiles.rules = lib.optional cfg.installCapability
      "L ${cfg.vault}/_horizon/capabilities/pot-tasks.md - ${cfg.capabilityOwner} ${cfg.capabilityGroup} - ${capabilityFile}";
  };
}
