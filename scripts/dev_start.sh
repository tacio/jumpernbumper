#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPACETIME_BIN="${SPACETIME_BIN:-/home/tacio/.local/bin/spacetime}"
LISTEN_ADDR="${STDB_LISTEN_ADDR:-127.0.0.1:3000}"
DATA_DIR="${STDB_DATA_DIR:-$ROOT_DIR/.spacetime-data}"
DB_NAME="${STDB_DB_NAME:-jumpernbumper}"

STDB_PID=""
cleanup() {
  if [ -n "$STDB_PID" ] && kill -0 "$STDB_PID" 2>/dev/null; then
    echo "[dev_start] Stopping SpacetimeDB (pid=$STDB_PID)..."
    kill "$STDB_PID" 2>/dev/null || true
    wait "$STDB_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

mkdir -p "$DATA_DIR"

echo "[dev_start] Starting local SpacetimeDB at $LISTEN_ADDR (data-dir=$DATA_DIR)..."
"$SPACETIME_BIN" start \
  --listen-addr "$LISTEN_ADDR" \
  --data-dir "$DATA_DIR" \
  --non-interactive &
STDB_PID=$!

for _ in $(seq 1 50); do
  if "$SPACETIME_BIN" server ping "http://$LISTEN_ADDR" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done

echo "[dev_start] Publishing module $DB_NAME..."
"$SPACETIME_BIN" publish "$DB_NAME" \
  --server "http://$LISTEN_ADDR" \
  --module-path "$ROOT_DIR/server/spacetimedb" \
  --no-config \
  --yes

echo "[dev_start] Ready at ws://$LISTEN_ADDR/v1/database/$DB_NAME/subscribe (Ctrl+C to stop)"
wait "$STDB_PID"
