# Shared static-site build. Installed as `build-site` by defrag-nix.
#
# Wrangler invokes a worker's [build].command from the worker's own directory,
# so this runs with $PWD set to the property/worker and leaves the bundle in
# ./dist for the worker's [assets] binding:
#
#   [build]
#   command = "build-site && build-worker"
#
# zola and tailwindcss come from this derivation (see flake.nix), so the build
# is identical in every repo and the versions are pinned once, here.
#
# The site's base template must link the stylesheet Tailwind emits:
#   <link rel="stylesheet" href="/css/site.css">
# and styles/main.css declares its scan roots via @source.
#
# SKIP_SITE=1 bypasses the build for a worker-only deploy. Wrangler's [assets]
# still expects dist/ to exist, so an empty placeholder is left behind.
#
# SITE_BASE_URL overrides config.toml's base_url for one build. A property whose
# dev environment lives on another host sets it in that environment's build
# command, so absolute URLs — og:image above all, which crawlers will not
# resolve relatively — point at a host that actually serves this bundle:
#
#   [env.dev.build]
#   command = "SITE_BASE_URL=https://dev.example.xyz build-site && build-worker"

SITE_DIR="$PWD"
DIST_DIR="$SITE_DIR/dist"
CSS_INPUT="$SITE_DIR/styles/main.css"
CSS_OUTPUT="$DIST_DIR/css/site.css"

# Resolved from cargo rather than $0 or ../..: this file is installed on PATH,
# so it has no meaningful script directory, and consumers lay their workers out
# at different depths (cnft.dev-workers at sites/<name>, theyexist/sites at
# <name>). The cargo workspace root is the one definition that holds everywhere.
WORKSPACE_ROOT="$(dirname "$(cargo locate-project --workspace --message-format plain)")"

if [[ "${SKIP_SITE:-0}" == "1" ]]; then
    echo "SKIP_SITE=1 — bypassing static-site build."
    mkdir -p "$DIST_DIR"
    exit 0
fi

# Fail loudly rather than silently producing an empty site.
for bin in zola tailwindcss; do
    if ! command -v "$bin" &> /dev/null; then
        echo "Error: '$bin' not found on PATH — it should come from the build-site derivation." >&2
        exit 1
    fi
done

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# 1. Render the Zola site into dist/ (--force allows a non-standard output dir).
if [[ -n "${SITE_BASE_URL:-}" ]]; then
    echo "🌐 Building Zola site -> dist/ (base_url $SITE_BASE_URL)"
    zola build --base-url "$SITE_BASE_URL" --output-dir "$DIST_DIR" --force
else
    echo "🌐 Building Zola site -> dist/"
    zola build --output-dir "$DIST_DIR" --force
fi

# 2. Compile Tailwind into dist/css/site.css. v4 has no config file: the theme
#    tokens and scan roots live in styles/main.css via @theme and @source.
echo "🎨 Compiling Tailwind -> dist/css/site.css"
mkdir -p "$(dirname "$CSS_OUTPUT")"
tailwindcss -i "$CSS_INPUT" -o "$CSS_OUTPUT" --minify

# 3. Declared shims -> dist/shim/. One `<package> <basename> [raw|bindgen]` per
#    line in shims.txt, deliberately declared rather than discovered — a wasm
#    artifact is expensive enough that building one by accident is worse than
#    declaring it. Runs after the dist/ clean and after zola, so a shim build
#    can never wipe the site.
#
#    The shim builder is repo-local (it needs the repo's cargo workspace), so
#    only repos that declare shims.txt need it; everything else skips here.
if [ -f "$SITE_DIR/shims.txt" ] && [ "${SKIP_SHIM:-0}" != "1" ]; then
    if [ ! -x "$WORKSPACE_ROOT/scripts/build-shim.sh" ]; then
        echo "Error: shims.txt declares shims but $WORKSPACE_ROOT/scripts/build-shim.sh is missing." >&2
        exit 1
    fi
    while read -r package basename mode; do
        [ -n "$package" ] || continue
        case "$package" in \#*) continue ;; esac
        echo "🧩 Building shim '$package' -> dist/shim/"
        "$WORKSPACE_ROOT/scripts/build-shim.sh" "$package" "$DIST_DIR/shim" "$basename" "${mode:-raw}"
    done < "$SITE_DIR/shims.txt"
fi

echo "✅ Static site built to dist/"
