# defrag-nix

Shared development shells for Defrag workspaces and repos.

## Available shells

- `rust-stable`: General Rust development shell.
- `rust-wasm`: Rust + WASM shell with `trunk`, `wasm-pack`, `wasm-bindgen-cli`, and `binaryen`.
- `cloudflare-worker`: Rust shell with `wrangler` for Cloudflare Worker development.
- `cardano-aiken`: Rust shell with `aiken` for Cardano contract work.
- `midnight`: Rust shell with the Compact compiler (`compactc`) and `zkir-v3` for Midnight contract work.
- `web-node`: Rust shell with `nodejs_22` for repos that also carry web tooling.
- `rust-worker-stack`: Shared Defrag workspace shell with Rust, WASM, Node, Wrangler, Aiken, the Mithril client, and shiku tooling.
- `infra`: Terraform/OpenTofu + cloudflared + Rust + shiku deploy tooling for the infra repo.
- `android-tools`: Google's `adb` and `fastboot` for physical Android devices — no SDK or NDK.

### compactc (Midnight)

`midnight` provides `compactc` and `zkir-v3` from the `RomarQ/compact` fork, pinned to the
revision `midnight-rs` tests (`COMPACT_REV = fa2181fbc6dac2135defdb4f55ce10d8332185d5`).
The fork is required because `--analyzed-ir` writes the `compiler/analyzed-ir.sexp` artifact the
Rust SDK's typed bindings and circuit interpreter consume; the official compiler does not emit
it. Bump the pin and the SDK's `COMPACT_REV` together.

```sh
nix develop .#midnight
compactc --help | grep analyzed-ir
compactc --skip-zk --analyzed-ir contract.compact compiled/
```

For the compiler alone without the shell's `zkir-v3` closure:
`nix shell .#compactc -c compactc --version`.

The first build is heavy: `compactc` is compiled from source with Chez, and the `midnight`
shell also builds `zkir-v3` (a larger Rust closure — 233 derivations in the dry run). `defrag-nix`
declares IOG's Hydra cache (`cache.iog.io`) because Compact's own flake does, but Nix honours it
only for a trusted user or with `--accept-flake-config`; if it is ignored, expect a long first
build. Run `nix build .#compactc` once, then entering the shell is cheap.

The compiler is also re-exported as `packages.compactc` and `packages.zkir-v3`, so a consumer
can add either to its own shell without taking the whole `midnight` shell. `compactc` invokes
`zkir-v3` for key generation, so a full compile needs both on `PATH`; the `midnight` shell has
both. It is deliberately **not** in `rust-worker-stack`: the compiler closure is large and most
repos do not need it.

### shiku

The `infra` and `rust-worker-stack` shells provide a `shiku` command that runs the CLI straight from the local checkout (`~/code/defrag/shiku`, override with `SHIKU_SRC`) via `cargo run` — it rebuilds automatically whenever the shiku source changes, so it's always current with no reinstall step. `cargo-zigbuild`, `zig`, and `rsync` ride along for the cross-compile + release-upload path shiku drives.

### worker-build-gate

`rust-worker-stack` carries `worker-build-gate`, which serialises worker-build's shared tool-cache update. worker-build 0.7.x/0.8.x deletes every cached version of a tool before downloading it, into a machine-global cache, with no lock. Two builds starting cold from different directories delete each other's wasm-bindgen download, and the loser fails with:

```
Error: Running the wasm-bindgen CLI
Caused by: No such file or directory (os error 2)
```

The cache is per machine, not per repo, so the gate locks beside it rather than beside a checkout:

```sh
worker-build-gate -- worker-build --release
```

The gate is a single-file Rust binary using `std::fs::File::lock`, so the protection is an OS file lock on both macOS and Linux. The kernel releases it when the process exits, so a killed build leaves no stale lock; the lock file itself stays in place. (macOS's `/usr/bin/lockf` unlinks the lock file on exit, which lets a third process lock a fresh inode and run beside an existing holder — that is why the gate does not use it.) The lock file is `~/Library/Caches/worker-build/.build.lock` on macOS and `${XDG_CACHE_HOME:-$HOME/.cache}/worker-build/.build.lock` on Linux; worker-build's `remove_all_versions` only removes the `wasm-bindgen-*`, `wasm-opt-*` and `esbuild-*` directories, so it survives cache clearing. `nix flake check` runs a two-process serialisation test for it.

### mithril-client

`rust-worker-stack` also carries the [Mithril](https://mithril.network) client CLI, for pulling a certified Cardano immutable-db snapshot:

```sh
mithril-client cardano-db download <digest> --download-dir <dir> --start <from> --end <to>
```

It is upstream's **prebuilt release binary**, pinned by hash in `nix/mithril-client.nix` and checked against the release's signed `CHECKSUM.asc`, rather than a build from source: the CLI crate is not published to crates.io, and upstream already ships, signs and tests the binary. The distribution is pinned (currently `2630.1-hotfix`, reporting `0.13.20`) — that tag is what carries the networks-compatibility statement, so it is the thing to bump. Upstream dropped `x86_64-darwin` in `IntersectMBO/mithril#3238`; that system's shell simply has no `mithril-client`, and `nix build .#mithril-client` does not exist there.

### android-tools

`android-tools` is the opt-in shell for physical Android devices: Google's platform-tools
(`adb` and `fastboot`), and nothing else. It is not in any other shell, and it carries no
SDK, NDK or build-tools.

It is deliberately **the same platform-tools build as montager's `.#android` shell**: both
compose `androidenv` from the same nixpkgs rev (montager imports
`defrag-nix.inputs.nixpkgs`), currently platform-tools 37.0.0. Laziness means only the
platform-tools derivation is realised here — the SDK and NDK are not fetched unless
something references them. That is the one adb version the real devices have been tested
against, rather than a second, older one chosen for a smaller closure.

```sh
nix develop .#android-tools -c adb devices
nix develop .#android-tools -c adb pair <host>:<port>   # wireless debugging
```

Building an APK needs the SDK, NDK and Android Rust std, which stay in the consumer that
builds one — montager's `.#android` shell:

```sh
nix develop ~/code/defrag/montager#android -c <build command>
```

On macOS, USB debugging needs a data cable and the on-screen authorisation. Wireless
debugging's port changes when the device sleeps, and macOS's Local Network permission can
block `adb` (while `curl` still works) — see montager's `docs/design/ANDROID_TV_PLAYER.md`.

## Local usage

From a consumer repo:

```sh
nix develop /Users/damo/code/defrag/defrag-nix#rust-worker-stack
```

Or from inside `defrag-nix`:

```sh
nix develop .#rust-worker-stack
```

## Consumer flake example

Use a local path while iterating:

```nix
{
  inputs.defrag-nix.url = "path:../defrag-nix";

  outputs = { self, defrag-nix, ... }: {
    devShells.aarch64-darwin.default =
      defrag-nix.devShells.aarch64-darwin.rust-worker-stack;
  };
}
```

Or pin the GitHub repo:

```nix
{
  inputs.defrag-nix.url = "github:defrag-au/defrag-nix";

  outputs = { self, defrag-nix, ... }: {
    devShells.aarch64-darwin.default =
      defrag-nix.devShells.aarch64-darwin.rust-worker-stack;
  };
}
```

## Notes

- Keep shared shells focused on common workspace tooling.
- Compose project shells from smaller reusable shell layers.
- Add repo-specific overrides in the consumer repo when one project diverges.
- Avoid turning this into one giant universal shell for every language and runtime.
