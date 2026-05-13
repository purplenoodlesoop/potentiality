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
    ];

    # Ship the task_* tool surface to Horizon. The fragment is
    # store-resident so it survives vault edits, and is hot-reloaded
    # by Horizon per event like any other allowlist.
    services.horizon.extraAllowlists = [ allowlistFragment ];

    # Drop the pot-tasks capability into the vault as a symlink to
    # the store. Type `L` means "create only if missing", so user
    # overrides (a regular file replacing the symlink) survive
    # rebuilds. To bump the capability prose, remove the file and
    # rebuild — the symlink reappears pointing at the new store
    # path.
    systemd.tmpfiles.rules = lib.optional cfg.installCapability
      "L ${cfg.vault}/_horizon/capabilities/pot-tasks.md - ${cfg.capabilityOwner} ${cfg.capabilityGroup} - ${capabilityFile}";
  };
}
