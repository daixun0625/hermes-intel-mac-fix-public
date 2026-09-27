# Hermes Desktop on Intel macOS — "Timed out connecting to Hermes backend" fix

A one-click diagnosis & fix for the `Timed out connecting to Hermes backend`
error that appears when starting **Hermes.app** on an **Intel (x86_64) Mac**,
typically right after a fresh install or after a Hermes/dependency update.

Verified on: macOS Intel, Hermes agent 0.18.2, Python 3.14.7 (uv-managed), `cryptography==50.0.1`.

## Root cause (the full chain)

1. Every launch of the desktop app spawns its own backend, which first runs a
   dependency sync: `uv sync --frozen --all-packages ...`
   (log line: `hermes: completing source-update dependencies...`).
2. The lock file pins `cryptography==50.0.1` for Python ≥ 3.14. On PyPI this
   version ships **macOS wheels for arm64 only — there is no `x86_64` macOS
   wheel** (checked: 46 files, macOS ones all `macosx_11_0_arm64`).
   So on an Intel Mac, `uv` must build `cryptography` **from source**.
3. The source build compiles a Rust extension whose `openssl-sys` crate needs
   the **system OpenSSL development files** (headers + libs). A clean Intel
   Mac usually has no Homebrew, no `pkg-config`, and no OpenSSL headers in the
   system SDK → build fails: `Could not find directory of OpenSSL installation`.
4. `uv sync` exits 1 → the backend never announces its port → the desktop app
   gives up after 90 s and shows **`Timed out connecting to Hermes backend`**.

> Note: the long-running `hermes gateway` / `hermes dashboard` processes
> (default ports 8642 / 9120, `/health` → 200) are usually **healthy** all
> along. What times out is the *desktop-spawned* backend that is blocked in
> dependency installation. Don't be misled by the healthy gateway.

## How to fix

Prerequisites: Xcode Command Line Tools (`xcode-select --install`) and internet access.

```bash
# 1) Fully quit Hermes.app (Cmd+Q), then in a real terminal:
curl -fsSL https://raw.githubusercontent.com/<YOUR-USER>/hermes-intel-mac-fix/main/fix-hermes-openssl.sh -o /tmp/fix-hermes-openssl.sh
bash /tmp/fix-hermes-openssl.sh
# 2) Reopen Hermes.app
```

The script (idempotent, **no sudo**, everything under your home dir):

1. Downloads **OpenSSL 3.5.1** and builds it **statically** into `~/.local/ssl`.
2. Re-runs the exact `uv sync` command the desktop app uses, with
   `OPENSSL_DIR` / `OPENSSL_STATIC` set so `openssl-sys` finds the local OpenSSL,
   after clearing the failed build cache of `cryptography`.
3. Persists `OPENSSL_DIR` into `~/.hermes/.env` so every future
   desktop-spawned backend can compile/link against OpenSSL.
4. Verifies `import cryptography` works.

Expected: `OK cryptography 50.0.1` and, after reopening Hermes, a
`HERMES_BACKEND_READY` / `Hermes backend is ready` line in
`~/.hermes/logs/desktop.log` instead of the timeout. Takes ~5–15 minutes
(mostly compiling OpenSSL + syncing dependencies).

## Verifying the fix

```bash
grep -E "HERMES_BACKEND_READY|backend is ready|Timed out" ~/.hermes/logs/desktop.log | tail -5
# success: "... backend is ready. Finalizing desktop startup"
```

## Known non-blocking tail

The desktop app may still log a background full-sync failure into the
`pm-runtime` generation venv when the GUI process environment doesn't inherit
`OPENSSL_DIR` — it then *falls back to the previous dependencies and runs
fine*. To fully silence it, re-run the script once more (it skips the already
built OpenSSL), or run `launchctl setenv OPENSSL_DIR "$HOME/.local/ssl"` and
relaunch Hermes.

## When this does NOT apply

- **Apple Silicon (arm64) Macs**: prebuilt wheels exist; a timeout there has a
  different cause (network/proxy, disk, sandbox).
- If the script still reports `uv sync` failure: stop and run
  `~/.hermes/hermes-agent/hermes pm doctor` and share the last 50 lines of
  `~/.hermes/logs/install.log`.

## Diagnosis cheat-sheet (read-only)

```bash
grep -E "completing source-update|HERMES_BACKEND_READY|Timed out" ~/.hermes/logs/desktop.log | tail -20
grep -E "exited 1|openssl-sys|Could not find" ~/.hermes/logs/install.log | tail -20
uname -m          # must print x86_64 for this guide to apply
```
