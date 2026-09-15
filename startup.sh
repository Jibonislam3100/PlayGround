#!/usr/bin/env bash
#
# startup.sh — start the MiniCraft app on a fresh Actions runner.
#
#  - Changes to its own directory (project root) so it works from any CWD.
#  - Installs required dependencies (reused safely on repeated launches).
#  - Builds when required (package.json `build` script + missing dist output).
#  - Serves the playable entrypoint (./dist/index.html preferred,
#    ./index.html fallback) on ${PORT:-3000} in the FOREGROUND.
#  - Prints per-command timing for every step.
#
# Tunnel setup stays in the workflow, not here.
#
set -euo pipefail

PORT="${PORT:-3000}"

# --- per-command timing helper -------------------------------------------
# Usage: timed "label" command args...
timed() {
  local label="$1"; shift
  local start end took rc
  start=$(date +%s)
  echo "==> [startup] START: ${label}"
  set +e
  "$@"
  rc=$?
  set -e
  end=$(date +%s)
  took=$((end - start))
  echo "==> [startup] DONE: ${label} (exit=${rc}, took=${took}s)"
  return $rc
}

timed "change to project root (script dir)" \
  cd "$(dirname "${BASH_SOURCE[0]:-$0}")"
echo "==> [startup] project root: $(pwd)"
echo "==> [startup] port: ${PORT}"

# --- dependency install (safe to re-run) ----------------------------------
if [ -f package.json ]; then
  if command -v npm >/dev/null 2>&1; then
    if [ ! -d node_modules ]; then
      if [ -f package-lock.json ]; then
        timed "npm ci (first install)" npm ci --no-audit --no-fund
      else
        timed "npm install (first install)" npm install --no-audit --no-fund
      fi
    else
      # Reuse existing install; refresh only if manifests are newer.
      if [ package.json -nt node_modules ] || { [ -f package-lock.json ] && [ package-lock.json -nt node_modules ]; }; then
        timed "npm install (manifests changed)" npm install --no-audit --no-fund --prefer-offline
      else
        timed "reuse node_modules (up to date)" true
      fi
    fi
  else
    echo "==> [startup] WARN: package.json present but npm not found; skipping install"
  fi
else
  timed "dependency check (no package.json; nothing to install)" true
fi

# --- build when required ---------------------------------------------------
if [ -f package.json ] && [ ! -f dist/index.html ]; then
  if command -v npm >/dev/null 2>&1 && npm run | grep -q "build"; then
    timed "npm run build (dist/index.html missing)" npm run build
  else
    echo "==> [startup] WARN: dist/index.html missing and no build script; continuing"
  fi
else
  timed "build check (not required)" true
fi

# --- resolve the served entrypoint -----------------------------------------
SERVE_DIR="."
if [ -f dist/index.html ]; then
  SERVE_DIR="dist"
elif [ -f ./index.html ]; then
  SERVE_DIR="."
else
  echo "==> [startup] ERROR: no playable entrypoint (./index.html or ./dist/index.html)" >&2
  exit 1
fi
timed "entrypoint check (serving ${SERVE_DIR}/index.html)" test -f "${SERVE_DIR}/index.html"
export SERVE_DIR PORT

# --- start the app in the foreground ----------------------------------------
# NOTE: node is preferred because python http.server sockets do not accept
# connections reliably in some sandboxed runners (observed: bound sockets
# stuck in CLOSED state, clients time out). python remains as fallback.
echo "==> [startup] serving '${SERVE_DIR}' on port ${PORT} (foreground)"
if command -v node >/dev/null 2>&1; then
  timed "start server (node static server, foreground)" \
    node -e '
      const http = require("http"), fs = require("fs"), path = require("path");
      const root = process.env.SERVE_DIR || ".", port = +(process.env.PORT || 3000);
      const types = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css",
        ".json": "application/json", ".png": "image/png", ".svg": "image/svg+xml", ".ico": "image/x-icon" };
      http.createServer((req, res) => {
        let p = path.normalize(decodeURIComponent(req.url.split("?")[0])).replace(/^(\.\.[\/\\])+/, "");
        if (p.endsWith("/")) p += "index.html";
        const f = path.join(root, p);
        fs.readFile(f, (e, d) => {
          if (e) { res.writeHead(404); res.end("not found"); return; }
          res.writeHead(200, { "Content-Type": types[path.extname(f)] || "application/octet-stream" });
          res.end(d);
        });
      }).listen(port, "0.0.0.0", () => console.log(`[startup] node static server on :${port} (root=${root})`));
    '
elif command -v python3 >/dev/null 2>&1; then
  timed "start server (python3 http.server, foreground)" \
    python3 -m http.server "${PORT}" --directory "${SERVE_DIR}"
else
  echo "==> [startup] ERROR: neither node nor python3 found; cannot serve" >&2
  exit 1
fi
