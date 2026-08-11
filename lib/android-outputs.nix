# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Android support for floresta-nix: the NDK cross-compilation setup and
# the cross-compiled Floresta binaries/libraries it produces.
{
  pkgs,
  inputs,
  system,
  masterSrc,
}:

let
  inherit (pkgs) lib;

  # Only x86_64-linux can drive the NDK: the prebuilt toolchain this file
  # points cargo at is the linux-x86_64 one (see ndkToolchain below), and
  # nixpkgs' androidndk-pkgs does not map aarch64 build hosts at all.
  ndkSupported = system == "x86_64-linux";

  # Android NDK configuration.
  androidConfig = {
    platformVersions = [ "34" ];
    ndkVersion = "27.2.12479018";
  };

  # Build Floresta for Android by cross-compiling through Cargo's --target
  # flag and the NDK linker, without using nixpkgs' crossSystem machinery.
  # This avoids the NDK version mismatch in nixpkgs' cross stdenv bootstrap.
  #
  # Requires libbitcoinkernel-sys >= 0.3.0, whose build.rs drives cmake
  # with the NDK's android.toolchain.cmake to build libbitcoinkernel for
  # the target ABI.
  #
  # abi:        ABI name carried in the package names (e.g. "aarch64-android")
  # rustTarget: Rust target triple (e.g. "aarch64-linux-android")
  mkAndroidBuild =
    abi: rustTarget:
    let
      nativePkgs = import inputs.nixpkgs {
        inherit system;
        config.android_sdk.accept_license = true;
        config.allowUnfree = true;
      };
      fenixPkgs = inputs.fenix.packages.${system};

      composition = nativePkgs.androidenv.composeAndroidPackages {
        inherit (androidConfig) platformVersions;
        ndkVersions = [ androidConfig.ndkVersion ];
        includeNDK = true;
      };
      sdk = composition.androidsdk;
      ndk = "${sdk}/libexec/android-sdk/ndk/${androidConfig.ndkVersion}";

      # Build a Rust toolchain that includes rust-std for the Android
      # target.  Without this, rustc can't find `core` / `std` for the
      # cross target.
      rustToolchain = fenixPkgs.combine [
        fenixPkgs.stable.rustc
        fenixPkgs.stable.cargo
        fenixPkgs.stable.rust-src
        fenixPkgs.stable.rust-std
        fenixPkgs.targets.${rustTarget}.stable.rust-std
      ];
      androidRustPlatform = nativePkgs.makeRustPlatform {
        cargo = rustToolchain;
        rustc = rustToolchain;
      };

      # NDK clang triple: armv7 uses "armv7a-linux-androideabi",
      # all others match the Rust target triple.
      ndkClangTriple =
        if builtins.match "armv7.*" rustTarget != null then "armv7a-linux-androideabi" else rustTarget;

      ndkToolchain = "${ndk}/toolchains/llvm/prebuilt/linux-x86_64";
      ndkClang = "${ndkToolchain}/bin/${ndkClangTriple}24-clang";

      # Wrapper around the NDK clang that works around an armv7
      # compiler_builtins issue.  The pre-compiled libcompiler_builtins
      # for armv7-linux-androideabi ships ARM EABI symbols tagged with
      # @@LIBC_N (e.g. __aeabi_memcpy@@LIBC_N).  When lld links a
      # shared library it errors on symbols whose version node (LIBC_N)
      # is not defined — unless the symbol has local visibility.
      # Passing --exclude-libs,ALL marks every symbol pulled from
      # static archives as local, which suppresses the error.
      #
      # libbitcoinkernel-sys' build.rs emits the same flag, but cargo
      # applies a dependency's rustc-link-arg only to that crate's own
      # link targets — never to florestad / floresta-cli / libfloresta.
      ndkLinker = nativePkgs.writeShellScript "ndk-clang-wrapper" ''
        exec ${ndkClang} "-Wl,--exclude-libs,ALL" "$@"
      '';

      # Cargo env var prefix for the target (e.g. CARGO_TARGET_AARCH64_LINUX_ANDROID)
      cargoTargetPrefix = "CARGO_TARGET_${
        builtins.replaceStrings [ "-" ] [ "_" ] (nativePkgs.lib.toUpper rustTarget)
      }";
    in
    import ./floresta-build.nix {
      pkgs = nativePkgs;
      inherit (nativePkgs) lib;
      defaultSrc = masterSrc;
      rustPlatform = androidRustPlatform;

      # The ABI is what tells these builds apart, so it belongs in the
      # package name itself.
      pnameSuffix = "-${abi}";

      # Disable the default cargoBuildHook / cargoInstallHook — they
      # don't handle cross-compilation via --target properly.
      dontCargoBuild = true;

      # Explicit cargo build with --target so all crates (including
      # proc-macro / build-script crates) are compiled correctly.
      # $cargoBuildFlags is set by buildRustPackage from the Nix attribute.
      customBuildPhase = ''
        runHook preBuild
        cargo build \
          $cargoBuildFlags \
          --target ${rustTarget} \
          --offline \
          --release
        runHook postBuild
      '';

      # Install binaries / libraries from the target-specific output dir.
      customInstallPhase = ''
        runHook preInstall
        mkdir -p $out/bin $out/lib
        local _releaseDir=target/${rustTarget}/release
        # Copy binaries (florestad, floresta-cli)
        for bin in florestad floresta-cli; do
          if [ -f "$_releaseDir/$bin" ]; then
            cp "$_releaseDir/$bin" $out/bin/
          fi
        done
        # Copy libraries (libfloresta)
        for lib in "$_releaseDir"/libfloresta*.a "$_releaseDir"/libfloresta*.so; do
          if [ -f "$lib" ]; then
            cp "$lib" $out/lib/
          fi
        done
        runHook postInstall
      '';

      extraEnvVars = {
        ANDROID_HOME = "${sdk}/libexec/android-sdk";
        ANDROID_NDK_HOME = ndk;
        ANDROID_NDK_ROOT = ndk;
        CARGO_BUILD_TARGET = rustTarget;
        "${cargoTargetPrefix}_LINKER" = ndkLinker;

        # Tell the `cc` crate (used by secp256k1-sys etc.) to use the NDK
        # clang and llvm-ar for C code compiled for the Android target.
        # Without this, cc::Build picks the host compiler and produces
        # x86_64 object files that the aarch64/armv7 linker rejects.
        "CC_${builtins.replaceStrings [ "-" ] [ "_" ] rustTarget}" = ndkClang;
        "AR_${builtins.replaceStrings [ "-" ] [ "_" ] rustTarget}" = "${ndkToolchain}/bin/llvm-ar";
      };
      extraNativeBuildInputsGlobal = [ sdk ];
    };
  # Cross-compiled Floresta for Android — requires the NDK cross
  # toolchain, which nixpkgs only supports on x86_64 hosts.
in
lib.optionalAttrs ndkSupported (
  # ABI -> Rust target triple.  x86_64 is the emulator ABI; the other two
  # are the device ABIs.
  lib.mapAttrs
    (
      abi: rustTarget:
      # Carry the target the build was compiled for, so consumers can ask the
      # package instead of inferring it from the attribute name.  Attached
      # with // rather than overrideAttrs: floresta-build.nix replaces
      # passthru.overrideAttrs with a self-recursive definition.
      (mkAndroidBuild abi rustTarget).default // { inherit rustTarget; }
    )
    {
      aarch64-android = "aarch64-linux-android";
      armv7a-android = "armv7-linux-androideabi";
      x86_64-android = "x86_64-linux-android";
    }
)
