#!/usr/bin/env bash
# Install hats to ~/.local/bin/
set -euo pipefail

INSTALL_DIR="${1:-$HOME/.local/bin}"

mkdir -p "$INSTALL_DIR"

# Atomic install: write to temp file then mv, so any running hats process
# keeps reading the old inode instead of seeing partial new content.
cp "$(dirname "$0")/hats" "$INSTALL_DIR/hats.tmp.$$"
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
