# The Mithril client CLI — pulls a certified Cardano immutable-db snapshot
# (`mithril-client cardano-db download <digest> --start N --end M`).
#
# Fetched as upstream's PREBUILT release binary rather than built from source: the
# CLI crate (`mithril-client-cli`) is not published to crates.io, so a source build
# means `fetchFromGitHub` at a release tag plus the whole rustls/mithril-common
# dependency tree — minutes of build for a binary upstream already ships, signs and
# tests. The hash below pins the released bytes, checked against the release's own
# signed `CHECKSUM.asc`.
#
# There is no x86_64-darwin asset: upstream dropped that platform in
# IntersectMBO/mithril#3238. `meta.platforms` records that and consumers filter on it
# — see `supportsMithril` in flake.nix.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
}:

let
  # Upstream releases are named by DISTRIBUTION (`2630.1-hotfix`), not by crate
  # version; the client inside this one reports `0.13.20+3f6cb73`. The distribution
  # is what carries the networks-compatibility statement, so it is the thing to bump.
  distribution = "2630.1-hotfix";

  version = "0.13.20";

  assets = {
    aarch64-darwin = {
      name = "macos-arm64";
      hash = "sha256-7HJT1is3eFA+opGk+1ZlEHejCBjuqOVcr8TYLREcSlE=";
    };
    aarch64-linux = {
      name = "linux-arm64";
      hash = "sha256-NbqHGgylSMc9bcTm/JHnsKSIP8TLP/6oA+vsaUsbrC0=";
    };
    x86_64-linux = {
      name = "linux-x64";
      hash = "sha256-brdF/fEk+tPZPOZFDEXU+29ri67YrsEMg8EQMb7HDsg=";
    };
  };

  asset =
    assets.${stdenv.hostPlatform.system}
      or (throw "mithril-client ${version} has no prebuilt binary for ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation (finalAttrs: {
  pname = "mithril-client";
  inherit version;

  src = fetchurl {
    url = "https://github.com/IntersectMBO/mithril/releases/download/${distribution}/mithril-${distribution}-${asset.name}.tar.gz";
    hash = asset.hash;
  };

  # The tarball holds the aggregator, signer, relay and client side by side, with
  # `mithril-client` at the root. Upstream's own installer extracts exactly that one
  # member, and so do we.
  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    tar -xzf $src -C $out/bin mithril-client
    chmod +x $out/bin/mithril-client
    runHook postInstall
  '';

  # The linux assets are glibc-linked (upstream refuses hosts below glibc 2.35), so the
  # loader path and RPATH are rewritten for the store. Darwin binaries link only system
  # frameworks and need nothing.
  nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];
  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [ stdenv.cc.cc.lib ];

  # The darwin assets carry an ad-hoc code signature and the arm64 loader checks it;
  # `strip` would invalidate the signature and the binary would be killed on launch.
  dontStrip = true;

  meta = {
    description = "Client CLI for the Mithril certification network (Cardano snapshots)";
    homepage = "https://mithril.network";
    changelog = "https://github.com/IntersectMBO/mithril/releases/tag/${distribution}";
    license = lib.licenses.asl20;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = builtins.attrNames assets;
    mainProgram = "mithril-client";
  };
})
