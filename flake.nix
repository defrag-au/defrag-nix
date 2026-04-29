{
  description = "Shared Defrag development shells";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs =
    { nixpkgs, ... }:
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
      mkShells =
        pkgs:
        let
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

            rust-stable = with pkgs; [
              cargo
              clippy
              rust-analyzer
              rustc
              rustfmt
            ];

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
        };
    in
    {
      devShells = forAllSystems (system: (mkShells (pkgsFor system)) // {
        default = (mkShells (pkgsFor system)).rust-worker-stack;
      });
    };
}
