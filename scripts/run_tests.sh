#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "========================================"
echo "Jumper 'n Bumper - Full Test Suite (Phases 1-4)"
echo "========================================"

echo ""
echo ">>> Phase 1: Pure Rust Simulation & Schema Validation"
cargo test --manifest-path "$ROOT_DIR/server/Cargo.toml"

echo ""
echo ">>> Phase 2: SpacetimeDB Module & Multi-Client E2E"
bash "$ROOT_DIR/scripts/test_phase2.sh"

echo ""
echo ">>> Phase 3: Procedural Assets & Arena Renderer"
bash "$ROOT_DIR/scripts/test_phase3.sh"

echo ""
echo ">>> Phase 4: Full Godot Client & 2-Instance E2E"
bash "$ROOT_DIR/scripts/test_phase4.sh"

echo ""
echo "========================================"
echo "ALL PHASES (1-4) PASSED!"
echo "========================================"
