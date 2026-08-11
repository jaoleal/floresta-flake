// SPDX-License-Identifier: MIT OR Apache-2.0
//
// floresta-verify: checks the collected release attestations. Imports only
// the trusted keys, so a good signature and a trusted signer are one check;
// then compares the surviving manifests per artifact. Reads the working
// tree's contrib/ when present, the flake's copies otherwise.
//
// Compiled by lib/attestation.nix, which fills in the @placeholders@.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};
use std::process::{exit, Command, Stdio};

const GPG: &str = "@gnupg@/bin/gpg";
const FLAKE_SIGS: &str = "@sigs@";
const FLAKE_KEYS: &str = "@trustedKeys@";

fn main() {
    let sigs_dir = existing_dir("contrib/sigs", FLAKE_SIGS);
    let keys_dir = existing_dir("contrib/trusted-keys", FLAKE_KEYS);

    println!("keys: {}", keys_dir.display());
    println!("sigs: {}", sigs_dir.display());
    println!();

    // A throwaway keyring, so the check never touches the user's.
    let home = std::env::temp_dir().join(format!("floresta-verify-{}", std::process::id()));
    let _ = fs::remove_dir_all(&home);
    if let Err(e) = fs::DirBuilder::new().mode(0o700).create(&home) {
        eprintln!("floresta-verify: cannot create {}: {e}", home.display());
        exit(2);
    }

    let result = run(&home, &sigs_dir, &keys_dir);
    let _ = fs::remove_dir_all(&home);

    match result {
        Ok(status) => exit(status),
        Err(e) => {
            eprintln!("floresta-verify: {e}");
            exit(2);
        }
    }
}

fn run(home: &Path, sigs_dir: &Path, keys_dir: &Path) -> Result<i32, String> {
    import_trusted_keys(home, keys_dir)?;

    let mut status = 0;
    let mut collected = false;
    let mut reported = false;

    for version_dir in sorted_subdirs(sigs_dir)? {
        let version = file_name(&version_dir);
        collected = true;

        // One signer per key, so the same person can't count twice.
        let mut signers: Vec<String> = Vec::new();
        let mut signer_of_key: HashMap<String, String> = HashMap::new();

        for signer_dir in sorted_subdirs(&version_dir)? {
            let signer = file_name(&signer_dir);
            let manifest = signer_dir.join("SHA256SUMS");
            let signature = signer_dir.join("SHA256SUMS.asc");
            if !signature.is_file() {
                continue;
            }
            if !manifest.is_file() {
                eprintln!("MISSING  {version}/{signer}: signature without a manifest");
                status = 1;
                continue;
            }
            match trusted_signing_key(home, &signature, &manifest) {
                Some(key) => {
                    if let Some(other) = signer_of_key.get(&key) {
                        eprintln!(
                            "DUPLICATE  {version}/{signer}: same key as {version}/{other} ({key})"
                        );
                        status = 1;
                        continue;
                    }
                    signer_of_key.insert(key, signer.clone());
                    signers.push(signer);
                }
                None => {
                    eprintln!("BAD SIGNATURE  {version}/{signer}: not signed by a trusted key");
                    status = 1;
                }
            }
        }

        if signers.is_empty() {
            continue;
        }
        reported = true;

        println!(
            "{version} — {} signer(s): {}",
            signers.len(),
            signers.join(", ")
        );
        println!();

        if !artifacts_agree(&version_dir, &signers)? {
            eprintln!("FAILED: signers disagree on {version}");
            status = 1;
        }
        println!();
    }

    if !collected {
        println!("No attestations collected yet.");
    } else if reported {
        println!("PARTIAL entries are artifacts only some signers can build — see PLATFORMS.md.");
    }

    Ok(status)
}

// Folds the signers' manifests per artifact: an artifact covered by only
// some signers is PARTIAL, two hashes for one artifact is DIFFERS and
// fails the version.
fn artifacts_agree(version_dir: &Path, signers: &[String]) -> Result<bool, String> {
    let mut order: Vec<String> = Vec::new();
    let mut claims: HashMap<String, Vec<(String, String)>> = HashMap::new();

    for signer in signers {
        let manifest = version_dir.join(signer).join("SHA256SUMS");
        let text = fs::read_to_string(&manifest)
            .map_err(|e| format!("cannot read {}: {e}", manifest.display()))?;
        for line in text.lines() {
            let mut fields = line.split_whitespace();
            let (Some(hash), Some(artifact)) = (fields.next(), fields.next()) else {
                continue;
            };
            if !claims.contains_key(artifact) {
                order.push(artifact.to_string());
            }
            claims
                .entry(artifact.to_string())
                .or_default()
                .push((signer.clone(), hash.to_string()));
        }
    }

    let mut agrees = true;
    for artifact in &order {
        let rows = &claims[artifact];
        let hashes: HashSet<&str> = rows.iter().map(|(_, hash)| hash.as_str()).collect();
        if hashes.len() > 1 {
            agrees = false;
            println!("  DIFFERS  {artifact}");
            for (signer, hash) in rows {
                println!("             {signer:<16} {hash}");
            }
        } else {
            let state = if rows.len() < signers.len() {
                "PARTIAL"
            } else {
                "OK"
            };
            println!(
                "  {state:<8} {artifact:<44} {}/{}  {}",
                rows.len(),
                signers.len(),
                rows[0].1
            );
        }
    }
    Ok(agrees)
}

fn import_trusted_keys(home: &Path, keys_dir: &Path) -> Result<(), String> {
    let mut keys: Vec<PathBuf> = fs::read_dir(keys_dir)
        .map_err(|e| format!("cannot read {}: {e}", keys_dir.display()))?
        .filter_map(|entry| entry.ok().map(|e| e.path()))
        .filter(|path| path.extension().is_some_and(|ext| ext == "asc"))
        .collect();
    keys.sort();
    if keys.is_empty() {
        return Err(format!("no *.asc keys in {}", keys_dir.display()));
    }

    let imported = Command::new(GPG)
        .env("GNUPGHOME", home)
        .args(["--batch", "--quiet", "--import"])
        .args(&keys)
        .status()
        .map_err(|e| format!("cannot run {GPG}: {e}"))?
        .success();
    if imported {
        Ok(())
    } else {
        Err("importing the trusted keys failed".into())
    }
}

// The primary key fingerprint behind a good signature, or None if the
// signature doesn't verify against the imported keys. VALIDSIG's last
// field is the primary fingerprint even when a subkey made the signature.
fn trusted_signing_key(home: &Path, signature: &Path, manifest: &Path) -> Option<String> {
    let output = Command::new(GPG)
        .env("GNUPGHOME", home)
        .args(["--batch", "--status-fd", "1", "--verify"])
        .arg(signature)
        .arg(manifest)
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .find(|line| line.starts_with("[GNUPG:] VALIDSIG "))
        .and_then(|line| line.split_whitespace().last())
        .map(str::to_owned)
}

// The working tree's copy when present, the flake's otherwise.
fn existing_dir(working_tree: &str, flake_copy: &str) -> PathBuf {
    let local = PathBuf::from(working_tree);
    if local.is_dir() {
        local
    } else {
        PathBuf::from(flake_copy)
    }
}

fn sorted_subdirs(dir: &Path) -> Result<Vec<PathBuf>, String> {
    let mut dirs: Vec<PathBuf> = fs::read_dir(dir)
        .map_err(|e| format!("cannot read {}: {e}", dir.display()))?
        .filter_map(|entry| entry.ok().map(|e| e.path()))
        .filter(|path| path.is_dir())
        .collect();
    dirs.sort();
    Ok(dirs)
}

fn file_name(path: &Path) -> String {
    path.file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .into_owned()
}
