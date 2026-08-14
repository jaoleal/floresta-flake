# floresta-nix

Nix packaging for [Floresta](https://github.com/getfloresta/Floresta).

## Packages

Every package this flake exports is a release: one build of the Floresta
workspace, which installs everything that release publishes — `florestad`
(the full node daemon) and `floresta-cli` (its command-line interface) under
`bin/`, the `libfloresta` shared and static libraries under `lib/`.

| Package  | Description                                       |
| -------- | ------------------------------------------------- |
| `master` | The current Floresta — the pinned upstream branch |
| `v0_9_1` | The v0.9.1 release tag                            |
| `v0_9_0` | The v0.9.0 release tag                            |

```sh
nix build .#master                # everything master publishes
nix build .#v0_9_1                # the same, as the v0.9.1 tag ships it
nix build .#master.aarch64-android
./result/bin/florestad
```

Master also cross-compiles for Android; those targets hang off it as
`master.<abi>` — see [PLATFORMS.md](PLATFORMS.md).

To build a single component instead of the whole workspace, use the build
library's `mkFloresta` directly — see below.

### Supported platforms

| Platform | Architecture                            |
| -------- | --------------------------------------- |
| Linux    | x86_64, aarch64                         |
| macOS    | x86_64 (Intel), aarch64 (Apple Silicon) |

### Using in your own flake

Add this flake as an input and import the build library:

```nix
{
  inputs.floresta-nix.url = "github:getfloresta/floresta-nix";

  outputs = { nixpkgs, floresta-nix, ... }:
    let
      pkgs = import nixpkgs { system = "x86_64-linux"; };
      florestaBuild = import "${floresta-nix}/lib/floresta-build.nix" { inherit pkgs; };
    in {
      packages.x86_64-linux.florestad = florestaBuild.mkFloresta {
        packageName = "florestad";
      };
    };
}
```

See [`examples/flake.nix`](examples/flake.nix) for a multi-platform example using `flake-utils`.

### Build options

`florestaBuild.mkFloresta` accepts:

| Option             | Type            | Default            | Description                                                                               |
| ------------------ | --------------- | ------------------ | ----------------------------------------------------------------------------------------- |
| `packageName`      | enum            | `"all"`            | `"all"` (the whole workspace), or one of `"florestad"`, `"floresta-cli"`, `"libfloresta"` |
| `profile`          | enum            | `"release"`        | `"release"` or `"debug"` cargo profile                                                    |
| `src`              | path            | Latest release tag | Override the Floresta source tree                                                         |
| `features`         | list of str     | `[]`               | Additional cargo features to enable                                                       |
| `extraBuildInputs` | list of package | `[]`               | Extra build-time dependencies                                                             |
| `doCheck`          | bool            | `false`            | Run tests during build                                                                    |

The library also exports `default` (`mkFloresta { }` — the whole workspace at
the release profile) and `debug` (the same at the debug profile). Building a
single component compiles the shared dependency graph on its own, so ask for
`"all"` unless you really want just the one.

## NixOS Service Module

This flake exports a NixOS module at `nixosModules.floresta` (also `nixosModules.default`) that provides a systemd service for running florestad.

See [`examples/flake.nix`](examples/flake.nix) for usage alongside the build library.

### Service options

| Option                      | Type         | Default             | Description                                        |
| --------------------------- | ------------ | ------------------- | -------------------------------------------------- |
| `enable`                    | bool         | `false`             | Enable the Floresta systemd service                |
| `allowV1Fallback`           | bool         | `false`             | Allow fallback to v1 P2P transport                 |
| `assumeUtreexo`             | bool         | `true`              | Use assume-utreexo for faster initial sync         |
| `assumeValid`               | str          | `"hardcoded"`       | `"hardcoded"`, `"0"` (disabled), or a block hash   |
| `backfill`                  | bool         | `true`              | Backfill blocks skipped during assume-utreexo sync |
| `cfilters`                  | bool         | `true`              | Build compact block filters (BIP 157/158)          |
| `connect`                   | str or null  | `null`              | Connect only to this specific node                 |
| `dataDir`                   | path         | `/var/lib/floresta` | Directory for chain and wallet data                |
| `debug`                     | bool         | `false`             | Enable verbose debug logging                       |
| `disableDnsSeeds`           | bool         | `false`             | Disable DNS seed discovery                         |
| `electrum.address`          | str or null  | `null`              | Electrum server listen address                     |
| `electrum.tls.enable`       | bool         | `false`             | Enable Electrum TLS                                |
| `electrum.tls.address`      | str or null  | `null`              | Electrum TLS listen address                        |
| `electrum.tls.certPath`     | path or null | `null`              | TLS certificate path                               |
| `electrum.tls.keyPath`      | path or null | `null`              | TLS private key path                               |
| `electrum.tls.generateCert` | bool         | `false`             | Auto-generate self-signed certificate              |
| `extraArgs`                 | list of str  | `[]`                | Extra CLI arguments passed to florestad            |
| `filtersStartHeight`        | int or null  | `null`              | Block height to start downloading filters from     |
| `group`                     | str          | `"floresta"`        | Group under which floresta runs                    |
| `logToFile`                 | bool         | `false`             | Write logs to file in data directory               |
| `network`                   | enum         | `"bitcoin"`         | `"bitcoin"`, `"signet"`, or `"regtest"`            |
| `package`                   | package      | `pkgs.floresta`     | The florestad package to use                       |
| `proxy`                     | str or null  | `null`              | SOCKS5 proxy (e.g. Tor)                            |
| `rpc.address`               | str or null  | `null`              | JSON-RPC server address (host:port)                |
| `user`                      | str          | `"floresta"`        | User under which floresta runs                     |
| `walletDescriptors`         | list of str  | `[]`                | Output descriptors to watch                        |
| `walletXpubs`               | list of str  | `[]`                | Extended public keys to watch                      |
| `zmqAddress`                | str or null  | `null`              | ZMQ push/pull server address                       |

The service includes systemd hardening (sandboxing, restricted syscalls, private tmp, etc.) out of the box.

## Release Verification

Releases are attested by independent builders. Each builder compiles the same source, hashes the resulting artifacts, and signs the hash manifest with their GPG key. The signed manifests live in [`contrib/sigs/`](contrib/sigs); anyone can then check that every trusted signer reported identical hashes.

Release artifacts are named `<file>-<target triple>` — `florestad-x86_64-unknown-linux-gnu`, `libfloresta.dylib-aarch64-apple-darwin`, and so on — the same names used in the manifests, so a downloaded binary can be checked directly against them.

An attestation covers one tagged release and hashes exactly what it installs. Master is not attested, and the Android cross builds exist only on master. `nix run .#releases` lists the versions.

[`lib/attestation.nix`](lib/attestation.nix) holds the whole mechanism:

|                                              |                                                                                                                            |
| -------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `nix run .#releases`                         | Lists the releases that can be attested                                                                                    |
| `nix run .#attest -- <version> <signer>`     | Builds the manifest and signs it with your key into `contrib/sigs/<version>/`                                              |
| `nix run .#verify`                           | Verifies every collected signature, then the consensus between signers                                                     |
| `nix build .#attestation-manifest-<version>` | Just the manifest: builds every target of that release for your host, hashes the artifacts, writes the sorted `SHA256SUMS` |

The `<version>` is one string throughout: it picks the source tree, names the manifest, and names the directory the signature is filed under. `attest` rejects a version this flake does not pin.

### Verifying a release

```bash
nix run .#verify     # or: just verify
```

`nix flake check` runs the same verifier against what is committed, so CI checks every attestation on every push. It fails if any signature is bad, if any signature comes from a key outside [`contrib/trusted-keys/`](contrib/trusted-keys), or if two signers report different hashes for the same artifact.

Artifacts marked `PARTIAL` are not a failure: they are covered by some signers and not others, because each signer hashes the artifacts their own host builds — a macOS signer cannot attest the Linux binaries, nor the other way around (see [PLATFORMS.md](PLATFORMS.md)).

You do not have to sign anything to check a release: `nix build .#attestation-manifest-<version>` produces the manifest on its own, so you can confirm you reproduce the same hashes.

### Becoming a signer

1. Export your public key with:

```bash
gpg --armor --export <KEYID> > contrib/trusted-keys/<yourname>.asc
```

2. Build and sign the release:

```bash
nix run .#attest -- v0_9_1 yourname
```

This writes `contrib/sigs/v0_9_1/yourname/SHA256SUMS` and `SHA256SUMS.asc`. Expect a long build: every target is compiled from source. Set `GPG_KEY` if your keyring holds more than one secret key.

3. Check what you just wrote with `nix run .#verify` — it reads your working tree, so it sees the signature before you commit it.
4. Commit both files and open a PR.

Releases published by CI also carry [GitHub build provenance](https://docs.github.com/actions/security-guides/using-artifact-attestations-to-establish-provenance-for-builds), verifiable with `gh attestation verify <file> --repo getfloresta/floresta-nix`.

## CI

All packages are built across every supported platform on each push and PR. Builds are cached on [Cachix](https://app.cachix.org/cache/floresta-flake), dependencies are tracked by Dependabot, and a weekly scheduled build catches upstream breakage early.
