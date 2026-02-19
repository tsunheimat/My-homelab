#!/bin/bash

echo "Linking VS Code environments..."

# 1. Define the central shared location
SHARED_DIR="$HOME/.vscode-shared"
SHARED_EXT="$SHARED_DIR/extensions"
SHARED_SETTINGS_DIR="$SHARED_DIR/settings"
SHARED_SETTINGS_FILE="$SHARED_SETTINGS_DIR/settings.json"

# Create the shared directories
mkdir -p "$SHARED_EXT"
mkdir -p "$SHARED_SETTINGS_DIR"

# Initialize a blank settings file if it doesn't exist
if [ ! -f "$SHARED_SETTINGS_FILE" ]; then
    echo "{}" > "$SHARED_SETTINGS_FILE"
fi

# Function to safely replace a target directory/file with a symlink
link_data() {
    local TARGET_EXT_DIR=$1
    local TARGET_SETTINGS_FILE=$2

    # Ensure parent directories exist
    mkdir -p "$(dirname "$TARGET_EXT_DIR")"
    mkdir -p "$(dirname "$TARGET_SETTINGS_FILE")"

    # Move existing extensions to shared folder if shared folder is empty
    if [ -d "$TARGET_EXT_DIR" ] && [ ! -L "$TARGET_EXT_DIR" ]; then
        cp -rn "$TARGET_EXT_DIR/"* "$SHARED_EXT/" 2>/dev/null || true
        rm -rf "$TARGET_EXT_DIR"
    fi

    # Create symlink for extensions
    if [ ! -L "$TARGET_EXT_DIR" ]; then
        ln -s "$SHARED_EXT" "$TARGET_EXT_DIR"
    fi

    # Move existing settings to shared settings if shared settings is empty
    if [ -f "$TARGET_SETTINGS_FILE" ] && [ ! -L "$TARGET_SETTINGS_FILE" ]; then
        # Only copy if the shared one is just empty brackets {}
        if grep -q "^[{[:space:]}]*$" "$SHARED_SETTINGS_FILE"; then
            cp "$TARGET_SETTINGS_FILE" "$SHARED_SETTINGS_FILE"
        fi
        rm -f "$TARGET_SETTINGS_FILE"
    fi

    # Create symlink for settings
    if [ ! -L "$TARGET_SETTINGS_FILE" ]; then
        ln -s "$SHARED_SETTINGS_FILE" "$TARGET_SETTINGS_FILE"
    fi
}

# 2. Map code-server
link_data "$HOME/.local/share/code-server/extensions" "$HOME/.local/share/code-server/User/settings.json"

# 3. Map vscode-desktop (Remote SSH Server)
link_data "$HOME/.vscode-server/extensions" "$HOME/.vscode-server/data/Machine/settings.json"

# 4. Map vscode-web (If it uses the newer/web specific directories)
link_data "$HOME/.vscode-web/extensions" "$HOME/.vscode-web/data/Machine/settings.json"

echo "✅ Extensions and settings are now successfully shared across all VS Code modules!"