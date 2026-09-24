# defrag-nix

Shared development shells for Defrag workspaces and repos.

## Available shells

- `rust-stable`: General Rust development shell.
- `rust-wasm`: Rust + WASM shell with `trunk`, `wasm-pack`, `wasm-bindgen-cli`, and `binaryen`.
- `cloudflare-worker`: Rust shell with `wrangler` for Cloudflare Worker development.
- `cardano-aiken`: Rust shell with `aiken` for Cardano contract work.
- `web-node`: Rust shell with `nodejs_22` for repos that also carry web tooling.
- `rust-worker-stack`: Shared Defrag workspace shell with Rust, WASM, Node, Wrangler, Aiken, the Mithril client, and shiku tooling.
- `infra`: Terraform/OpenTofu + cloudflared + Rust + shiku deploy tooling for the infra repo.

### shiku

The `infra` and `rust-worker-stack` shells provide a `shiku` command that runs the CLI straight from the local checkout (`~/code/defrag/shiku`, override with `SHIKU_SRC`) via `cargo run` — it rebuilds automatically whenever the shiku source changes, so it's always current with no reinstall step. `cargo-zigbuild`, `zig`, and `rsync` ride along for the cross-compile + release-upload path shiku drives.

### mithril-client

`rust-worker-stack` also carries the [Mithril](https://mithril.network) client CLI, for pulling a certified Cardano immutable-db snapshot:

```sh
mithril-client cardano-db download <digest> --download-dir <dir> --start <from> --end <to>
```

It is upstream's **prebuilt release binary**, pinned by hash in `nix/mithril-client.nix` and checked against the release's signed `CHECKSUM.asc`, rather than a build from source: the CLI crate is not published to crates.io, and upstream already ships, signs and tests the binary. The distribution is pinned (currently `2630.1-hotfix`, reporting `0.13.20`) — that tag is what carries the networks-compatibility statement, so it is the thing to bump. Upstream dropped `x86_64-darwin` in `IntersectMBO/mithril#3238`; that system's shell simply has no `mithril-client`, and `nix build .#mithril-client` does not exist there.

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
