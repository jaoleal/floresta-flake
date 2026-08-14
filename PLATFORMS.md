# Android Platform Support

## Floresta Android binaries

floresta-nix cross-compiles Floresta for Android using the NDK prebuilt
toolchain. Available on **x86_64-linux** only: the prebuilt toolchain is
the linux-x86_64 one, and nixpkgs' androidndk-pkgs does not map aarch64
build hosts at all.

These are cross targets of the master tree, so they hang off the `master`
release. Each is one build of the workspace for that ABI, carrying the same
artifacts the native build does: `florestad` and `floresta-cli` under `bin/`,
the `libfloresta` shared and static libraries under `lib/`.

| Package                  | Target               |
| ------------------------ | -------------------- |
| `master.aarch64-android` | aarch64 (arm64-v8a)  |
| `master.armv7a-android`  | armv7a (armeabi-v7a) |
| `master.x86_64-android`  | x86_64 (emulator)    |

```bash
nix build .#master.aarch64-android
ls result/lib
```

---

## Toolchain

`libbitcoinkernel` is built from source for the Android target by
`libbitcoinkernel-sys`'s `build.rs` (via the `cc` crate), using the NDK
clang wrapper that floresta-nix points cargo at. No prebuilt static
library is involved.

- **NDK version:** `27.2.12479018`
- **ANDROID_API_LEVEL:** `24` — this becomes the consumer's effective
  `minSdk` floor. Linking at a lower API level may produce missing-symbol
  errors.
