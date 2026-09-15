#!/usr/bin/env bash
# MiniCraft startup script — works on a fresh Actions runner.
# - Changes to its own directory (project root)
# - Installs required dependencies (safe to re-run: reuses existing installs)
# - Builds when a build step is defined
# - Serves the playable entrypoint (./index.html or ./dist/index.html)
#   on ${PORT:-3000} in the FOREGROUND (blocks; use tmux/session to daemonize).
# - Prints per-command timing. Tunnel setup stays in the workflow, not here.
set -euo pipefail

OVERALL_START=$(date +%s)
log()  { printf '[startup] %s\n' "$*"; }
timed() {
  local label="$1"; shift
  local start end elapsed rc
  start=$(date +%s)
  log "START: ${label}"
  set +e
  "$@"
  rc=$?
  set -e
  end=$(date +%s)
  elapsed=$((end - start))
  if [ "$rc" -ne 0 ]; then
    log "FAIL: ${label} (exit=${rc}, ${elapsed}s)"
    return "$rc"
  fi
  log "DONE: ${label} (${elapsed}s)"
  return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
timed "cd to script directory (${SCRIPT_DIR})" true
cd "$SCRIPT_DIR"

PORT="${PORT:-3000}"
log "PORT=${PORT}"

# --- Dependencies -----------------------------------------------------------
# Static site: the only runtime requirement is python3 (preinstalled on
# Actions runners) to serve files. If a package.json ever appears, install
# node deps idempotently (reuse node_modules when fresh).
if [ -f package.json ]; then
  if ! command -v npm >/dev/null 2>&1; then
    log "ERROR: package.json exists but npm is not installed."
    exit 1
  fi
  if [ -f package-lock.json ]; then
    if [ -d node_modules ]; then
      log "node_modules exists — verifying with 'npm ci --prefer-offline' skipped; running 'npm install --prefer-offline --no-audit --no-fund' to reuse safely."
      timed "npm install (reuse)" npm install --prefer-offline --no-audit --no-fund
    else
      timed "npm ci (fresh)" npm ci --no-audit --no-fund
    fi
  else
    timed "npm install (reuse-safe)" npm install --prefer-offline --no-audit --no-fund
  fi
  if [ -f package.json ] && node -e "process.exit(require('./package.json').scripts && require('./package.json').scripts.build ? 0 : 1)" 2>/dev/null; then
    timed "npm run build" npm run build
  else
    log "No build script — skipping build."
  fi
else
  log "No package.json — no dependencies to install (static site)."
fi

if ! command -v python3 >/dev/null 2>&1; then
  log "ERROR: python3 is required but not installed."
  exit 1
fi
timed "check python3 version" python3 --version

# --- Entrypoint --------------------------------------------------------------
if [ -f ./dist/index.html ]; then
  SERVE_DIR="dist"
elif [ -f ./index.html ]; then
  SERVE_DIR="."
else
  log "ERROR: no playable entrypoint found (looked for ./dist/index.html and ./index.html)."
  exit 1
fi
timed "verify entrypoint (${SERVE_DIR}/index.html)" \
  python3 -c "import sys; d=open('${SERVE_DIR}/index.html').read(); sys.exit(0 if ('</html>' in d) else 1)"
log "Serving '${SERVE_DIR}/index.html' on port ${PORT} (foreground)."

OVERALL_END=$(date +%s)
log "Startup preparation took $((OVERALL_END - OVERALL_START))s (excluding server runtime)."

# Foreground server (replaces this shell process image; logs stream to caller).
exec python3 -m http.server "$PORT" --directory "$SERVE_DIR"
