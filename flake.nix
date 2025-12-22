{
  description = "Nix & Flake packaging support for the Floresta node and library";

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      perSystem =
        {
          pkgs,
          system,
          self',
          ...
        }:
        {
          _module.args.pkgs = import inputs.nixpkgs { inherit system; };

          checks.nix-sanity-check = inputs.pre-commit-hooks.lib.${system}.run {
            src = pkgs.lib.fileset.toSource {
              root = ./.;
              fileset = pkgs.lib.fileset.unions [
                ./lib/floresta-build.nix
                # ./lib/floresta-service.nix
                ./flake.nix
                ./flake.lock
              ];
            };
            hooks = {
              nixfmt-rfc-style.enable = true;
              deadnix.enable = true;
              nil.enable = true;
              statix.enable = true;
              flake-checker.enable = true;
            };
          };

          packages =
            let
              florestaBuild = import ./lib/floresta-build.nix { inherit pkgs; };
            in
            {
              inherit (florestaBuild)
                florestad
                floresta-cli
                libfloresta
                floresta-debug
                default
                ;
            };

          devShells.default = pkgs.mkShell {
            inherit (self'.checks.nix-sanity-check) shellHook;
            packages = with pkgs; [
              nil
              nixfmt-rfc-style
            ];
          };
        };

      flake = {
        # Without defined pkgs
        lib = {
          florestaBuild = import ./lib/floresta-build.nix;
        };
      };
    };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

    flake-parts.url = "github:hercules-ci/flake-parts";

    pre-commit-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
}
