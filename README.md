# defrag-nix

Shared development shells for Defrag workspaces and repos.

## Available shells

- `rust-stable`: General Rust development shell.
- `rust-wasm`: Rust + WASM shell with `trunk`, `wasm-pack`, `wasm-bindgen-cli`, and `binaryen`.
- `cloudflare-worker`: Rust shell with `wrangler` for Cloudflare Worker development.
- `cardano-aiken`: Rust shell with `aiken` for Cardano contract work.
- `web-node`: Rust shell with `nodejs_22` for repos that also carry web tooling.
- `rust-worker-stack`: Shared Defrag workspace shell with Rust, WASM, Node, Wrangler, and Aiken tooling.

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
