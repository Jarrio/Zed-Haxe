#!/bin/sh
# Builds vshaxe/haxe-language-server, unmodified, at a given commit and publishes it as the
# `server-<short sha>` release of the fork that src/lib.rs downloads from (SERVER_REPO).
# Upstream publishes no standalone releases (vshaxe/vshaxe#513).
#
# Needs git, Node.js, gh (logged in) and a Haxe 5 nightly on PATH: upstream master uses Haxe 5's std.
#
# usage: scripts/release-server.sh <full commit sha> [fork]
set -eu

commit="$1"
fork="${2:-Jarrio/haxe-language-server}"
short=$(printf '%.7s' "$commit")
work=$(mktemp -d)

# The release tag points at the commit, so the fork has to contain it.
gh repo sync "$fork" --source vshaxe/haxe-language-server

git clone --quiet https://github.com/vshaxe/haxe-language-server.git "$work/server"
cd "$work/server"
git checkout --quiet "$commit"
npm ci --ignore-scripts
haxelib newrepo
haxelib state load install.hxml --always
haxe build.hxml
cp bin/server.js "$work/haxe-language-server.js"

gh release create "server-$short" "$work/haxe-language-server.js" \
	--repo "$fork" \
	--target "$commit" \
	--title "haxe-language-server $short" \
	--notes "Unmodified build of https://github.com/vshaxe/haxe-language-server/commit/$commit, made with Haxe $(haxe --version).

Published for the Zed Haxe extension, which downloads it because upstream publishes no standalone releases."

echo "Published server-$short. Set SERVER_VERSION = \"$short\" in src/lib.rs."
