{
  pkgs ? import <nixpkgs> { },
  lib ? pkgs.lib,
}:

let
  inherit (lib) types mkOption;

  buildFlorestaOptions = {
    options = {
      packageName = mkOption {
        type = types.enum [
          "all"
          "libfloresta"
          "florestad"
          "floresta-cli"
          "floresta-debug"
        ];
        default = "all";
        description = lib.mdDoc ''
          Which floresta package variant to build.

          - `all`: Builds all components (CLI, Node and lib)
          - `libfloresta`: Only the Floresta library
          - `florestad`: Only the Floresta Node
          - `floresta-cli`: Only the CLI tool
          - `floresta-debug`: CLI and Node with Debug profile
        '';
        example = "florestad";
      };

      src = mkOption {
        type = types.path;
        default = pkgs.fetchFromGitHub {
          rev = "master";
          owner = "vinteumorg";
          repo = "floresta";
          hash = "sha256-93piWE61HSAKOSGws6s9+ooqV0g1glCwr/HVHjGz1y0=";
        };
        description = lib.mdDoc ''
          Source tree for the Floresta project.

          By default, fetches the latest master branch from GitHub.
          Can be overridden to use a local checkout or specific revision.
        '';
        example = lib.literalExpression ''
          pkgs.fetchFromGitHub {
            owner = "vinteumorg";
            repo = "floresta";
            rev = "v0.5.0";
            hash = "sha256-... ";
          }
        '';
      };

      features = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = lib.mdDoc ''
          Additional cargo features to enable during build.

          These are passed directly to `cargo build --features`.

          The examples shows all feature options, including Node and Libraries features.
        '';
        example = [
          "zmq-server"
          "metricss"
          "tokio-console"
          "experimental"
          "json-rpc"
          "bitcoinconsensus"
          "test-utils"
          "flat-chainstore"
          "std"
          "descriptors-std"
          "descriptors-no-std"
          "clap"
          "bitcoinconsensus"
          "watch-only-wallet"
          "memory-database"
        ];
      };

      extraBuildInputs = mkOption {
        type = types.listOf types.package;
        default = [ ];
        description = lib.mdDoc ''
          Inputs to be included during build time of floresta.
        '';
      };

      doCheck = mkOption {
        type = types.bool;
        default = true;
        description = lib.mdDoc ''
          Whether to run tests during the build, deactivate if youre limited on resources.

          Only offline tests are executed.
        '';
      };
    };
  };

  # Evaluate the module to get the final configuration
  evalConfig =
    config:
    let
      evaluated = lib.evalModules {
        modules = [
          buildFlorestaOptions
          { inherit config; }
        ];
      };
    in
    evaluated.config;

  # Package-specific configurations
  packageConfigs = {
    all = {
      pname = "floresta";
      cargoBuildFlags = [ ];
      description = "Floresta packages, CLI and Node";
      cargoTomlPath = "bin/florestad/Cargo.toml";
    };

    libfloresta = {
      pname = "libfloresta";
      cargoBuildFlags = [ "--lib" ];
      description = "Floresta library";
      cargoTomlPath = "crates/floresta/Cargo.toml";
    };

    florestad = {
      pname = "florestad";
      cargoBuildFlags = [
        "--bin"
        "florestad"
      ];
      description = "Floresta Node";
      cargoTomlPath = "bin/florestad/Cargo.toml";
    };

    floresta-cli = {
      pname = "floresta-cli";
      cargoBuildFlags = [
        "--bin"
        "floresta-cli"
      ];
      description = "Floresta CLI";
      cargoTomlPath = "bin/floresta-cli/Cargo.toml";
    };

    floresta-debug = {
      pname = "floresta-debug";
      cargoBuildFlags = [ ];
      description = "Floresta in debug profile";
      cargoTomlPath = "bin/florestad/Cargo.toml";
      extraFeatures = [ "metrics" ];
    };
  };

  # Main builder function
  mkFloresta =
    args:
    let
      # Evaluate and validate the configuration
      cfg = evalConfig args;

      # Get the config for the requested package
      pkgConfig = packageConfigs.${cfg.packageName};

      # Read version from appropriate Cargo.toml
      cargoToml = builtins.fromTOML (builtins.readFile "${cfg.src}/${pkgConfig.cargoTomlPath}");

      # Well problably need that in the future
      darwinDeps = [ ];
      windowsDeps = [ ];
    in
    pkgs.rustPlatform.buildRustPackage {
      inherit (cargoToml.package) version;
      inherit (pkgConfig) pname description cargoBuildFlags;
      inherit (cfg) src doCheck;

      # Build the final features list
      buildFeatures = cfg.features ++ (cfg.extraFeatures or [ ]);

      # Platform-specific dependencies
      nativeBuildInputs = [
        pkgs.openssl
        pkgs.pkg-config
        pkgs.boost
        pkgs.cmake
        pkgs.llvmPackages.clang
        pkgs.llvmPackages.libclang
      ]
      ++ lib.optionals pkgs.hostPlatform.isDarwin darwinDeps
      ++ lib.optionals pkgs.hostPlatform.isWindows windowsDeps
      ++ cfg.extraBuildInputs;

      cargoLock = {
        lockFile = "${cfg.src}/Cargo.lock";
      };

      # Bitcoin Kernel needs these
      LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
      CMAKE_PREFIX_PATH = "${pkgs.boost.dev}";

      cargoDeps = pkgs.rustPlatform.importCargoLock { lockFile = "${cfg.src}/Cargo.lock"; };

      checkFlags = [
        # These tests has special needs that nix cant provide.
        "--skip=tests::test_get_block_header"
        "--skip=tests::test_get_block"
        "--skip=tests::test_get_block_hash"
        "--skip=tests::test_get_best_block_hash"
        "--skip=tests::test_get_blockchaininfo"
        "--skip=tests::test_stop"
        "--skip=tests::test_get_roots"
        "--skip=tests::test_get_height"
        "--skip=tests::test_send_raw_transaction"
        "--skip=p2p_wire::node::tests::test_parse_address"
      ];

      meta = with lib; {
        description = "A lightweight bitcoin full node - ${pkgConfig.description}";
        homepage = "https://github.com/vinteumorg/Floresta";
        license = licenses.mit;
        maintainers = with maintainers; [ jaoleal ];
        platforms = platforms.unix ++ platforms.windows;
        mainProgram = pkgConfig.pname;
      };

      # Override options
      passthru = {
        inherit cfg pkgConfig;

        override = newArgs: mkFloresta (cfg // newArgs);
        overrideAttrs = f: (mkFloresta args).overrideAttrs f;
      };
    };

in
# Export both the builder and a default build
{
  # The main builder function
  build = mkFloresta;

  # Convenience:  default package
  default = mkFloresta { };

  # Convenience: pre-configured variants
  florestad = mkFloresta { packageName = "florestad"; };
  floresta-cli = mkFloresta { packageName = "floresta-cli"; };
  libfloresta = mkFloresta { packageName = "libfloresta"; };
  floresta-debug = mkFloresta { packageName = "floresta-debug"; };

  # For documentation generation
  inherit buildFlorestaOptions;
}
