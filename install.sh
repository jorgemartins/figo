#!/bin/sh
# Installs Figo from its latest GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/jorgemartins/figo/main/install.sh | sh
#
# Options go after `sh -s --`, for example `... | sh -s -- --disable-conflicts`:
#   --no-themes   do not download the themes Fig shipped (dracula, nightowl, solarized, ...)
#   other options are passed on to `figo install` (--disable-conflicts, --shells zsh,fish, ...)
#
# Environment:
#   FIGO_REPO      GitHub repository to install from (default: jorgemartins/figo)
#   FIGO_VERSION   release tag to install, such as v0.1.0 (default: the latest release)
#   FIGO_APP_DIR   folder that Figo.app goes into (default: /Applications)
#   FIGO_ZIP       a Figo.zip already on this Mac, to install instead of downloading one
set -eu

# Fig's themes, at the same commit as scripts/bundle.sh. Their repository carries no licence, so a
# release does not contain them; each Mac fetches them from the source.
themes_commit="ab71dc82974f4750736d2583867bf6c7219515cb"

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# Everything runs from this function, called on the last line, so that a download cut short
# cannot run half of the script.
main() {
  repo="${FIGO_REPO:-jorgemartins/figo}"
  app_dir="${FIGO_APP_DIR:-/Applications}"
  target="$app_dir/Figo.app"

  themes=1
  remaining=$#
  while [ "$remaining" -gt 0 ]; do
    argument="$1"
    shift
    remaining=$((remaining - 1))
    case "$argument" in
      --no-themes) themes=0 ;;
      *) set -- "$@" "$argument" ;;
    esac
  done

  [ "$(uname -s)" = "Darwin" ] || fail "Figo only runs on macOS."
  [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = "1" ] \
    || fail "this build of Figo needs an Apple Silicon Mac. On an Intel Mac, build it from source (see the README)."
  macos="$(sw_vers -productVersion)"
  [ "${macos%%.*}" -ge 14 ] || fail "Figo needs macOS 14 or later; this Mac has $macos."
  [ -d "$app_dir" ] && [ -w "$app_dir" ] \
    || fail "cannot write to $app_dir. Set FIGO_APP_DIR to a folder you own, such as ~/Applications."

  work="$(mktemp -d "${TMPDIR:-/tmp}/figo-install.XXXXXX")"
  trap 'rm -rf "$work"' EXIT

  zip="${FIGO_ZIP:-}"
  if [ -z "$zip" ]; then
    if [ -n "${FIGO_VERSION:-}" ]; then
      base="https://github.com/$repo/releases/download/$FIGO_VERSION"
    else
      base="https://github.com/$repo/releases/latest/download"
    fi
    say "Downloading Figo"
    zip="$work/Figo.zip"
    curl -fL --progress-bar -o "$zip" "$base/Figo.zip" || fail "could not download $base/Figo.zip"
    curl -fsSL -o "$zip.sha256" "$base/Figo.zip.sha256" || fail "could not download $base/Figo.zip.sha256"
    expected="$(cut -d ' ' -f 1 <"$zip.sha256")"
    actual="$(shasum -a 256 "$zip" | cut -d ' ' -f 1)"
    [ "$expected" = "$actual" ] || fail "the download does not match its checksum; not installing it."
  fi

  ditto -x -k "$zip" "$work/unpacked" || fail "could not unpack $zip"
  unpacked="$work/unpacked/Figo.app"
  [ -x "$unpacked/Contents/MacOS/figo" ] || fail "$zip does not contain Figo.app"
  codesign --verify --deep --strict "$unpacked" || fail "Figo.app is damaged; not installing it."
  # Figo is not signed with an Apple developer certificate, so macOS would refuse to open a copy
  # that carries the "downloaded" flag. curl does not set it; a zip fetched with a browser has it.
  xattr -dr com.apple.quarantine "$unpacked" 2>/dev/null || true

  say "Installing into $app_dir"
  # A running copy holds the files that are about to be replaced.
  if [ -x "$target/Contents/MacOS/figo" ]; then
    "$target/Contents/MacOS/figo" quit >/dev/null 2>&1 || true
  fi
  rm -rf "$target"
  ditto "$unpacked" "$target"
  figo="$target/Contents/MacOS/figo"

  if [ "$themes" -eq 1 ]; then
    say "Fetching Fig's themes"
    if curl -fsSL "https://codeload.github.com/withfig/themes/tar.gz/$themes_commit" | tar -xz -C "$work" 2>/dev/null \
      && [ -d "$work/themes-$themes_commit/themes" ]; then
      "$figo" theme import "$work/themes-$themes_commit/themes"
    else
      echo "Could not fetch them; Figo's own themes are still there." >&2
    fi
  fi

  say "Setting up"
  "$figo" install "$@"
}

main "$@"
