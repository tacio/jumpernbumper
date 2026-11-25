#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPACETIME_BIN="${SPACETIME_BIN:-/home/tacio/.local/bin/spacetime}"
GODOT_BIN="${GODOT_BIN:-/home/tacio/Apps/Godot_v4.7.2-stable_linux.x86_64}"
LISTEN_ADDR="127.0.0.1:3100"
DB_NAME="jumpernbumper"
WS_URL="ws://$LISTEN_ADDR/v1/database/$DB_NAME/subscribe"

STDB_PID=""
HOST_PID=""
GUEST_PID=""
STDB_LOG="$(mktemp)"
STDB_DATA_DIR="$(mktemp -d)"
CODE_FILE="$(mktemp)"
rm -f "$CODE_FILE"

cleanup() {
  for p in "$HOST_PID" "$GUEST_PID" "$STDB_PID"; do
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
      kill "$p" 2>/dev/null || true
      wait "$p" 2>/dev/null || true
    fi
  done
  rm -f "$STDB_LOG" "$CODE_FILE"
  rm -rf "$STDB_DATA_DIR"
}
trap cleanup EXIT INT TERM

echo "[test_phase4] 1. Importing Godot project..."
"$GODOT_BIN" --headless --path "$ROOT_DIR/client" --import

echo "[test_phase4] 2. Checking GDScript syntax across all Phase 4 scripts..."
GDSCRIPTS=(
  "res://autoload/SpacetimeWire.gd"
  "res://autoload/SpacetimeClient.gd"
  "res://autoload/AudioManager.gd"
  "res://scripts/RetroUI.gd"
  "res://scripts/Main.gd"
  "res://scripts/ConnectScreen.gd"
  "res://scripts/RoomBrowserScreen.gd"
  "res://scripts/LobbyScreen.gd"
  "res://scripts/GameWorld.gd"
  "res://scripts/VictoryPodiumScreen.gd"
  "res://tests/test_phase4_client.gd"
)
for script_res in "${GDSCRIPTS[@]}"; do
  "$GODOT_BIN" --headless --path "$ROOT_DIR/client" --check-only -s "$script_res"
done

echo "[test_phase4] 3. Running static scene & 400x256 UI bounds smoke check..."
"$GODOT_BIN" --headless --path "$ROOT_DIR/client" -s res://tests/test_phase4_client.gd -- --smoke

echo "[test_phase4] 4. Starting ephemeral SpacetimeDB (--in-memory) at $LISTEN_ADDR..."
"$SPACETIME_BIN" start \
  --listen-addr "$LISTEN_ADDR" \
  --data-dir "$STDB_DATA_DIR" \
  --in-memory \
  --non-interactive >"$STDB_LOG" 2>&1 &
STDB_PID=$!

READY=0
for _ in $(seq 1 50); do
  if "$SPACETIME_BIN" server ping "http://$LISTEN_ADDR" >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 0.2
done

if [ "$READY" -ne 1 ]; then
  echo "[test_phase4] ERROR: SpacetimeDB failed to become ready:" >&2
  cat "$STDB_LOG" >&2
  exit 1
fi

echo "[test_phase4] 5. Publishing $DB_NAME module..."
"$SPACETIME_BIN" publish "$DB_NAME" \
  --server "http://$LISTEN_ADDR" \
  --module-path "$ROOT_DIR/server/spacetimedb" \
  --no-config \
  --anonymous \
  --yes

echo "[test_phase4] 6. Running 2-instance headless Godot E2E test (Host + Guest processes)..."
"$GODOT_BIN" --headless --path "$ROOT_DIR/client" -s res://tests/test_phase4_client.gd -- --role host --url "$WS_URL" --code-file "$CODE_FILE" &
HOST_PID=$!

"$GODOT_BIN" --headless --path "$ROOT_DIR/client" -s res://tests/test_phase4_client.gd -- --role guest --url "$WS_URL" --code-file "$CODE_FILE" &
GUEST_PID=$!

wait "$HOST_PID"
HOST_RC=$?
HOST_PID=""
wait "$GUEST_PID"
GUEST_RC=$?
GUEST_PID=""

if [ "$HOST_RC" -ne 0 ] || [ "$GUEST_RC" -ne 0 ]; then
  echo "[test_phase4] ERROR: 2-instance E2E failed (host_rc=$HOST_RC guest_rc=$GUEST_RC)" >&2
  exit 1
fi

echo "[test_phase4] PASS: All Phase 4 checks succeeded!"
