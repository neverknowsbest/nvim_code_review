#!/bin/bash
set -e

PLUGIN_NAME="code-review"
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_DIR="$HOME/.config/nvim/lua/plugins"
PLUGIN_FILE="$TARGET_DIR/$PLUGIN_NAME.lua"

if [ "$1" = "--dev" ]; then
  # Dev mode: lazy.nvim loads directly from source dir
  mkdir -p "$TARGET_DIR"
  cat > "$PLUGIN_FILE" << EOF
return {
  dir = "$SOURCE_DIR",
  lazy = false,
  keys = {
    { "<leader>cr", "<cmd>CodeReview<cr>", desc = "Code Review" },
  },
}
EOF
  echo "Installed (dev): lazy will load directly from $SOURCE_DIR"
else
  # Copy into lazy's plugin store
  INSTALL_DIR="$HOME/.local/share/nvim/lazy/$PLUGIN_NAME"
  rm -rf "$INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"
  cp -r "$SOURCE_DIR/lua" "$INSTALL_DIR/"
  cp -r "$SOURCE_DIR/plugin" "$INSTALL_DIR/"
  mkdir -p "$TARGET_DIR"
  cat > "$PLUGIN_FILE" << EOF
return {
  dir = "$INSTALL_DIR",
  lazy = false,
  keys = {
    { "<leader>cr", "<cmd>CodeReview<cr>", desc = "Code Review" },
  },
}
EOF
  echo "Installed (copy): $INSTALL_DIR"
fi

echo "Created plugin spec: $PLUGIN_FILE"
echo "Done. Restart nvim and run :CodeReview"
