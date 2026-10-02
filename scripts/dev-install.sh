#!/usr/bin/env bash
# For working on Figo: builds it if needed, puts the app in /Applications and sets it up.
# (To install a released build, see install.sh at the top of the repository.)
#
#   scripts/dev-install.sh [options passed on to `figo install`]
#
# The app is copied rather than run from build/ so that rebuilding does not pull the files out
# from under the running app and the registered input method.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

source_app="build/Figo.app"
target_app="/Applications/Figo.app"

if [[ ! -d "$source_app" ]]; then
  scripts/bundle.sh
fi

# Quit a running copy first; it holds the files that are about to be replaced.
if [[ -x "$target_app/Contents/MacOS/figo" ]]; then
  "$target_app/Contents/MacOS/figo" quit >/dev/null 2>&1 || true
fi

rm -rf "$target_app"
cp -R "$source_app" "$target_app"
echo "Copied to $target_app"

exec "$target_app/Contents/MacOS/figo" install "$@"
