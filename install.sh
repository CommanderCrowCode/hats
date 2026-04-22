#!/usr/bin/env bash
# Install hats to ~/.local/bin/
#
# Usage:
#   ./install.sh [install_dir]          # install to <install_dir> (default ~/.local/bin)
#   ./install.sh --check                # run tests/smoke.sh without installing
#   ./install.sh --check [install_dir]  # run smoke first; install only if tests pass
set -euo pipefail

CHECK=0
INSTALL_DIR=""
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=1 ;;
    -h|--help)
      sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*) echo "Unknown flag: $arg" >&2; exit 2 ;;
    *)
      [ -n "$INSTALL_DIR" ] && { echo "Too many arguments" >&2; exit 2; }
      INSTALL_DIR="$arg"
      ;;
  esac
done
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Parse --check etc. already done above. COMMIT comes from `git rev-parse` and
# is interpolated into a sed replacement expression below; constrain it to
# hex-only so that a tampered-git scenario (packed-refs, unusual HEAD) can't
# inject sed metacharacters (`/`, `&`, newline).

# Pre-install smoke check: run the test suite before overwriting the installed
# binary. Useful for CI or operators who want a safety gate on source changes.
if [ "$CHECK" -eq 1 ]; then
  smoke="$SCRIPT_DIR/tests/smoke.sh"
  [ -x "$smoke" ] || { echo "tests/smoke.sh missing or non-executable" >&2; exit 1; }
  echo "Running pre-install smoke check..."
  if ! "$smoke"; then
    echo "Smoke check failed — aborting install." >&2
    exit 1
  fi
  echo "Smoke check passed."
  echo
fi

mkdir -p "$INSTALL_DIR"

# Stamp the commit hash into the installed copy
COMMIT=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
if ! [[ "$COMMIT" =~ ^[0-9a-f]+$|^unknown$ ]]; then
  COMMIT="unknown"
fi

# Atomic install: write to temp file then mv, so any running hats process
# keeps reading the old inode instead of seeing partial new content.
cp "$SCRIPT_DIR/hats" "$INSTALL_DIR/hats.tmp.$$"
# Portable sed -i — BSD (macOS) sed requires explicit extension arg; GNU accepts it too.
sed -i.bak "s/^COMMIT=\"dev\"$/COMMIT=\"$COMMIT\"/" "$INSTALL_DIR/hats.tmp.$$"
rm -f "$INSTALL_DIR/hats.tmp.$$.bak"
chmod +x "$INSTALL_DIR/hats.tmp.$$"
mv -f "$INSTALL_DIR/hats.tmp.$$" "$INSTALL_DIR/hats"

echo "Installed hats to $INSTALL_DIR/hats"

# Copy rotation/ auxiliary scripts (pool_status.py, decision.py, etc.)
if [ -d "$SCRIPT_DIR/rotation" ]; then
  cp -R "$SCRIPT_DIR/rotation" "$INSTALL_DIR/rotation"
  echo "Installed rotation scripts to $INSTALL_DIR/rotation"
fi

# Check if install dir is in PATH
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
  echo ""
  echo "Warning: $INSTALL_DIR is not in your PATH."
  echo "Add this to your shell config:"
  echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
fi

echo ""
echo "Get started:"
echo "  hats init"
echo "  hats list"
