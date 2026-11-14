# Shared worker build. Installed as `build-worker` by defrag-nix.
#
# This is cnft.dev-workers' build-worker.sh with the one change a PATH command
# needs: the workspace root is resolved from cargo instead of ../.. . Everything
# else is feature-detected — frontend/, admin/, macroquad-clients.txt,
# offthread-services.txt and mitos-modules/ simply are not present in a repo
# that doesn't use them, so a static-site worker pays nothing for the branches.
#
# Wrangler (especially from a Nix-managed install) spawns [build].command with a
# sanitised PATH that usually has cargo but not $CARGO_HOME/bin, where
# `cargo install` writes worker-build.
export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"

# Nix's cc-wrapper injects hardening flags clang rejects when cross-compiling C
# to wasm — `-fzero-call-used-regs=used-gpr` is not a wasm32 option. Anything
# with a C dependency then fails, and the error names the C crate rather than
# the toolchain, so it reads as "this crate cannot target wasm". It cost a
# previous investigation exactly that wrong conclusion about `uplc`/`blst`,
# which builds fine once this is off.
export NIX_HARDENING_ENABLE=""

# Resolved from cargo rather than $0 or ../..: this file is installed on PATH,
# so it has no meaningful script directory, and consumers lay their workers out
# at different depths. The cargo workspace root is the one definition that holds.
WORKSPACE_ROOT="$(dirname "$(cargo locate-project --workspace --message-format plain)")"

# SKIP_FRONTEND=1 builds the worker ALONE, reusing whatever is already in dist/.
# For working on worker-side code where the frontend is irrelevant and
# rebuilding it is minutes of wasm.
if [ -d "frontend" ] && [ "${SKIP_FRONTEND:-0}" != "1" ]; then
    if [ -f "frontend/package.json" ]; then
        # JS/SvelteKit frontend
        echo "📦 Found JS frontend - building with npm..."
        cd frontend
        npm ci
        npm run build
        cd ..
        # SvelteKit adapter-static outputs to frontend/build/ — copy to dist/
        if [ -d "frontend/build" ]; then
            rm -rf dist
            cp -r frontend/build dist
        fi
        echo "✅ JS frontend built to dist/"
    elif [ -f "frontend/Cargo.toml" ]; then
        # Rust/trunk frontend
        echo "📦 Found Rust frontend - building with trunk..."
        if ! command -v trunk &> /dev/null; then
            echo "Installing trunk..."
            cargo install trunk --locked
        fi
        # PROFILING=1 builds the frontend with its in-app profiler.
        #
        #   PROFILING=1 wrangler deploy
        #
        # A BUILD-time switch and it cannot be anything else: `profiling` is a
        # Cargo feature, so a runtime variable would be asking code that was
        # never compiled to turn itself on.
        #
        # ⚠️ THE RESULT IS NOT A SHIPPING BUILD. It carries puffin and collects
        # on every frame. Deploy it to look at something, then deploy again
        # WITHOUT the flag.
        FRONTEND_FEATURES=""
        if [ "${PROFILING:-0}" = "1" ]; then
            if grep -q '^profiling = \[' frontend/Cargo.toml; then
                FRONTEND_FEATURES="--features profiling"
                echo "🔥 PROFILING=1 — building the in-app profiler into this frontend"
            else
                echo "⚠️  PROFILING=1 ignored: $(basename "$PWD")'s frontend declares no \`profiling\` feature"
            fi
        fi

        cd frontend
        # shellcheck disable=SC2086 # deliberately word-split: empty means none
        trunk build --release $FRONTEND_FEATURES --dist ../dist
        cd ..
        echo "✅ Rust frontend built to dist/"
    fi
fi

# A second, admin-only SPA served under /admin/ from the same assets directory.
# Built AFTER the public frontend because trunk empties its dist target: the
# root build would wipe dist/admin/ if it ran second.
if [ -f "admin/Cargo.toml" ]; then
    echo "📦 Found Rust admin frontend - building with trunk into dist/admin/..."
    if ! command -v trunk &> /dev/null; then
        echo "Installing trunk..."
        cargo install trunk --locked
    fi
    cd admin
    trunk build --release --dist ../dist/admin
    cd ..
    echo "✅ Rust admin frontend built to dist/admin/"
fi

# Macroquad clients served from the same assets directory, each at its own path.
# AFTER trunk for the same reason as the admin SPA. Declared per worker in
# `macroquad-clients.txt`, one `<package> <crate dir> <served at> <title…>` per
# line, and bundled by `mq-bundle` so the page's JS matches the crate (never a
# hand-copied gl.js). `--base` because the page is served at a bare path, where
# a relative `src="gl.js"` would resolve against the parent.
#
# `<served at>` of `.` means the worker's own root: the page is what `/`
# answers, so it is written straight into `dist/` and its base is `/` rather
# than `/.`. Anything else is a directory under `dist/`, served at `/<served at>/`.
if [ -f "macroquad-clients.txt" ]; then
    HERE="$PWD"
    while read -r package crate served title; do
        [ -n "$package" ] || continue
        case "$package" in \#*) continue ;; esac
        case "$served" in
            .) dest="$HERE/dist"; base="/"; label="/" ;;
            *) dest="$HERE/dist/$served"; base="/$served/"; label="/$served/" ;;
        esac
        # A client's `static/` (images the page fetches at run time) is served at
        # `<served at>/assets/`.
        assets=()
        [ -d "$HERE/$crate/static" ] && assets=(--assets "$HERE/$crate/static")
        echo "📦 Bundling macroquad client $package → $label"
        ( cd "$WORKSPACE_ROOT" && cargo run -q -p mq-bundle -- \
            --package "$package" --wasm "$package.wasm" \
            --title "$title" --dest "$dest" \
            --web "$HERE/$crate/web" --base "$base" "${assets[@]}" )
        echo "✅ $label staged"
    done < macroquad-clients.txt
fi

# `offthread` services, LAST — after every trunk build, because trunk empties
# its dist target and anything written before it would be wiped. Declared per
# worker in `offthread-services.txt`, one `<package> <basename>` per line, rather
# than discovered: a wasm artifact is expensive enough that building one by
# accident is worse than declaring it.
if [ -f "offthread-services.txt" ] && [ "${SKIP_FRONTEND:-0}" != "1" ]; then
    while read -r package basename; do
        [ -n "$package" ] || continue
        case "$package" in \#*) continue ;; esac
        "$WORKSPACE_ROOT/scripts/build-offthread-service.sh" "$package" "dist" "$basename"
    done < offthread-services.txt
fi

# mitos-modules/ — a wasm module this worker OWNS, built with mitos-build and
# embedded in the worker. Built here so a deploy cannot carry artifact bytes
# that predate the source the worker announces.
#
# Incremental on mtime: a rebuild changes the manifest's `build_id` (and so its
# digest) even when the wasm is unchanged, which would churn the committed
# artifact on every `wrangler dev` restart.
#
# CI has no mitos checkout. It uses the committed artifact and says so — the
# alternative is failing every deploy runner. `mitos-build` also needs a local
# checkout, so a remote install cannot stand in for one.
if [ -d "mitos-modules" ]; then
    MITOS_SRC="${MITOS_SRC:-${HOME}/code/defrag/mitos}"
    for rs in mitos-modules/*.rs; do
        [ -e "$rs" ] || continue
        name=$(basename "$rs" .rs)
        id="${name//_/-}"
        toml="mitos-modules/${name}.toml"
        built="mitos-artifacts/${id}/built-module.json"
        if [ -f "$built" ] && [ ! "$rs" -nt "$built" ] \
            && { [ ! -f "$toml" ] || [ ! "$toml" -nt "$built" ]; }; then
            echo "✓ mitos-modules/${name}: artifact is current"
            continue
        fi
        if [ ! -d "$MITOS_SRC" ]; then
            echo "⚠️  mitos-modules/${name}: no mitos checkout at ${MITOS_SRC}; using the committed artifact"
            echo "    set MITOS_SRC=/path/to/mitos to build it here"
            continue
        fi
        echo "📦 Building mitos module ${id} from mitos-modules/${name}.rs"
        MITOS_ARTIFACT_OUT="$PWD/mitos-artifacts/${id}" \
            "$WORKSPACE_ROOT/scripts/build-module.sh" "$PWD" "${name}" mitos-modules
        echo "✅ mitos-artifacts/${id}/ refreshed"
    done
fi

# Get the resolved worker crate version from cargo metadata. This is what makes
# the shared script safe across repos: the version comes from the consumer's
# lock, not from a constant here.
WORKER_VERSION=$(cargo metadata --format-version 1 2>/dev/null | jq -r '.packages[] | select(.name == "worker") | .version')

if [ -z "$WORKER_VERSION" ]; then
    echo "Error: Could not determine worker version from cargo metadata"
    exit 1
fi

# Map worker version to worker-build version
# - worker 0.6.x -> worker-build 0.1.11 (legacy versioning)
# - worker 0.7.x -> worker-build 0.7.x (unified versioning from 0.7.0+)
WORKER_MAJOR_MINOR=$(echo "$WORKER_VERSION" | cut -d. -f1,2)

case "$WORKER_MAJOR_MINOR" in
    "0.6")
        WORKER_BUILD_VERSION="0.1.11"
        ;;
    "0.7"|"0.8"|"0.9"|"1.0")
        WORKER_BUILD_VERSION="$WORKER_VERSION"
        ;;
    *)
        echo "Error: Unknown worker version $WORKER_VERSION - please update build-worker.sh"
        exit 1
        ;;
esac

echo "Worker version: $WORKER_VERSION -> worker-build version: $WORKER_BUILD_VERSION"

# worker-build 0.7.x/0.8.x clears every cached version of wasm-bindgen before
# downloading it, with no lock, into a machine-global cache. Parallel deploys
# from different directories therefore delete each other's download and fail in
# step_run_wasm_bindgen with ENOENT. `worker-build-gate` (defrag-nix) takes an
# OS lock for the whole install+build. CI runners are isolated and each job
# loops serially, so the unlocked fallback is safe there.
gate="${WORKER_BUILD_GATE:-}"
if [ -z "$gate" ] && command -v worker-build-gate >/dev/null 2>&1; then
    gate="$(command -v worker-build-gate)"
fi
if [ -z "$gate" ] && [ -z "${CI:-}" ]; then
    echo "⚠️  worker-build-gate not found; building without the shared worker-build lock" >&2
fi

run_worker_build() {
    if [ -n "$gate" ]; then
        "$gate" -- "$@"
    else
        "$@"
    fi
}

# shellcheck disable=SC2016 # the $1 is expanded by the inner bash, not here
run_worker_build bash -c \
    'cargo install -q worker-build --version "$1" --locked && exec worker-build --release' \
    _ "$WORKER_BUILD_VERSION"
