#!/usr/bin/env bash
# ============================================================================
# Fix "Timed out connecting to Hermes backend" on Intel macOS.
#
# Root cause: on x86_64, cryptography==50.0.1 has no prebuilt macOS wheel,
# so `uv sync` builds it from source; its openssl-sys crate fails because the
# system has no OpenSSL development files. This script builds a local static
# OpenSSL (~/.local/ssl, no sudo) and re-runs the dependency sync with
# OPENSSL_DIR set, then persists it into ~/.hermes/.env.
#
# Usage: quit Hermes.app (Cmd+Q), then:  bash fix-hermes-openssl.sh
# Idempotent — safe to re-run (skips the OpenSSL build when already present).
# ============================================================================
set -u

HERMES_HOME="$HOME/.hermes"
SSL_PREFIX="$HOME/.local/ssl"
OPENSSL_VERSION="3.5.1"

# Discover uv / python tools (paths can change across Hermes versions)
UV=$(ls "$HERMES_HOME"/tools/uv-*/uv 2>/dev/null | head -1)
PYBIN=$(ls "$HERMES_HOME"/tools/python-3.14*/bin/python3 2>/dev/null | head -1)
if [ -z "$UV" ] || [ -z "$PYBIN" ]; then
  echo "!! Cannot find uv or Python under $HERMES_HOME/tools"
  ls "$HERMES_HOME/tools" 2>/dev/null
  exit 1
fi
echo "uv: $UV"; echo "python: $PYBIN"

echo "==> 1/4 Building OpenSSL $OPENSSL_VERSION into $SSL_PREFIX (static, no sudo)"
if [ -f "$SSL_PREFIX/bin/openssl" ] && [ -f "$SSL_PREFIX/include/openssl/ssl.h" ]; then
  echo "Already installed, skipping: $("$SSL_PREFIX/bin/openssl" version)"
else
  rm -rf "$SSL_PREFIX"
  WORKDIR="$(mktemp -d /tmp/sslfix.XXXXXX)"
  echo "Downloading openssl-$OPENSSL_VERSION ..."
  curl -fsSL -o "$WORKDIR/openssl.tar.gz" "https://www.openssl.org/source/openssl-$OPENSSL_VERSION.tar.gz"
  tar xzf "$WORKDIR/openssl.tar.gz" -C "$WORKDIR"
  cd "$WORKDIR/openssl-$OPENSSL_VERSION"
  # static: avoids @rpath install_name issues with dynamic libs on macOS
  ./Configure --prefix="$SSL_PREFIX" --openssldir="$SSL_PREFIX/ssl" \
              no-shared no-tests >/dev/null || {
    echo "!! Configure failed. Ensure Xcode/CLT: xcode-select --install"; exit 1; }
  make -j"$(sysctl -n hw.ncpu)" >/dev/null || { echo "!! make failed"; exit 1; }
  make install >/dev/null || { echo "!! make install failed"; exit 1; }
  cd /; rm -rf "$WORKDIR"
  echo "OpenSSL installed"
fi

echo "==> 2/4 Re-syncing Hermes dependencies (uv sync, incl. source build of cryptography — be patient)"
export OPENSSL_DIR="$SSL_PREFIX"
export OPENSSL_STATIC=1
cd "$HERMES_HOME/hermes-agent" || exit 1
# Clear the failed source-build cache so uv doesn't reuse the broken artifact
rm -rf "$HERMES_HOME/cache/uv/sdists-v9/pypi/cryptography"
# Exactly the same command the desktop app runs
"$UV" sync --frozen --all-packages --python "$PYBIN" \
  --compile-bytecode \
  --extra acp --extra all --extra audio-io --extra bedrock \
  --extra computer-use --extra discord --extra edge-tts --extra google \
  --extra slack --extra teams --extra telegram --extra trace-upload \
  --extra vertex --extra vision --extra web --extra wecom --extra youtube
if [ $? -ne 0 ]; then
  echo "!! uv sync still failing. Share the last 50 lines above."
  echo "   Or run: $HERMES_HOME/hermes-agent/hermes pm doctor"
  exit 1
fi

echo "==> 3/4 Persisting OPENSSL_DIR into $HERMES_HOME/.env"
touch "$HERMES_HOME/.env"
grep -q "^OPENSSL_DIR=" "$HERMES_HOME/.env" || {
  printf '\n# Hermes fix: local OpenSSL prefix for cryptography/openssl-sys source builds\n' >> "$HERMES_HOME/.env"
  printf 'OPENSSL_DIR=%s\n' "$SSL_PREFIX" >> "$HERMES_HOME/.env"
  printf 'OPENSSL_STATIC=1\n' >> "$HERMES_HOME/.env"
}
grep -q "^TERMINAL_CWD=" "$HERMES_HOME/.env" && {
  echo "Removing deprecated TERMINAL_CWD line (moved to config.yaml)"
  grep -v "^TERMINAL_CWD=" "$HERMES_HOME/.env" > "$HERMES_HOME/.env.tmp" && mv "$HERMES_HOME/.env.tmp" "$HERMES_HOME/.env"
}

echo "==> 4/4 Verifying cryptography import"
"$PYBIN" -c "import cryptography; print('OK: cryptography', cryptography.__version__)" || echo "!! main-env verify failed"
GEN_DIR=$(ls -d "$HERMES_HOME"/installs/*/pm-runtime/generations/*/bin/python 2>/dev/null \
          | head -1 | sed 's|/bin/python$||')
if [ -n "$GEN_DIR" ] && [ -x "$GEN_DIR/bin/python" ]; then
  "$GEN_DIR/bin/python" -I -c "import cryptography; print('OK in Hermes runtime: cryptography', cryptography.__version__)" \
    || echo "!! runtime verify failed (non-blocking: app falls back to previous deps)"
fi

echo
echo "✅ Done. Reopen Hermes.app — the backend should announce its port right away."
echo "   Still timing out? Cmd+Q and reopen; if that fails, re-run this script."
