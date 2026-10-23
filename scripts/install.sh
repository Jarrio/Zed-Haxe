#!/bin/sh
# Installs the Haxe extension for Zed from the latest release of Jarrio/Zed-Haxe (Linux and macOS).
#
#   curl -fsSL https://github.com/Jarrio/Zed-Haxe/releases/latest/download/install.sh | sh
#
# Quit Zed first, or restart it afterwards. Replaces any installed `haxe` extension, including the
# registry one and a dev extension (only the link to the dev folder is removed, not the folder).
#
# Environment: HAXE_ZED_ARCHIVE (a local package instead of downloading one), ZED_DATA_DIR (Zed's data
# folder, if it isn't the usual one, e.g. for Zed started with --user-data-dir).
set -eu

repo="Jarrio/Zed-Haxe"

if [ -n "${ZED_DATA_DIR:-}" ]; then
	data="$ZED_DATA_DIR"
elif [ "$(uname)" = "Darwin" ]; then
	data="$HOME/Library/Application Support/Zed"
elif [ -d "$HOME/.var/app/dev.zed.Zed/data/zed" ]; then
	data="$HOME/.var/app/dev.zed.Zed/data/zed" # Flatpak
else
	data="${XDG_DATA_HOME:-$HOME/.local/share}/zed"
fi
extensions="$data/extensions"
target="$extensions/installed/haxe"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
archive="${HAXE_ZED_ARCHIVE:-}"
if [ -z "$archive" ]; then
	archive="$work/haxe-zed.tar.gz"
	echo "Downloading the latest release of $repo..."
	curl -fsSL -o "$archive" "https://github.com/$repo/releases/latest/download/haxe-zed.tar.gz"
fi

mkdir -p "$extensions/installed"
if [ -L "$target" ]; then
	rm "$target"
elif [ -e "$target" ]; then
	rm -rf "$target"
fi
mkdir "$target"
tar -xzf "$archive" -C "$target"
# Zed rebuilds this cache on start; a stale one makes it load the old extension first.
rm -f "$extensions/index.json"

version=$(sed -n 's/^version = "\(.*\)"/\1/p' "$target/extension.toml" | head -n 1)
echo "Installed the Haxe extension $version into $target"
echo "Restart Zed if it is running."
echo "Zed swaps it for the registry's Haxe extension at its next update check unless your Zed settings have"
echo '  "auto_update_extensions": { "haxe": false }'
