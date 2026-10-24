//! worker-build-gate — serialise worker-build's shared tool-cache update.
//!
//! WHY THIS EXISTS
//!
//! worker-build 0.7.x/0.8.x clears every cached version of a tool before
//! downloading it, and writes straight into a machine-global cache —
//! `~/Library/Caches/worker-build` on macOS,
//! `${XDG_CACHE_HOME:-$HOME/.cache}/worker-build` on Linux — with no lock and
//! no atomic rename. Two builds starting cold from different directories
//! therefore delete each other's download, and the loser fails in
//! `step_run_wasm_bindgen` with:
//!
//! ```text
//! Error: Running the wasm-bindgen CLI
//! Caused by: No such file or directory (os error 2)
//! ```
//!
//! The cache is not scoped to a repo, so serialising per repo is not enough:
//! two checkouts, two worktrees, or two different worker repos on the same
//! machine race just the same. This gate takes a kernel file lock beside that
//! cache and holds it for the whole command. The kernel releases it when the
//! process exits, and the lock file itself is left in place (unlike macOS's
//! `lockf`, which unlinks it and lets a third process lock a fresh inode).
//!
//! It is deliberately a wrapper, not an orchestrator: the caller names the
//! command, and this only decides when it may run.
//!
//! USAGE
//!
//! ```text
//! worker-build-gate -- COMMAND [ARG...]
//! ```
//!
//! `WORKER_BUILD_GATE_LOCK` overrides the lock path; the flake check uses it
//! to keep the test inside its sandbox.

use std::env;
use std::fs::{self, OpenOptions};
use std::path::PathBuf;
use std::process::{Command, ExitStatus};

fn usage() -> ! {
    eprintln!("usage: worker-build-gate -- COMMAND [ARG...]");
    std::process::exit(64);
}

/// The lock must sit beside worker-build's cache, because that cache — not a
/// checkout — is the shared resource. Keep this in step with `dirs-next`'s
/// macOS and Linux behaviour, which is what worker-build uses.
fn lock_path() -> PathBuf {
    if let Some(path) = env::var_os("WORKER_BUILD_GATE_LOCK") {
        if !path.is_empty() {
            return PathBuf::from(path);
        }
    }

    let home = env::var_os("HOME").unwrap_or_else(|| {
        eprintln!("worker-build-gate: HOME is not set and WORKER_BUILD_GATE_LOCK is empty");
        std::process::exit(1);
    });
    let home = PathBuf::from(home);

    if cfg!(target_os = "macos") {
        home.join("Library/Caches/worker-build/.build.lock")
    } else {
        let cache = env::var_os("XDG_CACHE_HOME")
            .map(PathBuf::from)
            .filter(|path| path.is_absolute())
            .unwrap_or_else(|| home.join(".cache"));
        cache.join("worker-build/.build.lock")
    }
}

fn exit_code(status: ExitStatus) -> i32 {
    if let Some(code) = status.code() {
        return code;
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::ExitStatusExt;
        if let Some(signal) = status.signal() {
            return 128 + signal;
        }
    }
    1
}

fn main() {
    let mut args = env::args().skip(1).peekable();
    if matches!(args.peek().map(String::as_str), Some("--")) {
        args.next();
    }
    let command: Vec<String> = args.collect();
    if command.is_empty() {
        usage();
    }

    let lock_path = lock_path();
    if let Some(parent) = lock_path.parent() {
        if let Err(err) = fs::create_dir_all(parent) {
            eprintln!(
                "worker-build-gate: cannot create {}: {err}",
                parent.display()
            );
            std::process::exit(1);
        }
    }

    let lock = match OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .open(&lock_path)
    {
        Ok(file) => file,
        Err(err) => {
            eprintln!(
                "worker-build-gate: cannot open {}: {err}",
                lock_path.display()
            );
            std::process::exit(1);
        }
    };

    if let Err(err) = lock.lock() {
        eprintln!(
            "worker-build-gate: cannot lock {}: {err}",
            lock_path.display()
        );
        std::process::exit(1);
    }

    let status = match Command::new(&command[0]).args(&command[1..]).status() {
        Ok(status) => status,
        Err(err) => {
            eprintln!("worker-build-gate: cannot run {}: {err}", command[0]);
            std::process::exit(127);
        }
    };

    // `lock` is still in scope, so the lock is held until the child has
    // exited. Dropping it before `exit` would release it one step early.
    std::process::exit(exit_code(status));
}
