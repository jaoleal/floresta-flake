# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Release attestation independent builders compile the same source, hash the
# artifacts, and sign the manifest into contrib/sigs/; verification confirms
# that every trusted signer reported identical hashes.
#
# The manifest is a derivation; signing and verifying are programs
# (`nix run .#attest`, `nix run .#verify`). `nix flake check` runs the same
# verifier against the committed attestations.
{
  pkgs,
  # <version> -> the build that release publishes on this host. The version
  # key names the manifest and its directory under contrib/sigs/.
  releases,
  # Directory of trusted release-signing public keys.
  trustedKeys,
  # Collected attestations: <version>/<signer>/SHA256SUMS{,.asc}.
  sigs,
}:

let
  inherit (pkgs) lib;

  # The target a build was compiled for: cross builds carry rustTarget,
  # native ones are the host's.
  tripleOf = drv: drv.rustTarget or pkgs.stdenv.hostPlatform.rust.rustcTarget;

  # One manifest per release: a "<hash>  <file>-<triple>" line for every
  # file its build installs under bin/ and lib/, sorted by artifact name.
  manifests = lib.mapAttrs (
    version: build:
    pkgs.runCommand "floresta-SHA256SUMS-${version}" { } ''
      for f in ${build}/bin/* ${build}/lib/*; do
          [ -f "$f" ] || continue
          echo "$(sha256sum "$f" | cut -d' ' -f1)  $(basename "$f")-${tripleOf build}"
      done | LC_ALL=C sort -k2 > $out
    ''
  ) releases;

  attestableVersions = lib.attrNames releases;

  # The verifier's logic lives in rust/verify.rs; this compiles it with the
  # flake's gpg and contrib/ copies baked in as the fallback paths.
  verify = pkgs.writers.writeRustBin "floresta-verify" { rustcArgs = [ "--edition=2021" ]; } (
    builtins.replaceStrings
      [ "@gnupg@" "@sigs@" "@trustedKeys@" ]
      [ "${pkgs.gnupg}" "${sigs}" "${trustedKeys}" ]
      (builtins.readFile ./rust/verify.rs)
  );

  # The signer's logic lives in rust/attest.rs; this compiles it with the
  # flake's gpg and the attestable versions baked in.
  attest = pkgs.writers.writeRustBin "floresta-attest" { rustcArgs = [ "--edition=2021" ]; } (
    builtins.replaceStrings
      [ "@gnupg@" "@versions@" ]
      [ "${pkgs.gnupg}" (lib.concatStringsSep " " attestableVersions) ]
      (builtins.readFile ./rust/attest.rs)
  );

  # Lists the attestable versions, for `nix run .#releases`.
  listReleases = pkgs.writeShellApplication {
    name = "floresta-releases";
    text = ''
      ${lib.concatMapStrings (v: "echo ${v}\n") attestableVersions}
    '';
  };

  # Runs against the committed copies the flake pins, not the working tree.
  check =
    pkgs.runCommand "floresta-attestations"
      {
        nativeBuildInputs = [ verify ];
      }
      ''
        set -o pipefail
        floresta-verify | tee "$out"
      '';
in
{
  inherit
    manifests
    verify
    attest
    listReleases
    check
    ;
}
