# SPDX-License-Identifier: MIT OR Apache-2.0

{
  pkgs ? import <nixpkgs> { },
  lib ? pkgs.lib,
  # Source tree every build defaults to; standalone imports fall back to
  # the latest release tag.
  defaultSrc ? pkgs.fetchFromGitHub {
    owner = "getfloresta";
    repo = "Floresta";
    rev = "v0.9.1";
    hash = "sha256-5dfE0Bd0yCDh7Kc0PsSXjBWLQ9WmNCCbropdXfK9YSk=";
  },
  # Extra environment variables set on buildRustPackage (e.g. ANDROID_NDK_HOME)
  extraEnvVars ? { },
  # Extra native build inputs added to every build (e.g. Android SDK)
  extraNativeBuildInputsGlobal ? [ ],
  # When true, disable cargoBuildHook and use customBuildPhase instead.
  # Required for Android cross-compilation where cargo must be invoked
  # with an explicit --target flag.
  dontCargoBuild ? false,
  # Custom buildPhase used when dontCargoBuild is true (e.g. Android).
  customBuildPhase ? null,
  # Custom installPhase used when dontCargoBuild is true (e.g. Android).
  customInstallPhase ? null,
  # Override the Rust platform (rustc + cargo + rust-std).  Defaults to
  # pkgs.rustPlatform.  For Android cross-compilation a fenix-based
  # platform with the target's rust-std must be supplied.
  rustPlatform ? pkgs.rustPlatform,
  # Appended to every package name produced by this import, to tell cross
  # variants apart in the store: an Android import passes "-aarch64-android"
  # and gets `floresta-aarch64-android`.
  pnameSuffix ? "",
}:

let
  inherit (lib) types mkOption;

  # Option definitions for the build module
  buildFlorestaOptions = {
    options = {
      packageName = mkOption {
        type = types.enum [
          "all"
          "libfloresta"
          "florestad"
          "floresta-cli"
        ];
        default = "all";
        description = ''
          Which floresta package variant to build.

          - `all`: Builds all components (CLI, Node and lib)
          - `libfloresta`: Only the Floresta library
          - `florestad`: Only the Floresta Node
          - `floresta-cli`: Only the CLI tool
        '';
        example = "florestad";
      };

      profile = mkOption {
        type = types.enum [
          "release"
          "debug"
        ];
        default = "release";
        description = ''
          Cargo profile to build with.

          `debug` keeps assertions and debug info, at the cost of a much
          slower binary.  Ignored by cross builds that drive cargo through a
          custom build phase.
        '';
        example = "debug";
      };

      src = mkOption {
        type = types.path;
        default = defaultSrc;
        description = ''
          Source tree for the Floresta project.

          Defaults to whatever the import was given as `defaultSrc` — the
          latest release tag, for a standalone import. Can be overridden to
          use a local checkout or specific revision.
        '';
        example = ''
          pkgs.fetchFromGitHub {
            owner = "getfloresta";
            repo = "Floresta";
            rev = "v0.9.1";
            hash = "sha256-... ";
          }
        '';
      };

      features = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
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
        description = ''
          Inputs to be included during build time of floresta.
        '';
      };

      doCheck = mkOption {
        type = types.bool;
        default = false;
        description = ''
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

  # Package-specific configurations.  `mainProgram` is the binary the package
  # is run as, which is not the package name for the workspace build: it
  # installs florestad and floresta-cli, and nothing called floresta.
  packageConfigs = {
    all = {
      pname = "floresta";
      cargoBuildFlags = [ ];
      description = "Floresta node, CLI and library";
      cargoTomlPath = "bin/florestad/Cargo.toml";
      mainProgram = "florestad";
    };

    libfloresta = {
      pname = "libfloresta";
      cargoBuildFlags = [ "--lib" ];
      description = "Floresta library";
      cargoTomlPath = "crates/floresta/Cargo.toml";
      mainProgram = null;
    };

    florestad = {
      pname = "florestad";
      cargoBuildFlags = [
        "--bin"
        "florestad"
      ];
      description = "Floresta Node";
      cargoTomlPath = "bin/florestad/Cargo.toml";
      mainProgram = "florestad";
    };

    floresta-cli = {
      pname = "floresta-cli";
      cargoBuildFlags = [
        "--bin"
        "floresta-cli"
      ];
      description = "Floresta CLI";
      cargoTomlPath = "bin/floresta-cli/Cargo.toml";
      mainProgram = "floresta-cli";
    };
  };

  # Main builder function
  mkFloresta =
    args:
    let
      cfg = evalConfig args;
      pkgConfig = packageConfigs.${cfg.packageName};
      cargoToml = builtins.fromTOML (builtins.readFile "${cfg.src}/${pkgConfig.cargoTomlPath}");

      # Darwin libraries linked into the target binary.  The Security and
      # SystemConfiguration frameworks used to be listed here explicitly;
      # since the nixpkgs Darwin SDK rework they ship with the default
      # `apple-sdk` that the Darwin stdenv already provides.
      darwinInputs = [ pkgs.libiconv ];

      inherit (pkgs.stdenv) targetPlatform;
    in
    rustPlatform.buildRustPackage (
      {
        inherit (cargoToml.package) version;
        inherit (pkgConfig) description cargoBuildFlags;
        inherit (cfg) src doCheck;

        # The profile is part of the name: a debug build of a release is a
        # different derivation of the same version, and two store paths that
        # differ only by a hash are not worth telling apart by hand.
        pname =
          pkgConfig.pname + pnameSuffix + lib.optionalString (cfg.profile != "release") "-${cfg.profile}";
        buildType = cfg.profile;
        buildFeatures = cfg.features;

        # Build-time tools that run on the build machine
        nativeBuildInputs = [
          pkgs.buildPackages.pkg-config
          pkgs.buildPackages.cmake
          pkgs.buildPackages.boost
          pkgs.buildPackages.llvmPackages.clang
          pkgs.buildPackages.llvmPackages.libclang
        ]
        ++ lib.optionals pkgs.stdenv.buildPlatform.isDarwin [ pkgs.buildPackages.libiconv ]
        ++ extraNativeBuildInputsGlobal
        ++ cfg.extraBuildInputs;

        # Libraries linked into the target binary
        buildInputs = lib.optionals targetPlatform.isDarwin darwinInputs;

        # Cargo.lock pins libbitcoinkernel-sys to a git rev, which carries no
        # checksum.  Let builtins.fetchGit vendor it from the pinned rev
        # instead of hardcoding an outputHash that goes stale every time
        # upstream bumps the dependency.
        cargoLock = {
          lockFile = "${cfg.src}/Cargo.lock";
          allowBuiltinFetchGit = true;
        };

        # libbitcoinkernel-sys runs CMake on the build machine; point it at
        # the build-platform Boost so find_package(Boost) succeeds without
        # trying to cross-compile Boost for the target.
        CMAKE_PREFIX_PATH = "${pkgs.buildPackages.boost.dev}";

        # bindgen (used by libbitcoinkernel-sys <= 0.2.0) needs libclang.
        LIBCLANG_PATH = "${pkgs.buildPackages.llvmPackages.libclang.lib}/lib";

      }
      # When cross-compiling (e.g. Android), disable the default cargo
      # build/install hooks and use explicit phases with --target.
      // lib.optionalAttrs dontCargoBuild {
        inherit dontCargoBuild;
        dontCargoInstall = true;
      }
      // lib.optionalAttrs (customBuildPhase != null) {
        buildPhase = customBuildPhase;
      }
      // lib.optionalAttrs (customInstallPhase != null) {
        installPhase = customInstallPhase;
      }
      // {

        preBuild =
          let
            inherit (pkgs.stdenv) buildPlatform;
            isCross = pkgs.stdenv.hostPlatform != buildPlatform;
            platformSuffix = builtins.replaceStrings [ "-" ] [ "_" ] buildPlatform.config;
          in
          lib.optionalString (buildPlatform.isDarwin && isCross) ''
            export NIX_LDFLAGS_${platformSuffix}="-L${pkgs.buildPackages.libiconv}/lib $NIX_LDFLAGS_${platformSuffix}"
          '';

        cargoDeps = rustPlatform.importCargoLock {
          lockFile = "${cfg.src}/Cargo.lock";
          allowBuiltinFetchGit = true;
        };

        checkFlags = [
          "--skip=tests::test_get_block_header"
          "--skip=tests::test_get_block"
          "--skip=tests::test_get_block_hash"
          "--skip=tests::test_get_best_block_hash"
          "--skip=tests::test_get_blockchaininfo"
          "--skip=tests::test_stop"
          "--skip=tests::test_get_roots"
          "--skip=tests::test_get_height"
          "--skip=tests::test_send_raw_transaction"
          "--skip=p2p_wire::node::conn::tests::test_parse_address"
        ];

        meta =
          with lib;
          {
            description = "A lightweight bitcoin full node - ${pkgConfig.description}";
            homepage = "https://github.com/getfloresta/Floresta";
            license = with licenses; [
              mit
              asl20
            ];
            maintainers = with maintainers; [ jaoleal ];
            platforms = platforms.unix;
          }
          # A library has no binary to be run as.
          // lib.optionalAttrs (pkgConfig.mainProgram != null) { inherit (pkgConfig) mainProgram; };

        passthru = {
          inherit cfg pkgConfig;
          override = newArgs: mkFloresta (cfg // newArgs);
          overrideAttrs = f: (mkFloresta args).overrideAttrs f;
        };
      }
      // extraEnvVars
    );

in
{
  inherit mkFloresta buildFlorestaOptions;

  # Everything a Floresta build publishes, from one compile of the workspace:
  # `cargo build` over the default members leaves the binaries and the cdylib
  # /staticlib targets in one directory, and the install hook sorts them into
  # bin/ and lib/. Nothing here lists what that is — the source tree decides,
  # and the version comes off the Cargo.toml being built.
  #
  # Three `--bin`/`--lib` builds joined afterwards would name the same files
  # and compile the shared dependency graph — libbitcoinkernel included —
  # once each.
  default = mkFloresta { };

  debug = mkFloresta { profile = "debug"; };
}
