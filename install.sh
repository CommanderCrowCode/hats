#!/usr/bin/env bash
# Install hats to ~/.local/bin/
set -euo pipefail

INSTALL_DIR="${1:-$HOME/.local/bin}"

mkdir -p "$INSTALL_DIR"

# Stamp the commit hash into the installed copy
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMMIT=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")

# Atomic install: write to temp file then mv, so any running hats process
# keeps reading the old inode instead of seeing partial new content.
cp "$SCRIPT_DIR/hats" "$INSTALL_DIR/hats.tmp.$$"
sed -i "s/^COMMIT=\"dev\"$/COMMIT=\"$COMMIT\"/" "$INSTALL_DIR/hats.tmp.$$"
chmod +x "$INSTALL_DIR/hats.tmp.$$"
mv -f "$INSTALL_DIR/hats.tmp.$$" "$INSTALL_DIR/hats"

echo "Installed hats to $INSTALL_DIR/hats"

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
