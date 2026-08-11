# SPDX-License-Identifier: MIT OR Apache-2.0

# Example consumer flake — shows how to use floresta-nix's build library
# and NixOS service module.
# Used in CI to verify the consumer integration interface.
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-utils.url = "github:numtide/flake-utils";
    floresta-nix.url = "path:../";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      floresta-nix,
      ...
    }:
    let
      # Per-system outputs (packages)
      perSystem = flake-utils.lib.eachDefaultSystem (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          florestaBuild = import "${floresta-nix}/lib/floresta-build.nix" { inherit pkgs; };
        in
        {
          packages = {
            # Everything Floresta publishes, from one build of the workspace.
            inherit (florestaBuild) default;

            # Or build a single component, or a variant, with mkFloresta.
            florestad = florestaBuild.mkFloresta { packageName = "florestad"; };

            florestad-debug = florestaBuild.mkFloresta {
              packageName = "florestad";
              profile = "debug";
            };
          };
        }
      );

      # NixOS service example (linux only)
      nixosExample =
        let
          pkgs = import nixpkgs { system = "x86_64-linux"; };
          florestaBuild = import "${floresta-nix}/lib/floresta-build.nix" { inherit pkgs; };
        in
        {
          nixosConfigurations.example = nixpkgs.lib.nixosSystem {
            system = "x86_64-linux";
            modules = [
              floresta-nix.nixosModules.floresta
              {
                services.floresta = {
                  enable = true;
                  package = florestaBuild.mkFloresta { packageName = "florestad"; };
                  network = "signet";
                  electrum.address = "127.0.0.1:50001";
                  rpc.address = "127.0.0.1:38332";
                };

                # Minimal config to make nixosSystem evaluate
                boot.loader.grub.devices = [ "nodev" ];
                fileSystems."/" = {
                  device = "none";
                  fsType = "tmpfs";
                };
                system.stateVersion = "25.05";
              }
            ];
          };
        };
    in
    perSystem // nixosExample;
}
