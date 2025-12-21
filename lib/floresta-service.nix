{
  config,
  pkgs,
  lib,
  ...
}:

with lib;
let
  options = {
    services.floresta = {
      enable = mkEnableOption "Floresta Bitcoin node daemon";

      address = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Address to listen for peer connections. ";
      };

      port = mkOption {
        type = types.port;
        default =
          if cfg.network == "bitcoin" then
            8333
          else if cfg.network == "signet" then
            38333
          else
            18444;
        defaultText = ''
          The network we are running in, it may be one of: bitcoin, signet, regtest or testnet.
        '';
        description = "Port to listen for peer connections.";
      };

      listen = mkEnableOption {
        type = types.bool;
        default = false;
        description = ''
          Listen for peer connections at `address:port`.
        '';
      };

      package = mkOption {
        type = types.package;
        default =
          if
            cfg.features != [ ]
            || cfg.noDefaultFeatures
            || cfg.electrum.enable
            || cfg.rpc.enable
            || cfg.zmq-server.enable
            || cfg.cfilters.enable
            || cfg.metrics
            || cfg.tokio-console
          then
            cfg.package.override {
              buildFeatures = cfg.features;
              buildNoDefaultFeatures = cfg.noDefaultFeatures;
            }
          else
            pkgs.floresta or (throw "floresta package not found in pkgs");
        defaultText = literalExpression "pkgs.floresta";
        description = ''
          The package providing floresta binaries.

          This is automatically overridden with custom features if `features` or
          `noDefaultFeatures` options are set.

          You can also manually override this to use a custom floresta package.
        '';
      };

      features = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [
          "cli"
          "json-rpc"
          "zmq"
        ];
        description = ''
          List of features to directly pass when re-building floresta.

          Common floresta features:
          - cli:  Command-line interface
          - json-rpc: JSON-RPC server support
          - electrum-server: Electrum protocol server
          - compact-filters: BIP 157/158 compact block filters
          - experimental-p2p:  Experimental P2P features
          - zmq: ZeroMQ notification support

          Feature related options triggers a rebuild of the node, even if youre
          providing a package under services.floresta.package. You can set
          services.floresta.packageUnwrapped to deny any rebuilding.
        '';
      };

      noDefaultFeatures = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to disable default Cargo features when building floresta.
          Equivalent to `cargo build --no-default-features`.

          Use this when you want fine-grained control over exactly which
          features are enabled.

          Feature related options triggers a rebuild of the node, even if youre
          providing a package under services.floresta.package. You can set
          services.floresta.packageUnwrapped to deny any rebuilding.
        '';
      };

      packageUnwrapped = mkOption {
        type = types.package;
        internal = true;
        default = pkgs.floresta or (throw "floresta package not found in pkgs");
        description = ''
          The base floresta package to use without any overriding or rebuilding
          including/excluding features.

          Feature related options triggers a rebuild of the node, even if youre
          providing a package under services.floresta.package. You can set
          services.floresta.packageUnwrapped to deny any rebuilding.
        '';
      };

      extraConfig = mkOption {
        type = types.lines;
        default = "";
        example = ''
          log_level = "debug"
          assume_valid = true
        '';
        description = "Extra lines appended to {file}`config.toml`.";
      };

      dataDir = mkOption {
        type = types.path;
        default = "/var/lib/floresta";
        description = ''
          Where we should place our data

          This directory must be readable and writable by our process. We'll use this dir to store
          both chain and wallet data, so this should be kept in a non-volatile medium. We are not
          particularly aggressive in disk usage, so we don't need a fast disk to work.
        '';
      };

      logging = {
        toStdout = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Whether to write logs to stdout.
            Useful for systemd journal integration.
          '';
        };

        toFile = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Whether to log to a filesystem file.
            Logs will be written to the data directory.
          '';
        };

        debug = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Whether to post debug information to the console.
            Enables verbose logging output.
          '';
        };
      };

      assumeUtreexo = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to use assume utreexo mode.
          This allows skipping validation of early blocks using a trusted utreexo accumulator,
          significantly speeding up initial sync.
        '';
      };

      assumeUtreexoValue = mkOption {
        type = types.nullOr (
          types.submodule {
            options = {
              blockHash = mkOption {
                type = types.str;
                example = "00000000000000000002a7c4c1e48d76c5a37902165a270156b7a8d72728a054";
                description = ''
                  The block hash of the latest block assumed to be valid.
                  The accumulator roots correspond to this block.
                '';
              };

              height = mkOption {
                type = types.ints.unsigned;
                example = 800000;
                description = ''
                  The block height corresponding to blockHash.
                  Same information as blockHash, but in height format.
                '';
              };

              roots = mkOption {
                type = types.listOf types.str;
                example = [
                  "a1b2c3d4e5f6..."
                  "f6e5d4c3b2a1..."
                ];
                description = ''
                  The roots of the Utreexo accumulator at this block.
                  Each root is represented as a hex-encoded hash string.
                '';
              };

              leaves = mkOption {
                type = types.ints.unsigned;
                example = 123456789;
                description = ''
                  The number of leaves in the Utreexo accumulator at this block.
                  This represents the total number of UTXOs in the accumulator.
                '';
              };
            };
          }
        );
        default = null;
        example = literalExpression ''
          {
            blockHash = "00000000000000000002a7c4c1e48d76c5a37902165a270156b7a8d72728a054";
            height = 800000;
            roots = [
              "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2"
              "f6e5d4c3b2a1f0e9d8c7b6a5f4e3d2c1b0a9f8e7d6c5b4a3f2e1d0c9b8a7f6e5"
            ];
            leaves = 123456789;
          }
        '';
        description = ''
          The Utreexo accumulator value to assume when using assume utreexo mode.

          It should contain:
          - The block hash and height of a known valid block
          - The Utreexo accumulator roots at that block
          - The number of leaves (UTXOs) in the accumulator

          If null and assumeUtreexo is enabled, Floresta will use its default
          hardcoded value (typically the most recent release checkpoint).

          You can obtain these values from a trusted Floresta node or from
          the Floresta project's official checkpoints.
        '';
      };

      backfill = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to backfill and validate blocks that were skipped during assume utreexo sync.

          When enabled, Floresta will download and validate all previously skipped blocks
          in the background.  This is CPU and bandwidth intensive but ensures full validation
          of the entire blockchain history.

          Note: This only has effect when assumeUtreexo is enabled.
        '';
      };

      userAgent = mkOption {
        type = types.str;
        default = "/Floresta: ${cfg.package.version}/";
        defaultText = "/Floresta: <version>/";
        description = ''
          The user agent string that will be advertised to peers.
        '';
      };

      allowV1Fallback = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether to allow fallback to v1 P2P transport if v2 connection fails.

          Bitcoin v2 transport provides encrypted peer connections.  If a peer doesn't
          support v2, enabling this option allows falling back to unencrypted v1 transport.
        '';
      };

      electrum = {
        enable = mkEnableOption "Electrum server support";

        address = mkOption {
          type = types.str;
          default = "127.0.0.1:50001";
          description = "Address the Electrum server will listen on (non-TLS).";
        };

        tls = {
          enable = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Whether to enable the Electrum TLS server.
              Provides encrypted connections for Electrum wallets.
            '';
          };

          address = mkOption {
            type = types.str;
            default = "127.0.0.1:50002";
            description = "Address the Electrum TLS server will listen on. ";
          };

          keyPath = mkOption {
            type = types.nullOr types.path;
            default = null;
            example = "/var/lib/floresta/tls/key.pem";
            description = ''
              Path to TLS private key in PKCS#8 format.
              If null, defaults to `{dataDir}/tls/key.pem`.

              Generate with:
              ```
              openssl genpkey -algorithm RSA -out key.pem -pkeyopt rsa_keygen_bits:2048
              ```
            '';
          };

          certPath = mkOption {
            type = types.nullOr types.path;
            default = null;
            example = "/var/lib/floresta/tls/cert.pem";
            description = ''
              Path to TLS certificate in PKCS#8 format.
              If null, defaults to `{dataDir}/tls/cert.pem`.

              Generate with:
              ```
              openssl req -x509 -new -key key.pem -out cert.pem -days 365 -subj "/CN=localhost"
              ```
            '';
          };

          generateCert = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Whether to automatically generate a self-signed certificate if cert/key don't exist.
              Useful for testing and local development.

              For production use, you should provide your own certificate signed by a trusted CA.
            '';
          };
        };
      };

      rpc = {
        enable = mkEnableOption "JSON-RPC server support";

        address = mkOption {
          type = types.str;
          default = "127.0.0.1";
          description = ''
            Address to listen for JSON-RPC connections.
          '';
        };

        port = mkOption {
          type = types.port;
          default =
            if cfg.network == "bitcoin" then
              8332
            else if cfg.network == "signet" then
              38332
            else
              18443;
          defaultText = "8332 for mainnet, 38332 for signet, 18443 for regtest";
          description = "Port to listen for JSON-RPC connections.";
        };

        allowip = mkOption {
          type = types.listOf types.str;
          default = [ "127.0.0.1" ];
          description = ''
            Allow JSON-RPC connections from specified sources.
          '';
        };
      };

      network = mkOption {
        type = types.enum [
          "bitcoin"
          "signet"
          "regtest"
        ];
        default = "bitcoin";
        description = ''
          Which Bitcoin network to use.
          - bitcoin: mainnet
          - signet: signet testnet
          - regtest: regression test mode
        '';
      };

      proxy = mkOption {
        type = types.nullOr types.str;
        default = if cfg.tor.proxy then config.nix-bitcoin.torClientAddressWithPort or null else null;
        description = ''
          A proxy that we should use to connect with others.

          This should be a socks5 proxy, like Tor's socks. If provided, all our outgoing connections
          will be made through this one, except dns seed connections.

          - Nix exclusive
          If none is provided it try to use nixbitcoin`s tor service.
        '';
      };

      assumeValid = mkOption {
        type = types.bool;
        default = false;
        description = ''
          We consider blocks prior to this one to have a valid signature

          This is an optimization mirrored from Core, where blocks before this one are considered to
          have valid signatures. The idea here is that if a block is buried under a lot of PoW, it's
          very unlikely that it is invalid. We still validate everything else and build the
          accumulator until this point (unless running on PoW-fraud proof or assumeutreexo mode) so
          there's still some work to do.
        '';
      };

      assumeValidValue = mkOption {
        type = types.nullOr (
          types.submodule {
            options = {
              blockHash = mkOption {
                type = types.str;
                example = "00000000000000000002a7c4c1e48d76c5a37902165a270156b7a8d72728a054";
                description = ''
                  The block hash of the latest block assumed to be valid.
                  The accumulator roots correspond to this block.
                '';
              };
              hardcoded = mkOption {
                type = types.bool;
                example = true;
                description = ''
                  Wheter to use the hardcoded blockhash under the assumption that these scripts
                  were correctly validated when the software was released. Since users already trust
                  the developers and reviewers of the software, the hardcoded boundary is assumed
                  to be correct.
                '';
              };
            };
          }
        );
        default = null;
        example = literalExpression ''
          {
            blockHash = "00000000000000000002a7c4c1e48d76c5a37902165a270156b7a8d72728a054";
            height = 800000;
            roots = [
              "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2"
              "f6e5d4c3b2a1f0e9d8c7b6a5f4e3d2c1b0a9f8e7d6c5b4a3f2e1d0c9b8a7f6e5"
            ];
            leaves = 123456789;
          }
        '';
        description = ''
          The Utreexo accumulator value to assume when using assume utreexo mode.

          It should contain:
          - The block hash and height of a known valid block
          - The Utreexo accumulator roots at that block
          - The number of leaves (UTXOs) in the accumulator

          If null and assumeUtreexo is enabled, Floresta will use its default
          hardcoded value (typically the most recent release checkpoint).

          You can obtain these values from a trusted Floresta node or from
          the Floresta project's official checkpoints.
        '';
      };

      walletXpubs = mkOption {
        type = types.nullOr types.listOf types.str;
        description = ''
          A vector of xpubs to cache

          This is a list of SLIP-132-encoded extended public key that we should add to our Watch-only
          wallet. A descriptor may be only passed one time, if you call florestad with an already
          cached address, that will be a no-op. After a xpub is cached, we derive multiple addresses
          from it and try to find transactions involving it.
        '';
      };

      walletDescriptors = mkOption {
        type = types.nullOr types.listOf types.str;
        description = ''
          A Vec of output descriptor to cache

          This should be a list of output descriptors that we should add to our watch-only wallet.
          This works just like wallet_xpub, but with a descriptor.
        '';
      };

      configFile = mkOption {
        type = types.nullOr types.str;
        description = ''
          Where to read the config file from or the file to append the config on, in case it already exists.
        '';
      };

      metrics = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Wheter to enable the metrics feature on florestad.
        '';
      };

      tokio-console = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Wheter to enable the support for the tokio console on florestad.
        '';
      };

      cfilters = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether we should build and store compact block filters

          Those filters are used for rescanning our wallet for historical transactions. If you don't
          have this on, the only way to find historical transactions is to download all blocks, which
          is very inefficient and resource/time consuming. But keep in mind that filters will take
          up disk space.
        '';
      };

      filters_start_height = mkOption {
        type = types.nullOr types.ints.s32;
        default = null;
        example = -100;
        description = ''
          If we are using block filters, we may not need to download the whole chain of filters, as
          our wallets may not have been created at the beginning of the chain. With this option, we
          can make a rough estimate of the block height we need to start downloading filters.

          If the value is negative, it's relative to the current tip. For example, if the current tip
          is at height 1000, and we set this value to -100, we will start downloading filters from
          height 900.'';
      };

      zmq-server = {
        enable = mkEnableOption "Wheter to enable the zmq-server";
        address = mkOption {
          type = types.nullOr types.str;
          description = ''
            The address to listen to for our ZMQ server

            We have an (optional) ZMQ server, that pushes new blocks over a PUSH/PULL ZMQ queue, this
            is the address that we'll listen for incoming connections.
          '';
        };
      };

      disableDnsSeeds = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether we should disable dns seeds.
        '';
      };

      dbCache = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        example = 1000;
        description = "Database cache size in MB.";
      };

      maxConnections = mkOption {
        type = types.ints.positive;
        default = 10;
        description = "Maximum number of peer connections.";
      };

      addnodes = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Add nodes to connect to";
      };

      connect = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          A node to connect to

          If this option is provided, we'll connect **only** to this node.
        '';
      };

      user = mkOption {
        type = types.str;
        default = "floresta";
        description = "The user as which to run floresta.";
      };

      group = mkOption {
        type = types.str;
        default = cfg.user;
        description = "The group as which to run floresta.";
      };

      tor = mkOption {
        type = types.submodule {
          options = {
            proxy = mkOption {
              type = types.bool;
              default = false;
              description = "Use Tor proxy for peer connections.";
            };
            enforce = mkOption {
              type = types.bool;
              default = false;
              description = "Enforce Tor usage, blocking non-Tor connections.";
            };
          };
        };
        default = {
          proxy = false;
          enforce = false;
        };
        description = "Tor configuration options.";
      };
    };
  };

  cfg = config.services.floresta;
  nbLib = config.nix-bitcoin.lib or { };
in
{
  inherit options;

  config = mkIf cfg.enable {
    environment.systemPackages = [
      cfg.package
    ];

    assertions = [
      {
        assertion = cfg.electrum.enable -> cfg.filters;
        message = "Electrum server requires filters to be enabled";
      }
    ];

    systemd.services.floresta = rec {
      description = "Floresta Bitcoin Node";
      wants = [ "network-online.target" ];
      after = wants;
      wantedBy = [ "multi-user.target" ];

      preStart = ''${optionalString cfg.dataDirReadableByGroup ''chmod -R g+rX '${cfg.dataDir}' || true ''}'';

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        ExecStart = "${cfg.package}/bin/florestad --config-file='${cfg.dataDir}'";
        Restart = "on-failure";
        RestartSec = "30s";
        TimeoutStartSec = "10min";
        TimeoutStopSec = "10min";

        # Hardening
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        RemoveIPC = true;
        PrivateMounts = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
          "~@resources"
        ];
        ProtectHostname = true;
        ProtectClock = true;
        ProtectKernelLogs = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        UMask = if cfg.dataDirReadableByGroup then "0027" else "0077";

        # Permissions
        ReadWritePaths = [ cfg.dataDir ];
        ReadOnlyPaths = optionals (cfg.rpc.passwordFile != null) [ cfg.rpc.passwordFile ];

        # Resource limits
        MemoryDenyWriteExecute = true;
        LimitNOFILE = 8192;
      }
      // optionalAttrs (cfg.tor.enforce && nbLib ? allowedIPAddresses) (
        nbLib.allowedIPAddresses cfg.tor.enforce
      );
    };

    users = {
      groups.${cfg.group} = { };
      groups.floresta-rpc = { };

      users.${cfg.user} = {
        inherit (cfg) group;
        isSystemUser = true;
        description = "Floresta daemon user";
        home = cfg.dataDir;
      };
    };

    # nix-bitcoin integration (optional)
    nix-bitcoin.operator.groups = optionals (config.nix-bitcoin.operator or null != null) [ cfg.group ];
  };
}
