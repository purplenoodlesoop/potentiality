{ config, lib, pkgs, ... }:

let
  cfg = config.services.potentiality;
in
{
  options.services.potentiality = {
    enable = lib.mkEnableOption "Potentiality agent runner (`pot do watch`)";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.potentiality or null;
      defaultText = lib.literalExpression "pkgs.potentiality";
      description = ''
        The `pot` package to run. `pkgs.potentiality` is only present if
        the flake's overlay is applied; otherwise set this explicitly,
        e.g. `inputs.potentiality.packages.''${pkgs.system}.default`.
      '';
    };

    vault = lib.mkOption {
      type = lib.types.str;
      example = "/home/yakov/vault";
      description = ''
        Absolute path to the Markdown vault to watch. Must be a writable
        runtime directory — do NOT use a Nix path literal, since that
        would copy the vault into the store.
      '';
    };

    maxConcurrent = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3;
      description = "Maximum concurrent tasks the watcher will claim.";
    };

    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      example = lib.literalExpression "[ pkgs.git pkgs.claude-code ]";
      description = ''
        Packages prepended to the service's `PATH`. `pot` requires
        `claude` and `git` at runtime; the systemd user service runs
        with a minimal `PATH` and must be told where to find them.
      '';
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/run/secrets/potentiality.env";
      description = ''
        Systemd `EnvironmentFile=` for credentials, e.g. a file
        containing `CLAUDE_CODE_OAUTH_TOKEN=…` or
        `ANTHROPIC_API_KEY=…`. Must be readable by the service user.
      '';
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Extra flags passed to `pot do watch`. Only the flags actually
        implemented by the binary work here — `--vault` and
        `--max-concurrent` are already set by the module.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.package != null;
        message = ''
          services.potentiality.package is not set and `pkgs.potentiality`
          is not in scope. Set it explicitly, e.g.
            services.potentiality.package = inputs.potentiality.packages.''${pkgs.system}.default;
        '';
      }
      {
        assertion = lib.hasPrefix "/" cfg.vault;
        message = "services.potentiality.vault must be an absolute path.";
      }
    ];

    systemd.user.services.potentiality = {
      description = "Potentiality agent runner";
      wantedBy = [ "default.target" ];

      path = cfg.extraPackages;

      environment = {
        POTENTIALITY_VAULT = cfg.vault;
      };

      serviceConfig = {
        ExecStart = lib.concatStringsSep " " (
          [
            (lib.getExe cfg.package)
            "do" "watch"
            "--vault" (lib.escapeShellArg cfg.vault)
            "--max-concurrent" (toString cfg.maxConcurrent)
          ]
          ++ map lib.escapeShellArg cfg.extraArgs
        );

        Restart = "on-failure";
        RestartSec = 5;
      } // lib.optionalAttrs (cfg.environmentFile != null) {
        EnvironmentFile = cfg.environmentFile;
      };
    };
  };
}
