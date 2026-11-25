#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT_BIN="${GODOT_BIN:-/home/tacio/Apps/Godot_v4.7.2-stable_linux.x86_64}"

echo "[test_phase3] 1. Running procedural asset generator..."
python3 "$ROOT_DIR/tools/gen_assets.py"

echo "[test_phase3] 2. Verifying shared/*.json == client/data/*.json byte-for-byte..."
for src in "$ROOT_DIR"/shared/*.json; do
  name="$(basename "$src")"
  dst="$ROOT_DIR/client/data/$name"
  if [ ! -f "$dst" ]; then
    echo "[test_phase3] ERROR: Missing mirrored file $dst" >&2
    exit 1
  fi
  if ! cmp -s "$src" "$dst"; then
    echo "[test_phase3] ERROR: $dst differs from $src" >&2
    exit 1
  fi
  echo "  OK: $name"
done

echo "[test_phase3] 3. Verifying PNG dimensions and WAV PCM headers..."
python3 - "$ROOT_DIR" <<'PY'
import pathlib
import sys
import wave
from PIL import Image

root = pathlib.Path(sys.argv[1])

expected_pngs = {
    root / "client/assets/sprites/bunny_sheet.png": (128, 64),
    root / "client/assets/tiles/tileset.png": (128, 32),
    root / "client/assets/bg/meadow_bg.png": (400, 256),
    root / "client/assets/sprites/particles.png": (64, 32),
}

for path, exp_size in expected_pngs.items():
    assert path.is_file(), f"Missing PNG: {path}"
    with Image.open(path) as img:
        assert img.size == exp_size, f"{path}: expected {exp_size}, got {img.size}"
        assert img.mode == "RGBA", f"{path}: expected RGBA, got {img.mode}"
    print(f"  OK PNG: {path.relative_to(root)} {exp_size}")

expected_wavs = [
    "jump.wav",
    "stomp_splat.wav",
    "puff.wav",
    "spring.wav",
    "splash.wav",
    "countdown.wav",
    "victory.wav",
]

for name in expected_wavs:
    path = root / "client/assets/sfx" / name
    assert path.is_file(), f"Missing WAV: {path}"
    with wave.open(str(path), "rb") as wf:
        assert wf.getnchannels() == 1, f"{name}: expected mono, got {wf.getnchannels()}"
        assert wf.getsampwidth() == 2, f"{name}: expected 16-bit, got {wf.getsampwidth() * 8}"
        assert wf.getframerate() == 22050, f"{name}: expected 22050 Hz, got {wf.getframerate()}"
        assert wf.getnframes() > 0, f"{name}: zero frames"
    print(f"  OK WAV: {path.relative_to(root)} (16-bit mono 22050 Hz, {wf.getnframes()} frames)")
PY

echo "[test_phase3] 4. Importing Godot client assets headlessly..."
"$GODOT_BIN" --headless --path "$ROOT_DIR/client" --import

echo "[test_phase3] 5. Checking GDScript syntax..."
"$GODOT_BIN" --headless --path "$ROOT_DIR/client" --check-only -s res://scripts/ArenaRenderer.gd
"$GODOT_BIN" --headless --path "$ROOT_DIR/client" --check-only -s res://tests/test_phase3_arena.gd

echo "[test_phase3] 6. Running headless Godot Arena test..."
"$GODOT_BIN" --headless --path "$ROOT_DIR/client" -s res://tests/test_phase3_arena.gd

echo "[test_phase3] PASS: All Phase 3 checks succeeded!"
