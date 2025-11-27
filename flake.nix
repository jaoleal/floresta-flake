{
  description = "Nix & Flake packaging support for the Floresta node and library";

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      pre-commit-hooks,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };

        florestaBuild = import ./lib/floresta-build.nix { inherit pkgs; };
      in
      with pkgs;
      {
        checks.nix-sanity-check = pre-commit-hooks.lib.${system}.run {
          src = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./lib/floresta-build.nix
              ./flake.nix
              ./flake.lock
            ];
          };
          hooks = {
            nixfmt-rfc-style.enable = true;
            statix.enable = true;
            flake-checker.enable = true;
          };
        };
        lib = { inherit florestaBuild; };
        packages = {
          inherit (florestaBuild)
            florestad
            floresta-cli
            libfloresta
            floresta-debug
            default
            ;
        };
      }
    )
    // {
      # Without defined pkgs
      lib = {
        florestaBuild = import ./floresta-build.nix;
      };
    };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

    flake-utils.url = "github:numtide/flake-utils";

    pre-commit-hooks.url = "github:cachix/git-hooks.nix";
  };
}
