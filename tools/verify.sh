#!/usr/bin/env bash
# Headless verification runner for Colonial Conquest II.
#
#   tools/verify.sh            run every test
#   tools/verify.sh test_turn_engine
#   tools/verify.sh --import   only refresh the Godot class registry
#
# Godot registers global `class_name` types into .godot/global_script_class_cache.cfg
# during an editor import pass. New scripts therefore need `--editor --quit` before the
# `-s` test run can resolve them by name, so this script always re-imports first.

set -uo pipefail

GODOT="${GODOT:-$HOME/.local/godot/godot}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$PROJECT_DIR" || exit 1

if [[ ! -x "$GODOT" ]]; then
  echo "FATAL: Godot binary not found at '$GODOT'." >&2
  echo "       Set GODOT=/path/to/godot or install it at ~/.local/godot/godot." >&2
  exit 2
fi

# --- Registry refresh (errors here are real script problems) --------------------
echo ">>> importing project (refreshing global class cache)"
IMPORT_LOG="$(mktemp)"
"$GODOT" --headless --editor --quit --path "$PROJECT_DIR" >"$IMPORT_LOG" 2>&1
IMPORT_RC=$?

# The editor emits colour codes and progress lines; keep only diagnostics.
IMPORT_ERRORS="$(grep -E "SCRIPT ERROR|Parse Error|Compile Error|Failed to load|ERROR:" "$IMPORT_LOG" \
  | grep -vE "ObjectDB instances were leaked" || true)"

if [[ -n "$IMPORT_ERRORS" ]]; then
  echo ">>> IMPORT FAILED (rc=$IMPORT_RC)"
  echo "$IMPORT_ERRORS"
  rm -f "$IMPORT_LOG"
  exit 1
fi
echo "    import clean (rc=$IMPORT_RC)"
rm -f "$IMPORT_LOG"

if [[ "${1:-}" == "--import" ]]; then
  exit 0
fi

# --- Test selection ------------------------------------------------------------
if [[ $# -ge 1 ]]; then
  TESTS=("$@")
else
  TESTS=()
  while IFS= read -r f; do
    TESTS+=("$f")
  done < <(ls tests/test_*.gd 2>/dev/null | grep -vE 'test_support\.gd$' | sed 's|^|res://|')
fi

if [[ ${#TESTS[@]} -eq 0 ]]; then
  echo "FATAL: no tests found in tests/test_*.gd" >&2
  exit 2
fi

# --- Run ----------------------------------------------------------------------
# Guard paths that are *supposed* to report an error. Tests exercise these deliberately
# to prove a guard fires; the matching ERROR line is expected output, not a failure.
# Each entry is a fixed substring of the engine's message.
EXPECTED_ERRORS_FILE="$(mktemp)"
cat >"$EXPECTED_ERRORS_FILE" <<'EOF'
PeerTransport.open() is abstract
PeerTransport.submit_order() is abstract
LoopbackTransport.submit_order() with no resolver bound
LoopbackTransport: resolver has no receive_order() ingress point
[FleetState] unknown hull id
[GalaxyState] payload missing systems or planets
[GalaxyState] save version
[GalaxyState] from_json: payload is not an object
[PlanetState] dictionary missing required fields
[SystemState] dictionary missing required fields
[FleetState] dictionary missing required fields
[FactionState] dictionary missing required fields
Parse JSON failed
[cc2] unknown run mode
[cc2] definitions not loaded; cannot generate a galaxy
[cc2] dedicated server needs the Defs and GameDB autoloads
[Defs] directory missing
[GalaxyGenerator] generate: definition registry is null
[GalaxyGenerator] generate: RNG stream is null
[GalaxyGenerator] no planet type for class
[GalaxyGenerator] no ship hull definitions
[AssetPaths] refusing to save a null image
[GalaxyGenerator] GameDB tuning constants unavailable
[Order] payload missing 'type'
[Order] payload has an unknown type
EOF

TOTAL_PASS=0
TOTAL_FAIL=0
FAILED_TESTS=()

for test_path in "${TESTS[@]}"; do
  name="$(basename "$test_path" .gd)"
  echo ""
  echo ">>> running $name"
  LOG="$(mktemp)"
  "$GODOT" --headless --path "$PROJECT_DIR" -s "$test_path" 2>&1 | tee "$LOG"
  RC=${PIPESTATUS[0]}

  # Count the harness's own summary lines.
  LINE="$(grep -oE "RESULT $name: (OK|FAILED).*" "$LOG" | tail -1)"
  CHECKS="$(grep -c '\[PASS\]' "$LOG" || true)"
  BAD="$(grep -c '\[FAIL\]' "$LOG" || true)"
  TOTAL_PASS=$((TOTAL_PASS + CHECKS))
  TOTAL_FAIL=$((TOTAL_FAIL + BAD))

  # A clean run is: exit 0, an OK summary, and no *unexpected* engine diagnostics.
  # Some tests deliberately exercise guard paths that call push_error(); those are
  # allowlisted by message so a genuinely new failure still trips the gate.
  ERRORS="$(grep -E "SCRIPT ERROR|Parse Error|Compile Error|ERROR:" "$LOG" \
    | grep -vF -f "$EXPECTED_ERRORS_FILE" \
    | grep -vE "ObjectDB instances were leaked" || true)"

  if [[ $RC -ne 0 ]]; then
    echo "    !! exit=$RC (expected 0)"
    FAILED_TESTS+=("$name")
  fi
  if [[ "$LINE" != *": OK"* ]]; then
    echo "    !! $LINE"
    FAILED_TESTS+=("$name")
  fi
  if [[ -n "$ERRORS" ]]; then
    echo "    !! engine diagnostics:"
    echo "$ERRORS" | sed 's/^/       /'
    FAILED_TESTS+=("$name")
  fi
  rm -f "$LOG"
done

# --- Summary ------------------------------------------------------------------
echo ""
echo "============================================================"
printf "  tests run : %d\n" "${#TESTS[@]}"
printf "  checks    : %d passed, %d failed\n" "$TOTAL_PASS" "$TOTAL_FAIL"
if [[ ${#FAILED_TESTS[@]} -eq 0 ]]; then
  echo "  STATUS    : ALL GREEN"
  echo "============================================================"
  rm -f "$EXPECTED_ERRORS_FILE"
  exit 0
fi
echo "  FAILED    : ${FAILED_TESTS[*]}"
echo "============================================================"
rm -f "$EXPECTED_ERRORS_FILE"
exit 1