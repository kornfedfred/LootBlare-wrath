#!/usr/bin/env bash
set -euo pipefail

# Package the LootBlare-wrath addon for release.
# Produces LootBlare-wrath.zip with a single top-level folder matching the
# addon's .toc file name, which is what WoW expects.

VERSION="${1:-dev}"
ZIP_NAME="LootBlare-wrath.zip"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE=$(mktemp -d)
ADDON_DIR="$STAGE/LootBlare-wrath"

cleanup() {
  rm -rf "$STAGE"
}
trap cleanup EXIT

mkdir -p "$ADDON_DIR"

# Core addon files
cp "$PROJECT_ROOT/LootBlare-wrath.toc" \
   "$PROJECT_ROOT/LootBlare.lua" \
   "$PROJECT_ROOT/LootPreview.lua" \
   "$PROJECT_ROOT/RollForSync.lua" \
   "$PROJECT_ROOT/Config.lua" \
   "$ADDON_DIR/"

# Media files
cp "$PROJECT_ROOT/lootblareframe.png" \
   "$PROJECT_ROOT/lootblareframe2.png" \
   "$PROJECT_ROOT/MonaspaceNeonFrozen-Regular.ttf" \
   "$ADDON_DIR/"

# Libraries: drop README/docs that are not loaded by the TOC
rsync -a --exclude='README*' --exclude='*.md' \
  "$PROJECT_ROOT/Libs/" "$ADDON_DIR/Libs/"

# Set version in the staged TOC before zipping
sed -i "s/^## Version: .*/## Version: $VERSION/" "$ADDON_DIR/LootBlare-wrath.toc"

cd "$STAGE"
zip -r "$ZIP_NAME" LootBlare-wrath/
mv "$STAGE/$ZIP_NAME" "$PROJECT_ROOT/$ZIP_NAME"

echo "Packaged $PROJECT_ROOT/$ZIP_NAME"
