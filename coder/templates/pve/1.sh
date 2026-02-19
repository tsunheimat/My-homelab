#!/bin/bash

# 1. Define the unified, shared directories
SHARED_DIR="$HOME/.vscode-shared"
SHARED_EXTENSIONS="$SHARED_DIR/extensions"
SHARED_USER_DATA="$SHARED_DIR/User"

# Create the shared directories
mkdir -p "$SHARED_EXTENSIONS"
mkdir -p "$SHARED_USER_DATA"

# 2. Define the target paths for each VS Code flavor in Ubuntu
# code-server paths
CODE_SERVER_EXT="$HOME/.local/share/code-server/extensions"
CODE_SERVER_DATA="$HOME/.local/share/code-server/User"

# vscode-desktop (Remote SSH/Tunnels) paths
VSCODE_DESKTOP_EXT="$HOME/.vscode-server/extensions"
VSCODE_DESKTOP_DATA="$HOME/.vscode-server/data/Machine"

# vscode-web paths
VSCODE_WEB_EXT="$HOME/.vscode-web/extensions"
VSCODE_WEB_DATA="$HOME/.vscode-web/data/Machine"

# 3. Function to safely create a symlink for directories
link_shared_dir() {
    local TARGET_DIR=$1
    local SHARED_SOURCE=$2

    # If it's a real directory and not a symlink, move existing data to shared folder
    if [ -d "$TARGET_DIR" ] && [ ! -L "$TARGET_DIR" ]; then
        echo "Moving existing data from $TARGET_DIR to $SHARED_SOURCE..."
        cp -a "$TARGET_DIR/." "$SHARED_SOURCE/" 2>/dev/null || true
        rm -rf "$TARGET_DIR"
    elif [ -L "$TARGET_DIR" ]; then
        # If it's already a symlink, remove it so we can recreate it cleanly
        rm -f "$TARGET_DIR"
    fi

    # Ensure the parent directory of the target exists
    mkdir -p "$(dirname "$TARGET_DIR")"

    # Create the symbolic link
    ln -s "$SHARED_SOURCE" "$TARGET_DIR"
    echo "Symlinked: $TARGET_DIR -> $SHARED_SOURCE"
}

echo "Configuring shared VS Code directories..."

# Apply to Extensions
link_shared_dir "$CODE_SERVER_EXT" "$SHARED_EXTENSIONS"
link_shared_dir "$VSCODE_DESKTOP_EXT" "$SHARED_EXTENSIONS"
link_shared_dir "$VSCODE_WEB_EXT" "$SHARED_EXTENSIONS"

# Apply to User Data / Settings
link_shared_dir "$CODE_SERVER_DATA" "$SHARED_USER_DATA"
link_shared_dir "$VSCODE_DESKTOP_DATA" "$SHARED_USER_DATA"
link_shared_dir "$VSCODE_WEB_DATA" "$SHARED_USER_DATA"

# Optional: Share the specific settings.json files if they are scattered
# Some versions look directly for settings.json in specific paths. 
# You can symlink the individual files if needed:
# ln -sf "$SHARED_USER_DATA/settings.json" "$HOME/.local/share/code-server/User/settings.json"

echo "✅ Shared VS Code extensions and data directories configured successfully!"