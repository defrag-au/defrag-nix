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
  };

  outputs =
    { nixpkgs, fenix, ... }:
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
      mkShells =
        pkgs:
        let
          rustToolchain = rustToolchainFor pkgs.stdenv.hostPlatform.system;
          packageSets = rec {
            shared-cli = with pkgs; [
              curl
              git
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

            rust-wasm = with pkgs; [
              binaryen
              trunk
              wasm-bindgen-cli
              wasm-pack
            ];

            cloudflare-worker = with pkgs; [
              wrangler
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
                    ]
                    ++ packageGroups
                  )
                );

              shellHook = ''
                export CARGO_TERM_COLOR=always
                export RUST_BACKTRACE=1
                export PKG_CONFIG_PATH="${pkgs.openssl.dev}/lib/pkgconfig''${PKG_CONFIG_PATH:+:}$PKG_CONFIG_PATH"
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
            packageGroups = [
              "rust-stable"
              "rust-wasm"
              "cloudflare-worker"
              "web-node"
              "cardano-aiken"
            ];
            extraShellHook = ''
              echo "rust-worker-stack shell ready"
              echo "Includes Rust, WASM, Node, Wrangler, and Aiken tooling."
            '';
          };

          infra = mkDevShell {
            name = "infra";
            packageGroups = [ "infra" ];
            extraShellHook = ''
              echo "infra shell ready"
              echo "Includes terraform, opentofu, cloudflared, python3, jq."
            '';
          };
        };
    in
    {
      devShells = forAllSystems (system: (mkShells (pkgsFor system)) // {
        default = (mkShells (pkgsFor system)).rust-worker-stack;
      });
    };
}
