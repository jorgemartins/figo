#!/usr/bin/env bash
# Builds build/Figo.app.
#
#   scripts/bundle.sh             build the web page and specs, the Swift products, assemble, sign
#   scripts/bundle.sh --skip-web  native-only rebuild; reuses web/dist and specs/dist as they are
#
# Environment:
#   FIGO_SWIFT_SCRATCH           swift build --scratch-path (default: .build)
#   FIGO_CONFIGURATION           release (default) or debug
#   FIGO_SIGN_IDENTITY           codesign identity (default: - for ad-hoc)
#   FIGO_BUNDLE_DIR              where Figo.app is assembled (default: build)
#   FIGO_SKIP_COMMUNITY_THEMES   set to leave Fig's own themes out of the bundle
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

skip_web=0
for arg in "$@"; do
  case "$arg" in
    --skip-web) skip_web=1 ;;
    -h | --help)
      sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

scratch="${FIGO_SWIFT_SCRATCH:-.build}"
configuration="${FIGO_CONFIGURATION:-release}"
identity="${FIGO_SIGN_IDENTITY:--}"
version="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/FigoCore/Figo.swift | head -n 1)"
app="${FIGO_BUNDLE_DIR:-build}/Figo.app"
contents="$app/Contents"

step() { printf '\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }

# --- Web page and specs -------------------------------------------------------------------------

if [[ $skip_web -eq 0 ]]; then
  step "Building the web page"
  pnpm --dir web build
  if [[ ! -d specs/dist ]]; then
    step "Building completion specs"
    node specs/build.mjs
  fi
fi

# --- Swift --------------------------------------------------------------------------------------

swift_build() {
  swift build --scratch-path "$scratch" -c "$configuration" --product "$1"
}

step "Building FigoApp and FigoInputMethod ($configuration)"
swift_build FigoApp
swift_build FigoInputMethod

# The CLI and the pty wrapper are developed separately; a broken or placeholder build of either
# must not stop the app from being assembled.
optional_products=()
for product in figo figoterm; do
  step "Building $product"
  if swift_build "$product"; then
    optional_products+=("$product")
  else
    warn "$product did not build; the bundle will not contain it"
  fi
done

bin="$(swift build --scratch-path "$scratch" -c "$configuration" --show-bin-path)"

# --- Assemble -----------------------------------------------------------------------------------

step "Assembling $app ($version)"
rm -rf "$app"
mkdir -p "$contents/MacOS" "$contents/Resources" "$contents/Helpers"

sed "s/__VERSION__/$version/g" Resources/Info.plist >"$contents/Info.plist"
# Not "Figo": on a case-insensitive volume it would collide with the `figo` CLI.
cp "$bin/FigoApp" "$contents/MacOS/FigoApp"
for product in "${optional_products[@]+"${optional_products[@]}"}"; do
  cp "$bin/$product" "$contents/MacOS/$product"
done
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$contents/Resources/AppIcon.icns"

helper="$contents/Helpers/FigoInputMethod.app"
mkdir -p "$helper/Contents/MacOS" "$helper/Contents/Resources"
sed "s/__VERSION__/$version/g" Resources/InputMethod-Info.plist >"$helper/Contents/Info.plist"
cp "$bin/FigoInputMethod" "$helper/Contents/MacOS/FigoInputMethod"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$helper/Contents/Resources/AppIcon.icns"

if [[ -f web/dist/index.html ]]; then
  cp -R web/dist "$contents/Resources/web"
else
  warn "web/dist is missing; bundling a placeholder page (run without --skip-web to build it)"
  mkdir -p "$contents/Resources/web"
  cat >"$contents/Resources/web/index.html" <<'HTML'
<!doctype html>
<html lang="en">
  <head><meta charset="UTF-8" /><title>Figo</title></head>
  <body>
    <script>
      // Placeholder: the real page was not built. Say hello so the app knows the page is alive.
      window.webkit?.messageHandlers?.figo?.postMessage({ method: "app.ready", params: {} });
    </script>
  </body>
</html>
HTML
fi

if [[ -d specs/dist ]]; then
  cp -R specs/dist "$contents/Resources/specs"
else
  warn "specs/dist is missing; the bundle has no completion specs"
fi

mkdir -p "$contents/Resources/themes"
cp Resources/themes/*.json "$contents/Resources/themes/"

# The themes Fig shipped (dracula, nightowl, solarized, ...) live in github.com/withfig/themes.
# That repository carries no licence, so they are not kept in this one: they are fetched at a
# pinned commit when the app is built, for personal use, and sit beside Figo's own themes.
# FIGO_SKIP_COMMUNITY_THEMES=1 leaves them out, which is what a build that is handed to other
# people wants (scripts/release.sh); install.sh fetches them on each Mac instead.
themes_commit="ab71dc82974f4750736d2583867bf6c7219515cb"
themes_cache="build/.cache/fig-themes"
if [[ -z "${FIGO_SKIP_COMMUNITY_THEMES:-}" ]]; then
  if [[ "$(git -C "$themes_cache" rev-parse HEAD 2>/dev/null || true)" != "$themes_commit" ]]; then
    step "Fetching community themes"
    rm -rf "$themes_cache"
    mkdir -p "$themes_cache"
    git -C "$themes_cache" init --quiet
    git -C "$themes_cache" remote add origin https://github.com/withfig/themes.git
    if git -C "$themes_cache" fetch --quiet --depth 1 origin "$themes_commit" \
      && git -C "$themes_cache" checkout --quiet --detach FETCH_HEAD; then
      :
    else
      warn "could not fetch the community themes; the bundle will only have Figo's own"
      rm -rf "$themes_cache"
    fi
  fi
  if [[ -d "$themes_cache/themes" ]]; then
    cp "$themes_cache"/themes/*.json "$contents/Resources/themes/"
  fi
fi

# The shell integration scripts that `figo install` copies into place.
mkdir -p "$contents/Resources/shell"
cp shell/*.zsh shell/*.bash shell/*.fish shell/*.sh shell/*.md "$contents/Resources/shell/"

cp LICENSE THIRD_PARTY_NOTICES.md "$contents/Resources/"

# --- Sign, innermost first ----------------------------------------------------------------------

step "Signing (identity: $identity)"
sign() { codesign --force --sign "$identity" --timestamp=none "$@"; }
sign "$helper"
for product in "${optional_products[@]+"${optional_products[@]}"}"; do
  sign --identifier "dev.figo.$product" "$contents/MacOS/$product"
done
sign "$app"
codesign --verify --deep --strict "$app"

step "Done: $root/$app"
