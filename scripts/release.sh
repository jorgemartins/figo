#!/usr/bin/env bash
# Builds the files of a GitHub release: build/release/Figo.zip and Figo.zip.sha256.
#
#   scripts/release.sh             build them and print the command that publishes the release
#   scripts/release.sh --publish   also create the release v<version> with the GitHub CLI, and
#                                  commit and push Casks/figo.rb pointing at it
#
# The release build leaves out Fig's own themes (their repository carries no licence, so they
# are not redistributed); install.sh downloads them from their source on each Mac instead.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

publish=0
for arg in "$@"; do
  case "$arg" in
    --publish) publish=1 ;;
    -h | --help)
      sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

version="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/FigoCore/Figo.swift | head -n 1)"
out="build/release"

if [[ $publish -eq 1 ]]; then
  # A release is a tag on a commit that everyone can see, built from exactly that commit.
  # Untracked files count: a new source file that was never added builds here and is missing
  # from the tag.
  if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
    echo "error: there are uncommitted or untracked changes; commit or remove them before publishing" >&2
    exit 1
  fi
  git fetch --quiet origin
  if [[ "$(git rev-parse HEAD)" != "$(git rev-parse '@{upstream}' 2>/dev/null)" ]]; then
    echo "error: this commit is not what is on GitHub; push (or pull) before publishing" >&2
    exit 1
  fi
  if gh release view "v$version" >/dev/null 2>&1; then
    echo "error: release v$version already exists; raise the version in Sources/FigoCore/Figo.swift" >&2
    exit 1
  fi
fi

# The page is always rebuilt. The specs are pinned to a commit, so an existing specs/dist is reused.
rm -rf "$out"
FIGO_BUNDLE_DIR="$out" FIGO_SKIP_COMMUNITY_THEMES=1 scripts/bundle.sh

# ditto keeps the code signature and symlinks intact, which plain zip does not. Extended
# attributes and resource forks are left out: they would add a `._` twin for every file, which
# an unzip other than Apple's unpacks into the bundle, breaking its signature.
ditto -c -k --norsrc --noextattr --keepParent "$out/Figo.app" "$out/Figo.zip"
(cd "$out" && shasum -a 256 Figo.zip >Figo.zip.sha256)

echo
echo "Figo $version ($(uname -m)): $out/Figo.zip, $(du -h "$out/Figo.zip" | cut -f1 | tr -d ' ')"
cat "$out/Figo.zip.sha256"

# Homebrew installs the zip of one exact version, so the cask names the version and its
# checksum. This repository is its own Homebrew tap, so the cask is committed here.
update_cask() {
  local checksum
  checksum="$(cut -d ' ' -f 1 <"$out/Figo.zip.sha256")"
  sed -i '' \
    -e "s/^  version \".*\"/  version \"$version\"/" \
    -e "s/^  sha256 \".*\"/  sha256 \"$checksum\"/" Casks/figo.rb
  if git diff --quiet -- Casks/figo.rb; then
    echo "Casks/figo.rb already names this build of $version."
    return
  fi
  git commit --quiet --message "Point the Homebrew cask at $version" -- Casks/figo.rb
  git push --quiet
  echo "Casks/figo.rb now names $version."
}

command=(
  gh release create "v$version" "$out/Figo.zip" "$out/Figo.zip.sha256"
  --target "$(git rev-parse HEAD)" --title "Figo $version" --generate-notes
)
if [[ $publish -eq 1 ]]; then
  "${command[@]}"
  update_cask || echo "warning: the release is published, but Casks/figo.rb could not be updated and pushed." >&2
else
  echo
  echo "To publish, push your commits and run:"
  echo "  $(printf '%q ' "${command[@]}")"
fi
