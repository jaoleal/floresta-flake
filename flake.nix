# SPDX-License-Identifier: MIT OR Apache-2.0

{
  description = "Nix & Flake packaging support for the Floresta node and library";

  nixConfig = {
    extra-substituters = [ "https://floresta-flake.cachix.org" ];
    extra-trusted-public-keys = [
      "floresta-flake.cachix.org-1:FIb3n6oyT4vr8Fc4TvJNADQB/PFTHzB376Ho1P8xxP8="
    ];
  };

  outputs =
    inputs@{ flake-parts, ... }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = supportedSystems;

      flake = {
        nixosModules = {
          floresta = import ./lib/floresta-service.nix;
          default = inputs.self.nixosModules.floresta;
        };
      };

      perSystem =
        {
          pkgs,
          system,
          self',
          ...
        }:
        let
          inherit (pkgs) lib;

          # Upstream Floresta source — pinned via flake input, shared by
          # default builds, master builds, and Android cross-compilation.
          # Update with: nix flake update floresta-master
          masterSrc = inputs.floresta-master;

          fetchTag =
            rev: hash:
            pkgs.fetchFromGitHub {
              owner = "getfloresta";
              repo = "Floresta";
              inherit rev hash;
            };

          # Every Floresta tree this flake pins, keyed by the release it is.
          releaseSrcs = {
            master = masterSrc;
            v0_9_1 = fetchTag "v0.9.1" "sha256-5dfE0Bd0yCDh7Kc0PsSXjBWLQ9WmNCCbropdXfK9YSk=";
            v0_9_0 = fetchTag "v0.9.0" "sha256-8GXCHvk6xxT93c073W15L0+xpri8lQvIcIdDcPead8I=";
          };

          # The build library of each release, built from its source tree.
          releaseBuilds = lib.mapAttrs (
            _release: src:
            import ./lib/floresta-build.nix {
              inherit pkgs;
              defaultSrc = src;
            }
          ) releaseSrcs;

          # A release is its native build, with cross builds attached as
          # attributes: `.#master.aarch64-android`. Only master carries the
          # Android builds. Attached with // rather than passthru:
          # floresta-build.nix defines passthru.overrideAttrs
          # self-recursively, so overriding would rebuild the set.
          releases = lib.mapAttrs (
            release: build: build.default // lib.optionalAttrs (release == "master") androidPackages
          ) releaseBuilds;

          # Android outputs: one cross-compiled Floresta per ABI, keyed by it.
          # Only present on hosts that can drive the NDK.
          # See lib/android-outputs.nix.
          androidPackages = import ./lib/android-outputs.nix {
            inherit
              pkgs
              inputs
              system
              masterSrc
              ;
          };

          # Release attestation — see lib/attestation.nix.
          attestation = import ./lib/attestation.nix {
            inherit pkgs;
            # Tagged versions only
            releases = removeAttrs releases [ "master" ];
            trustedKeys = ./contrib/trusted-keys;
            sigs = ./contrib/sigs;
          };
        in
        {
          _module.args.pkgs = import inputs.nixpkgs { inherit system; };

          checks = {
            nix-sanity-check = inputs.pre-commit-hooks.lib.${system}.run {
              src = pkgs.lib.fileset.toSource {
                root = ./.;
                fileset = pkgs.lib.fileset.unions [
                  ./lib/android-outputs.nix
                  ./lib/attestation.nix
                  ./lib/floresta-build.nix
                  ./lib/floresta-service.nix
                  ./lib/floresta-service-eval-test.nix
                  ./lib/floresta-service-vm-test.nix
                  ./flake.nix
                  ./flake.lock
                ];
              };
              hooks = {
                nixfmt.enable = true;
                deadnix.enable = true;
                nil.enable = true;
                statix.enable = true;
              };
            };

            service-eval-test = import ./lib/floresta-service-eval-test.nix {
              inherit pkgs;
              flakeInputs = inputs;
            };

            # The same verifier `nix run .#verify` runs, against what is
            # committed.
            attestations = attestation.check;
          }
          // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
            service-vm-test = import ./lib/floresta-service-vm-test.nix {
              inherit pkgs;
              flakeInputs = inputs;
            };
          };

          packages =
            releases
            # attestation-manifest-<version>: the SHA256SUMS of one release.
            // lib.mapAttrs' (
              version: lib.nameValuePair "attestation-manifest-${version}"
            ) attestation.manifests;

          # The attestation verbs.
          apps = {
            verify.program = attestation.verify;
            attest.program = attestation.attest;
            releases.program = attestation.listReleases;
          };

          formatter = pkgs.nixfmt-classic;

          devShells.default = pkgs.mkShell {
            inherit (self'.checks.nix-sanity-check) shellHook;
            packages = with pkgs; [
              nil
              nixfmt
              just
              nix-output-monitor
              cachix
            ];
          };
        };
    };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    flake-parts.url = "github:hercules-ci/flake-parts";

    pre-commit-hooks = {
      url = "github:cachix/git-hooks.nix";
    };

    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Upstream Floresta with patched libbitcoinkernel-sys (>= 0.3.0).
    # Used for default native builds and Android cross-compilation.
    # Update with: nix flake update floresta-master
    floresta-master = {
      url = "github:jaoleal/FlorestaBA/android_patched_bitcoinkernel";
      flake = false;
    };
  };
}
