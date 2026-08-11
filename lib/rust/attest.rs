// SPDX-License-Identifier: MIT OR Apache-2.0
//
// floresta-attest: builds the manifest of <version> and signs it into
// contrib/sigs/<version>/<signer>/. Rejects unknown versions before the
// build starts.
//
// Compiled by lib/attestation.nix, which fills in the @placeholders@.

use std::env;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{exit, Command, Stdio};

const GPG: &str = "@gnupg@/bin/gpg";
const VERSIONS: &str = "@versions@";

fn usage() -> String {
    let mut text = String::from(
        "Usage: floresta-attest <version> <signer>\n\
         \n\
         Builds every target of <version> for this host, hashes what they\n\
         install, and signs the manifest into contrib/sigs/<version>/<signer>/.\n\
         Expect a long build: every target is compiled from source.\n\
         \n\
         Set GPG_KEY if your keyring holds more than one secret key.\n\
         \n\
         Releases that can be attested:\n",
    );
    for version in VERSIONS.split_whitespace() {
        text.push_str("  ");
        text.push_str(version);
        text.push('\n');
    }
    text
}

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    if matches!(args.first().map(String::as_str), Some("-h" | "--help")) {
        print!("{}", usage());
        return;
    }

    let version = args.first().filter(|s| !s.is_empty());
    let signer = args.get(1).filter(|s| !s.is_empty());
    let (Some(version), Some(signer)) = (version, signer) else {
        eprint!("{}", usage());
        exit(2);
    };

    if !VERSIONS.split_whitespace().any(|v| v == version) {
        eprintln!("floresta-attest: {version} is not a release this flake pins");
        eprint!("{}", usage());
        exit(2);
    }

    if !Path::new("flake.nix").is_file() {
        eprintln!(
            "floresta-attest: run this from a floresta-nix checkout — it writes into contrib/sigs/"
        );
        exit(2);
    }

    if let Err(e) = run(version, signer) {
        eprintln!("floresta-attest: {e}");
        exit(1);
    }
}

fn run(version: &str, signer: &str) -> Result<(), String> {
    let manifest = build_manifest(version)?;

    let dest = PathBuf::from("contrib/sigs").join(version).join(signer);
    let sums = dest.join("SHA256SUMS");
    fs::create_dir_all(&dest).map_err(|e| format!("cannot create {}: {e}", dest.display()))?;
    fs::copy(&manifest, &sums)
        .map_err(|e| format!("cannot install {manifest} to {}: {e}", sums.display()))?;
    fs::set_permissions(&sums, fs::Permissions::from_mode(0o644))
        .map_err(|e| format!("cannot chmod {}: {e}", sums.display()))?;

    sign(&sums, &dest.join("SHA256SUMS.asc"))?;

    println!();
    println!("Wrote {}/SHA256SUMS{{,.asc}}", dest.display());
    println!("Check it:  nix run .#verify");
    println!("Then:      git add {} && git commit", dest.display());
    Ok(())
}

// Builds the release's manifest derivation. Logs stream to stderr; stdout
// is the manifest's store path.
fn build_manifest(version: &str) -> Result<String, String> {
    let output = Command::new("nix")
        .args(["build", "-L", "--no-link", "--print-out-paths"])
        .arg(format!(".#attestation-manifest-{version}"))
        .stderr(Stdio::inherit())
        .output()
        .map_err(|e| format!("cannot run nix: {e}"))?;
    if !output.status.success() {
        return Err(format!("building the {version} manifest failed"));
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

// gpg keeps the terminal: it may need pinentry for the passphrase.
fn sign(sums: &Path, asc: &Path) -> Result<(), String> {
    let mut gpg = Command::new(GPG);
    gpg.args(["--detach-sign", "--armor", "--yes"]);
    if let Ok(key) = env::var("GPG_KEY") {
        if !key.is_empty() {
            gpg.args(["--local-user", &key]);
        }
    }
    let signed = gpg
        .arg("--output")
        .arg(asc)
        .arg(sums)
        .status()
        .map_err(|e| format!("cannot run {GPG}: {e}"))?
        .success();
    if signed {
        Ok(())
    } else {
        Err("signing the manifest failed".into())
    }
}
