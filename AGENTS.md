<!-- BEGIN agent-playbook (project: defrag-nix, target: zed) — generated, do not edit -->

# Agent rules

Generated from `.playbook/project.conf` + `models/zed`.
Each rule's source file is named in the comment above its heading.
To change a rule, change the rule — not this block.

## Read code and history with the agent tools, not with the shell
<!-- rule: rules/org/defrag/agent-tools -->

- Reading code with `rg`, `grep`, `sed`, `cat`, `head` or `wc` → `at-peek`. Installed crate source or
  build-script output → `at-crate`. History or working-tree state → `at-recall`. A Cardano chain
  question → `at-cardano`. All four are read-only and say what they did not show.
- `git show` and `git blame` have no `at-recall` verb yet — say so rather than reaching for them.

| Instead of | Use |
| --- | --- |
| `rg`, `grep` | `at-peek search <pattern> [path…]` |
| `sed -n '40,60p' <file>`, `head`, `cat` | `at-peek slice <file>:40-60` |
| `wc -l`, `ls -l`, `stat` | `at-peek stat <path>…` |
| `grep -rn … ~/.cargo/…` | `at-crate search <pattern> <crate>` · `slice` · `where` |
| `git status` | `at-recall state` |
| `git diff` | `at-recall diff [<rev>] [<path>…]` — `--patch` for hunks |
| `git log` | `at-recall log [<rev>] [<path>…]` |
| PR archaeology | `at-recall pr [--base <rev>]` |
| `curl …koios…` | `at-cardano <noun> [<aspect>]` · `query` · `run --scenario` |
| anything not listed | `at-describe` — the catalogue, one screen |

- `which at-peek` empty → `direnv exec . at-peek <verb>`. Never wrap an `at-*` call in
  `nix develop`: the evaluation is paid before the read starts (7.5 s vs 5 ms).
- Output that was cut says so, and a `# next:` line is the next read — run it as printed.
  Never `| tail -3`: the bound is the part that makes the answer reportable.
- These tools are for understanding, not for preparing an edit. Read the file with the editor
  tools before changing it.
- The `inspect-code` skill has the flags, exit semantics, recipes and traps; the `at-cardano`
  skill has the chain verbs. Invoke one when a read is not a plain `search` or `slice`.


## Toggle local [patch] blocks as a unit
<!-- rule: rules/org/defrag/patch-blocks -->

Engaging a local `[patch]` override block in `Cargo.toml` — to consume a sibling working tree
instead of the pinned git rev → uncomment the **entire `[patch."…"]` table as a unit**.

- Never selectively un-comment individual entries.
- Re-commenting before commit → re-comment the whole block. Never leave a partial active block
  behind.

Selective edits cause two failures:

- A line ends up in both the active and the still-commented copy → duplicate-key error
- A transitively-required crate is left commented → unrelated workers break


## Keep logic pure — runtime bridges come in pairs
<!-- rule: rules/org/defrag/runtime-pairs -->

**wasm-bindgen code can never run under macroquad/miniquad** — the miniquad `gl.js` runtime has no
wasm-bindgen glue; browser interop goes through the miniquad plugin protocol (`sapp_jsutils`)
instead. Permanent, not a version issue.

- Runtime-specific bridges come in pairs: `wallet-core` for wasm-bindgen frontends,
  `wallet-miniquad` for macroquad games. egui-widgets and macroquad-widgets do not interchange.
- Keep logic in small pure crates — no wasm-bindgen, no I/O, no runtime deps — so the same crate
  can be consumed from a macroquad game, a wasm-bindgen frontend (Leptos) **and** a Cloudflare
  worker. Push runtime bindings to thin edge crates.
- Macroquad target → check a dependency's transitive tree for wasm-bindgen before adding it. A
  native `cargo tree` is blind to this; the target flag is required:

```sh
nix develop -c cargo tree --target wasm32-unknown-unknown -p <crate>
```

- WASM build → minimise the features enabled on a wasm32 target. Default features are chosen for a
  native build, so a wasm consumer inherits capabilities it cannot use; a feature that pulls in a
  system library fails at link time, not at the crate that introduced it. Check the transitive
  tree, not the direct dependency.


## Never drive a terminal UI with tmux — use tui-shot or the crate's harness
<!-- rule: rules/org/defrag/tui-capture -->

**Never drive a TUI with tmux.** `tmux` is a generic executor: approving it approves `send-keys`
into any pane and `attach` to sessions it did not start, so it cannot be granted per-prefix.

| Want | Use |
| --- | --- |
| a live screen, keys, a resize, a narrow terminal | `tui-shot` — one PTY, one workspace binary target, no shell |
| a frame while iterating on the renderer | the crate's own `TestBackend` harness |
| the second check | `tui-shot`'s `<out>.json` · the harness's `run.json` |

```sh
tui-shot run --scenario .tmp/factotum.dsl
tui-shot check --scenario .tmp/factotum.dsl
```

- Wait for content, never sleep: `wait … contains=`, `absent=`, `idle=`, `exit=true`.
- Not: a hand-started tmux session, `send-keys`, `capture-pane`, or a fixed `sleep`.
- The `tui-shot` skill has the grammar, fields and failures.


## Bulk uploads to R2 run on the arm box, not the workstation
<!-- rule: rules/org/defrag/bulk-uploads-run-on-the-arm-box -->

**Build and verify on the workstation; run the transfer on the arm box.** The workstation's
uplink sets the ceiling for a GB-scale write to R2.

| step | where |
| --- | --- |
| build the artifact · dry-run the publish · check the bytes | workstation |
| the `rclone`/`publish` run that moves GB to R2 | arm box |

- `--run`-gated publishers print their exact `rclone` invocation without `--run`; copy that line
  to the box rather than re-running it here.
- The box already holds the chunk store, so an artifact derived from chunks is rebuilt there,
  never copied to it.
- Native build on the box, not `aarch64-unknown-linux-musl`: the musl build is slower.


## Commit and PR conventions for this ecosystem
<!-- rule: rules/org/defrag/commit-conventions -->

Applies only when asked to prepare a commit or draft a PR — see
`core/git-is-the-users-domain` for the standing rule
that you do not commit uninvited.

#### Commits

Prefix with a type, then the change, then the PR number:

```
feature: indexer retries (#164)
fix: wrap the stake address in the compact breakpoint (#171)
chore: bump pallas to 0.31 (#168)
```

- Prefixes are `feature:`, `chore:`, `fix:` · never `feat:`/`refactor:`/`perf:` — match the
  existing log, not conventional-commits defaults.
- Append the PR number as `(#164)`.
- One concern per commit — never bundle a formatting sweep with a behaviour change.
- Imperative, present tense: "wrap the address", not "wrapped the address".

#### Pull requests

- Include a concise summary, the linked issue, test coverage for the change, and example output or
  screenshots where they apply.
- Note any feature flags involved (`native`, `wasm`).
- `[skip ci]` → needs a clear justification in the description, and any manual deployment or data
  task named (CI cannot catch what CI did not run).


## Prefer rustls over OpenSSL
<!-- rule: rules/org/defrag/rustls-over-openssl -->

Use `rustls` rather than OpenSSL for TLS in any new dependency or HTTP client, and when choosing
between two crates that differ only in which they pull in.

- Check a crate's default features for `native-tls` or `openssl-sys`; prefer a `rustls` feature
  where one exists:

```toml
reqwest = { version = "0.12", default-features = false, features = ["rustls-tls", "json"] }
```

- Check the transitive tree, not the crate you typed — OpenSSL usually arrives because a crate's
  *default* features pulled it in:

```sh
nix develop -c cargo tree --target wasm32-unknown-unknown -p <crate> | grep -e openssl -e native-tls
```

<!-- END agent-playbook -->
