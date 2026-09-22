{
  description = "Shared Defrag development shells";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    # fenix provides per-target rust-std components — required
    # for `wasm32-wasip2` (mitos wasm modules) which nixpkgs's
    # bundled rustc doesn't ship out of the box.
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # The agent toolkit (at-peek, at-recall, at-describe) is built and packaged by
    # agent-playbook itself; this flake only wires that package into shells. The derivation
    # used to live here, which made a public repository's build depend on this one.
    #
    # `nixpkgs.follows` and `fenix.follows` so the toolkit is built by the same nixpkgs and
    # the same toolchain as everything else here, rather than a second copy of either being
    # evaluated for it. A flake input sees COMMITTED state, so a toolkit change reaches a
    # shell after it is committed there and `nix flake update agent-playbook` is run here.
    agent-playbook = {
      url = "github:defrag-au/agent-playbook";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.fenix.follows = "fenix";
    };
  };

  outputs =
    { nixpkgs, fenix, agent-playbook, ... }:
    let
      lib = nixpkgs.lib;
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = lib.genAttrs systems;
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
      # Combined rust toolchain with all targets the workspace
      # currently builds for. Fenix lets us bolt extra stdlib
      # variants onto the stable rustc — host (native) +
      # wasm32-unknown-unknown (CF Worker frontends) +
      # wasm32-wasip2 (mitos modules).
      rustToolchainFor =
        system:
        let
          fenixPkgs = fenix.packages.${system};
        in
        fenixPkgs.combine [
          fenixPkgs.stable.cargo
          fenixPkgs.stable.clippy
          fenixPkgs.stable.rust-analyzer
          fenixPkgs.stable.rustc
          fenixPkgs.stable.rustfmt
          fenixPkgs.stable.rust-src
          fenixPkgs.targets.wasm32-unknown-unknown.stable.rust-std
          fenixPkgs.targets.wasm32-wasip2.stable.rust-std
          # Static musl target for native services deployed via shiku
          # (cross-compiled to aarch64-unknown-linux-musl with cargo-zigbuild).
          fenixPkgs.targets.aarch64-unknown-linux-musl.stable.rust-std
        ];
      # The agent toolkit's derivation now lives in agent-playbook, beside the source it
      # builds, and arrives here as a package — see the `agent-playbook` input above and
      # `packageSets.agent-tools` below. Building it here meant a public repository's
      # build depended on this one.
      mkShells =
        pkgs:
        let
          rustToolchain = rustToolchainFor pkgs.stdenv.hostPlatform.system;
          packageSets = rec {
            shared-cli = with pkgs; [
              curl
              git
              gh
              jq
              just
              pkg-config
            ];

            native-libs =
              with pkgs;
              [
                openssl
                sqlite
              ]
              ++ lib.optionals stdenv.isDarwin [ libiconv ];

            # Fenix-managed toolchain so we can pick up
            # wasm32-wasip2 stdlib (used by mitos wasm modules).
            # Bundled cargo/clippy/rustc/rustfmt come from the
            # same combined derivation; no separate installs.
            rust-stable = [ rustToolchain ];

            # Cargo subcommands, included in every shell. These previously
            # resolved out of ~/.cargo/bin: cargo searches $CARGO_HOME/bin for
            # `cargo-*` regardless of PATH, so `cargo nextest` et al silently
            # ran unpinned, non-nix binaries even inside a dev shell.
            rust-dev-tools = with pkgs; [
              cargo-all-features
              cargo-bloat
              cargo-expand
              cargo-insta
              cargo-nextest
              cargo-release
              cargo-workspaces
            ];

            rust-wasm = with pkgs; [
              binaryen
              trunk
              wasm-bindgen-cli
              wasm-pack
              # Frontend build tooling (leptos + stylance CSS modules) and
              # wasm inspection — twiggy/wasm-tools for chasing bundle size.
              cargo-leptos
              stylance-cli
              twiggy
              wasm-tools
            ];

            cloudflare-worker = with pkgs; [
              wrangler
              # workers-rs build step; wrangler.toml would otherwise
              # `cargo install worker-build` on every clean build.
              worker-build
            ];

            web-node = with pkgs; [
              nodejs_22
            ];

            cardano-aiken = with pkgs; [
              aiken
            ];

            infra = with pkgs; [
              terraform
              opentofu
              python3
              cloudflared
              openssh
              rsync
            ];

            # Shiku deploy tooling. The `shiku` command runs the CLI from the
            # local checkout via `cargo run`, so it always reflects the latest
            # source in ~/code/defrag/shiku (override with SHIKU_SRC) — cargo's
            # incremental build means it recompiles only when shiku changed.
            # zigbuild/zig do the aarch64-musl cross-compiles shiku drives;
            # rsync ships releases (macOS openrsync is too old).
            shiku-deploy =
              (with pkgs; [
                cargo-zigbuild
                zig
                rsync
              ])
              ++ [
                (pkgs.writeShellScriptBin "shiku" ''
                  SHIKU_SRC="''${SHIKU_SRC:-$HOME/code/defrag/shiku}"
                  if [ ! -f "$SHIKU_SRC/Cargo.toml" ]; then
                    echo "shiku source not found at $SHIKU_SRC (set SHIKU_SRC to override)" >&2
                    exit 1
                  fi
                  exec cargo run --quiet --manifest-path "$SHIKU_SRC/Cargo.toml" -p shiku -- "$@"
                '')
              ];

            # The agent tooling, from agent-playbook: the two read-only inspectors —
            # `at-peek` (the working tree) and `at-recall` (history and state, through `git`
            # read verbs only) — plus `at-describe` (the catalogue) and `playbook` (the rule
            # composer, which `check`/`install` a repo's managed block). No member has a write
            # path in any flag or option except `playbook install`, which writes one file it
            # names in its output.
            #
            # Every shell gets this group — see `mkDevShell` — rather than each shell asking
            # for it, because there is no shell where a read-only inspector is unwelcome.
            agent-tooling = [
              agent-playbook.packages.${pkgs.stdenv.hostPlatform.system}.agent-tools
              agent-playbook.packages.${pkgs.stdenv.hostPlatform.system}.playbook
            ];
          };
          mkDevShell =
            {
              name,
              packageGroups ? [ ],
              extraShellHook ? "",
            }:
            pkgs.mkShell {
              packages =
                lib.flatten (
                  map (group: packageSets.${group}) (
                    [
                      "shared-cli"
                      "native-libs"
                      "rust-dev-tools"
                      # In every shell, not only in the worker stack: the rule that tells an
                      # agent to reach for `at-peek`/`at-recall` names no repository, so a
                      # shell the toolkit is missing from is a rule failing where it was
                      # meant to apply. It is three read-only binaries and costs the shell
                      # nothing it can do.
                      "agent-tooling"
                    ]
                    ++ packageGroups
                  )
                );

              shellHook = ''
                export CARGO_TERM_COLOR=always
                export RUST_BACKTRACE=1
                export PKG_CONFIG_PATH="${pkgs.openssl.dev}/lib/pkgconfig''${PKG_CONFIG_PATH:+:}$PKG_CONFIG_PATH"
                ${lib.optionalString pkgs.stdenv.isDarwin ''
                  # Link wasm32 with nixpkgs' wasm-ld instead of the toolchain's
                  # own rust-lld, which is BROKEN on darwin from rustc 1.98:
                  # fenix ships it with an rpath resolving to
                  # lib/rustlib/<host>/lib, and libLLVM.dylib is not there (it
                  # sits at <toolchain>/lib), so it aborts with SIGABRT and
                  # "Library not loaded: @rpath/libLLVM.dylib".
                  #
                  # How it presents, which is the nasty part: `cargo check
                  # --target wasm32-unknown-unknown` PASSES, because checking does
                  # not link. Only a real wasm build fails — so CI (linux, fine)
                  # and every check command stay green while no one on a mac can
                  # produce a bundle, and the error reads like a broken project.
                  #
                  # Pointing dyld at the real directory also works, but only when
                  # nothing re-execs in between: a `#!/usr/bin/env bash` build
                  # script goes through SIP-protected /usr/bin/env, which STRIPS
                  # DYLD_* from the environment. CARGO_* survives, so the linker
                  # override is the one that holds through a script.
                  export CARGO_TARGET_WASM32_UNKNOWN_UNKNOWN_LINKER="${pkgs.lld}/bin/wasm-ld"
                ''}
                ${extraShellHook}
              '';
            };
        in
        {
          rust-stable = mkDevShell {
            name = "rust-stable";
            packageGroups = [ "rust-stable" ];
          };

          rust-wasm = mkDevShell {
            name = "rust-wasm";
            packageGroups = [
              "rust-stable"
              "rust-wasm"
            ];
            extraShellHook = ''
              echo "Rust + WASM shell ready"
            '';
          };

          cloudflare-worker = mkDevShell {
            name = "cloudflare-worker";
            packageGroups = [
              "rust-stable"
              "cloudflare-worker"
            ];
            extraShellHook = ''
              echo "Cloudflare Worker shell ready"
            '';
          };

          cardano-aiken = mkDevShell {
            name = "cardano-aiken";
            packageGroups = [
              "rust-stable"
              "cardano-aiken"
            ];
            extraShellHook = ''
              echo "Cardano + Aiken shell ready"
            '';
          };

          web-node = mkDevShell {
            name = "web-node";
            packageGroups = [
              "rust-stable"
              "web-node"
            ];
            extraShellHook = ''
              echo "Web + Node shell ready"
            '';
          };

          rust-worker-stack = mkDevShell {
            name = "rust-worker-stack";
            # `agent-tools` is not listed: it is in the base groups every shell gets now.
            packageGroups = [
              "rust-stable"
              "rust-wasm"
              "cloudflare-worker"
              "web-node"
              "cardano-aiken"
              "shiku-deploy"
            ];
            extraShellHook = ''
              echo "rust-worker-stack shell ready"
              echo "Includes Rust, WASM, Node, Wrangler, Aiken, shiku and agent tooling."
            '';
          };

          # Rust toolchain included: the infra repo carries Rust service
          # crates (services/claude-agent/bot) and shiku deploys run from it.
          infra = mkDevShell {
            name = "infra";
            packageGroups = [
              "rust-stable"
              "infra"
              "shiku-deploy"
            ];
            extraShellHook = ''
              echo "infra shell ready"
              echo "Includes terraform, opentofu, cloudflared, python3, jq, rust, and shiku."
            '';
          };
        };
    in
    {
      # Re-exported from agent-playbook, so `nix build .#agent-tools`, `nix build .#playbook`
      # and a profile install keep working from here without a second definition of either.
      packages = forAllSystems (system: {
        inherit (agent-playbook.packages.${system}) agent-tools playbook;
      });

      devShells = forAllSystems (system: (mkShells (pkgsFor system)) // {
        default = (mkShells (pkgsFor system)).rust-worker-stack;
      });
    };
}
