#!/usr/bin/env bash
#
# Update the Zed npx cache with the ACP-patched Kimi Code bundle.
#
# Usage:
#   scripts/update-zed-cache.sh [--dry-run] [TAG]
#
# TAG defaults to the newest v<version>-patched release. The cache is
# replaced atomically; the previous tree is removed after a successful swap.
#
# Environment:
#   KIMI_CODE_REPO               GitHub repo (default: luckzylp/kimi-code)
#   KIMI_CODE_ZED_CACHE_DIR      target directory
#   KIMI_CODE_ZED_CACHE_BASE_URL override the release asset base URL
#   GITHUB_TOKEN                 optional; raises GitHub API limits
#
# Linux only. Run as the user that owns the Zed cache; do not use sudo.
set -euo pipefail

REPO="${KIMI_CODE_REPO:-luckzylp/kimi-code}"
D="${KIMI_CODE_ZED_CACHE_DIR:-$HOME/.local/share/zed/external_agents/registry/npx/kimi-code}"
TAG=""
DRY_RUN=0

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=1 ;;
    -h|--help)
      printf '%s\n' \
        'Usage: scripts/update-zed-cache.sh [--dry-run] [TAG]' \
        '' \
        'Replaces the Zed npx cache with the ACP-patched Kimi Code bundle.' \
        'TAG defaults to the newest v<version>-patched release.' \
        '' \
        'Environment: KIMI_CODE_REPO, KIMI_CODE_ZED_CACHE_DIR,' \
        '  KIMI_CODE_ZED_CACHE_BASE_URL, GITHUB_TOKEN'
      exit 0
      ;;
    -*) die "unknown option: $1" ;;
    *)
      [ -z "$TAG" ] || die "unexpected argument: $1"
      TAG="$1"
      ;;
  esac
  shift
done

need curl
need tar
need sha256sum
need node
need flock
need uname
need realpath

[ "$(uname -s)" = "Linux" ] || die "this script currently supports Linux only"
node -e '
  const [major, minor] = process.versions.node.split(".").map(Number);
  if (major < 22 || (major === 22 && minor < 19)) process.exit(1);
' || die "Node.js >= 22.19 is required"

case "$(uname -m)" in
  x86_64|amd64) TARGET=linux-x64 ;;
  aarch64|arm64) TARGET=linux-arm64 ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac

D="$(realpath -m "$D")"
ROOT="$(dirname "$D")"
mkdir -p "$ROOT"

exec 9>"$ROOT/.kimi-zed-cache.lock"
flock -n 9 || die "another update is already running"

api_headers=(-H "Accept: application/vnd.github+json")
if [ -n "${GITHUB_TOKEN:-}" ]; then
  api_headers+=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi

if [ -z "$TAG" ]; then
  TAG="$(curl -fsSL "${api_headers[@]}" \
    "https://api.github.com/repos/$REPO/releases?per_page=30" |
    node -e '
      let body = "";
      process.stdin.on("data", (chunk) => (body += chunk)).on("end", () => {
        const tags = JSON.parse(body)
          .map((release) => release.tag_name)
          .filter((tag) => /^v\d+\.\d+\.\d+-patched$/.test(tag));
        const version = (tag) => tag.slice(1, -"-patched".length).split(".").map(Number);
        tags.sort((a, b) => {
          const av = version(a);
          const bv = version(b);
          return av[0] - bv[0] || av[1] - bv[1] || av[2] - bv[2];
        });
        if (tags.length === 0) process.exit(2);
        process.stdout.write(tags[tags.length - 1]);
      });
    ')" || die "could not resolve the latest v<version>-patched release"
fi

[[ "$TAG" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)-patched$ ]] || die "unsupported tag: $TAG"
VERSION="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"

BASE="${KIMI_CODE_ZED_CACHE_BASE_URL:-https://github.com/$REPO/releases/download/$TAG}"
ASSET="kimi-code-zed-cache-$TARGET-$VERSION-patched.tar.gz"
MANIFEST="kimi-code-zed-cache-$TARGET.json"

tmp="$(mktemp -d "$ROOT/.kimi-zed-cache-update.XXXXXX")"
old=""
installed=0
cleanup() {
  if [ "$installed" -ne 1 ] && [ -n "$old" ] && [ ! -e "$D" ] && [ -e "$old" ]; then
    mv "$old" "$D" || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

echo "==> downloading $TAG ($TARGET)"
curl -fsSL "$BASE/$ASSET" -o "$tmp/$ASSET" \
  || die "cache asset not found: $BASE/$ASSET (run the Zed cache workflow first)"
curl -fsSL "$BASE/$ASSET.sha256" -o "$tmp/$ASSET.sha256" \
  || die "checksum not found: $BASE/$ASSET.sha256"
(cd "$tmp" && sha256sum -c "$ASSET.sha256" >/dev/null)
SHA="$(cut -d' ' -f1 "$tmp/$ASSET.sha256")"

if curl -fsSL "$BASE/$MANIFEST" -o "$tmp/manifest.json" 2>/dev/null; then
  node -e '
    const fs = require("fs");
    const manifest = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const [version, asset, sha] = process.argv.slice(2);
    if (manifest.upstreamVersion !== version) process.exit(1);
    if (manifest.asset !== asset) process.exit(1);
    if (manifest.sha256 !== sha) process.exit(1);
  ' "$tmp/manifest.json" "$VERSION" "$ASSET" "$SHA" \
    || die "manifest does not match the downloaded asset"
fi

tar -tzf "$tmp/$ASSET" | awk '!/^npx\/kimi-code(\/|$)/ { exit 1 }' \
  || die "archive contains paths outside npx/kimi-code"

mkdir -p "$tmp/extract"
tar -xzf "$tmp/$ASSET" -C "$tmp/extract"
NEW="$tmp/extract/npx/kimi-code"
MAIN="$NEW/node_modules/@moonshot-ai/kimi-code/dist/main.mjs"

[ -f "$NEW/package.json" ] || die "cache package.json missing"
[ -f "$NEW/package-lock.json" ] || die "cache package-lock.json missing"
[ -f "$NEW/node_modules/.package-lock.json" ] || die "cache node_modules lock missing"
[ -L "$NEW/node_modules/.bin/kimi" ] || die "cache .bin/kimi symlink missing"
[ -x "$MAIN" ] || die "patched main.mjs missing or not executable"
[ "$(readlink -f "$NEW/node_modules/.bin/kimi")" = "$(realpath -m "$MAIN")" ] \
  || die "cache .bin/kimi does not point at main.mjs"

spec="$(node -e '
  const fs = require("fs");
  const pkg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  process.stdout.write(pkg.dependencies?.["@moonshot-ai/kimi-code"] ?? "");
' "$NEW/package.json")"
[ "$spec" = "$VERSION" ] || die "cache is for $spec, expected $VERSION"

installed_version="$(node -e '
  const fs = require("fs");
  process.stdout.write(JSON.parse(fs.readFileSync(process.argv[1], "utf8")).version);
' "$NEW/node_modules/@moonshot-ai/kimi-code/package.json")"
[ "$installed_version" = "$VERSION" ] || die "cache package is $installed_version, expected $VERSION"

node --check "$MAIN"
for marker in MIN_ASSISTANT_CHUNK_CHARS shouldServeLocally commandTextFromBlocks scheduleUsageUpdate; do
  grep -q "$marker" "$MAIN" || die "patched bundle is missing $marker"
done
mkdir -p "$tmp/home"
KIMI_CODE_HOME="$tmp/home" node "$MAIN" --version >/dev/null
KIMI_CODE_HOME="$tmp/home" node "$MAIN" acp --help >/dev/null

if [ -f "$D/package.json" ]; then
  current="$(node -e '
    const fs = require("fs");
    const pkg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    process.stdout.write(pkg.dependencies?.["@moonshot-ai/kimi-code"] ?? "");
  ' "$D/package.json")"
  if [ -n "$current" ] && [ "$current" != "$VERSION" ]; then
    die "Zed cache expects $current; refusing to install $VERSION (rebase the patches first)"
  fi
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "dry run: would install $TAG ($VERSION) into $D"
  exit 0
fi

ts="$(date +%Y%m%d-%H%M%S)-$$"
if [ -e "$D" ]; then
  old="$ROOT/.kimi-zed-cache.old.$ts"
  mv "$D" "$old"
fi
mv "$NEW" "$D"
installed=1

if [ -n "$old" ]; then
  rm -rf -- "$old"
fi

printf 'updated %s\n' "$D"
printf '  release: %s\n' "$TAG"
printf '  version: %s\n' "$VERSION"
printf '  sha256:  %s\n' "$SHA"
if ! grep -q '"kimi-code"' "$HOME/.config/zed/settings.json" 2>/dev/null; then
  printf '\nnote: ~/.config/zed/settings.json has no "kimi-code" agent entry.\n'
fi
printf '\nRestart the kimi-code agent in Zed to load the new build.\n'
