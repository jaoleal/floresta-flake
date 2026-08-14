# List all available recipes
default:
    @just --list

# Run all nix sanity checks
check:
    nix flake check -L
    nix flake check ./examples -L --no-build

# Build a release or one of its cross targets (master, v0_9_1, master.aarch64-android)
build package="master":
    nix build -L .#{{ package }}

# Build a release and copy its artifacts into artifacts/, suffixed with the nix system
build-and-package-all release="master":
    #!/usr/bin/env bash
    set -euo pipefail
    SYSTEM=$(nix eval --impure --raw --expr 'builtins.currentSystem')
    echo "Building {{ release }} for $SYSTEM..."
    just build {{ release }}

    mkdir -p artifacts
    for f in result/bin/* result/lib/*; do
        [ -f "$f" ] || continue
        cp -L "$f" "artifacts/$(basename "$f")-$SYSTEM"
        echo "✅ Packaged $(basename "$f")-$SYSTEM"
    done

# The attestation verbs below are flake apps; these are shorthands for them.

# List the releases that can be attested
releases:
    @nix run .#releases

# Build, hash and sign a release manifest into contrib/sigs/ (long build; GPG_KEY picks a key)
attest version signer:
    nix run .#attest -- {{ version }} {{ signer }}

# Check every collected attestation: signatures, then consensus
verify:
    nix run .#verify

# Import the release-signing keys into your own GPG keyring
import-keys:
    gpg --import contrib/trusted-keys/*.asc

# Clean build artifacts
clean:
    rm -rf result artifacts

update:
    nix flake update --flake ./examples/
    nix flake update
