# 09 — Provisioning

Potentiality is provisioned via Nix using [`purplenoodlesoop/core-flake`](https://github.com/purplenoodlesoop/core-flake). This matches Horizon's distribution pattern.

## What `core-flake` provides

(Verified by reading `flake.nix` in `core-flake` at the May 2026 head.)

Self-description: "Abstractions for Nix flake development."

License: MIT. Default branch: `master`. Pure Nix (~10 KB), no flake-parts dependency. Inputs:

- `nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable"`
- `flake-utils.url = "github:numtide/flake-utils"`

Exposed surface:

| Output | Type | Purpose |
|---|---|---|
| `lib.evalFlake { overlays, topLevel, perSystem }` | function | Wrapper around `flake-utils.lib.eachDefaultSystem` with structured args |
| `nixosModules.tasks` | module | (TBD — read content before using) |
| `nixosModules.compose` | module | (TBD — read content before using) |
| `overlays.fvm` | overlay | Flutter Version Manager — not relevant to Haskell builds |
| `templates.default` | template | `nix flake init -t github:purplenoodlesoop/core-flake` scaffolds a new flake |

The user's existing Horizon flake uses `core-flake` (per `flake.nix` in Horizon). Potentiality adopts the same input pattern.

## Potentiality's `flake.nix`

```nix
{
  description = "Potentiality — Haskell agent runner over a markdown vault.";

  inputs = {
    core-flake.url = "github:purplenoodlesoop/core-flake";
    nixpkgs.follows = "core-flake/nixpkgs";
    flake-utils.follows = "core-flake/flake-utils";
  };

  outputs =
    { core-flake, nixpkgs, ... }:
    core-flake.lib.evalFlake {
      overlays = [
        # haskell toolchain pin if needed; otherwise rely on nixpkgs.haskellPackages
      ];
      perSystem.imports = [
        ./nix/package.nix
        ./nix/devshell.nix
      ];
      topLevel.nixosModules.potentiality = ./nix/module.nix;
    };
}
```

## Files in `nix/`

### `nix/package.nix`

Builds the `pot` binary from the cabal project. Default to `pkgs.haskell.packages.${ghcVersion}.callCabal2nix`, with `--enable-static` for portability if practical.

```nix
{ pkgs, ... }:
{
  packages.default = pkgs.haskell.packages.ghc964.callCabal2nix "potentiality" ../. { };
  apps.default = {
    type = "app";
    program = "${pkgs.haskell.packages.ghc964.callCabal2nix "potentiality" ../. { }}/bin/pot";
  };
}
```

GHC version pin: 9.6.4 or whatever the user's nixpkgs unstable currently ships. Bumping is a deliberate change.

### `nix/devshell.nix`

Development shell with cabal, HLS, formatter, and `claude` CLI on PATH for integration tests.

```nix
{ pkgs, ... }:
{
  devShells.default = pkgs.mkShell {
    buildInputs = with pkgs; [
      haskell.compiler.ghc964
      cabal-install
      haskellPackages.haskell-language-server
      fourmolu
      hlint
      claude-code  # if packaged; otherwise install via npm or direct download
    ];
  };
}
```

### `nix/module.nix`

NixOS user-service module. Declares a systemd-user service that runs `pot do watch` against a configured vault.

```nix
{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.services.potentiality;
in
{
  options.services.potentiality = {
    enable = mkEnableOption "Potentiality agent runner";
    vault = mkOption {
      type = types.path;
      description = "Path to the Markdown vault to watch.";
    };
    maxConcurrent = mkOption {
      type = types.int;
      default = 3;
    };
    maxCostUsdPerDay = mkOption {
      type = types.nullOr types.number;
      default = null;
    };
    package = mkOption {
      type = types.package;
      default = pkgs.potentiality;
    };
  };

  config = mkIf cfg.enable {
    systemd.user.services.potentiality = {
      description = "Potentiality agent runner";
      wantedBy = [ "default.target" ];
      serviceConfig = {
        ExecStart = ''
          ${cfg.package}/bin/pot do watch ${cfg.vault} \
            --max-concurrent ${toString cfg.maxConcurrent} \
            ${optionalString (cfg.maxCostUsdPerDay != null)
              "--max-cost-usd-per-day ${toString cfg.maxCostUsdPerDay}"}
        '';
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
  };
}
```

User configures in their NixOS / home-manager config:

```nix
services.potentiality = {
  enable = true;
  vault = "/home/yakov/vault";
  maxCostUsdPerDay = 25;
};
```

## Install paths

| Channel | Command |
|---|---|
| Run latest from main | `nix run github:purplenoodlesoop/potentiality -- do run vault/tasks/.../task.md` |
| Add to a flake | `inputs.potentiality.url = "github:purplenoodlesoop/potentiality";` then reference `potentiality.packages.${system}.default` |
| NixOS user-service | Import `potentiality.nixosModules.potentiality`, set `services.potentiality.enable = true;` |
| Dev shell | `nix develop github:purplenoodlesoop/potentiality` |

## Runtime dependencies

`pot` requires the `claude` binary on `$PATH`. The Nix module SHOULD add `pkgs.claude-code` (or whatever the upstream package name is) to the service's PATH explicitly to avoid relying on the user's profile.

`pot` also requires:

- `git` (commits frontmatter mutations)
- inotify (Linux) / kqueue (macOS) — provided by the libc

## Versioning

- The binary version is read from `cabal` (`pot --version` prints semver).
- Schema version in `task.md` frontmatter is independent: starts at `schema: 1`. Breaking changes bump it; `pot` refuses to operate on unknown future versions.
- Flake input pins are managed by `flake.lock`; commits to `core-flake` are picked up via `nix flake update`.
