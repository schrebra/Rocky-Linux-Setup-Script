#!/usr/bin/env bash

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root or using sudo."
  exit 1
fi

# Set extension specifics
EXTENSION_ID="uBlock0@raymondhill.net"
TARGET_DIR="/usr/lib64/firefox/browser/extensions"
DOWNLOAD_URL="https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi"

echo "Creating Firefox global extensions directory..."
mkdir -p "$TARGET_DIR"

echo "Downloading the latest uBlock Origin build..."
if curl -sL "$DOWNLOAD_URL" -o "$TARGET_DIR/$EXTENSION_ID.xpi"; then
    # Give all users read permissions so Firefox can load it
    chmod 644 "$TARGET_DIR/$EXTENSION_ID.xpi"
    echo "uBlock Origin successfully installed system-wide!"
    echo "Restart Firefox to apply changes."
else
    echo "Error: Failed to download the extension."
    exit 1
fi
