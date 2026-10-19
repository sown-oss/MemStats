#!/bin/sh

set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PROJECT_PATH="$ROOT_DIR/MemStats/MemStats.xcodeproj"
CHANGELOG_PATH="$ROOT_DIR/CHANGELOG.md"
SCHEME_NAME="MemStats"
CONFIGURATION_NAME="Release"
TAG_RELEASE=0
ALLOW_DIRTY=0

usage() {
  cat <<EOF
Usage: $0 [options]

Build the release archive and zip from MARKETING_VERSION in the Xcode project.

Options:
  --tag          Create an annotated local tag named v<version> after the build.
  --allow-dirty  Allow uncommitted changes. Do not use this for a public release.
  -h, --help     Show this help.

Artifacts are written to dist/:
  MemStats-<version>.zip
  MemStats-<version>.sha256
  MemStats-<version>-RELEASE_NOTES.md
EOF
}

fail() {
  printf 'release: %s\n' "$1" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --tag)
      TAG_RELEASE=1
      ;;
    --allow-dirty)
      ALLOW_DIRTY=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "unknown option: $1"
      ;;
  esac
  shift
done

command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild is required"
command -v codesign >/dev/null 2>&1 || fail "codesign is required"
command -v ditto >/dev/null 2>&1 || fail "ditto is required"
command -v shasum >/dev/null 2>&1 || fail "shasum is required"
[ -f "$CHANGELOG_PATH" ] || fail "missing CHANGELOG.md"

if [ "$TAG_RELEASE" -eq 1 ] && [ "$ALLOW_DIRTY" -eq 0 ] && [ -n "$(git -C "$ROOT_DIR" status --porcelain)" ]; then
  fail "working tree is not clean; commit release changes or pass --allow-dirty"
fi

VERSION=$(xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME_NAME" \
  -configuration "$CONFIGURATION_NAME" \
  -showBuildSettings 2>/dev/null \
  | awk -F ' = ' '/MARKETING_VERSION/ { print $2; exit }')

[ -n "$VERSION" ] || fail "could not read MARKETING_VERSION from Xcode"
printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || fail "MARKETING_VERSION must use x.y.z, got: $VERSION"

TAG_NAME="v$VERSION"
if [ "$TAG_RELEASE" -eq 1 ] && git -C "$ROOT_DIR" show-ref --tags --verify --quiet "refs/tags/$TAG_NAME"; then
  fail "tag already exists: $TAG_NAME"
fi

ARTIFACT_DIR="$ROOT_DIR/dist"
TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/memstats-release.XXXXXX")
ARCHIVE_PATH="$TEMP_ROOT/MemStats.xcarchive"
APP_PATH="$ARCHIVE_PATH/Products/Applications/MemStats.app"
ZIP_PATH="$ARTIFACT_DIR/MemStats-$VERSION.zip"
CHECKSUM_PATH="$ARTIFACT_DIR/MemStats-$VERSION.sha256"
NOTES_PATH="$ARTIFACT_DIR/MemStats-$VERSION-RELEASE_NOTES.md"
TEMP_ZIP_PATH="$TEMP_ROOT/MemStats-$VERSION.zip"
TEMP_CHECKSUM_PATH="$TEMP_ROOT/MemStats-$VERSION.sha256"
TEMP_NOTES_PATH="$TEMP_ROOT/MemStats-$VERSION-RELEASE_NOTES.md"

cleanup() {
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT INT TERM

mkdir -p "$ARTIFACT_DIR"

printf 'Archiving MemStats %s...\n' "$VERSION"
xcodebuild archive \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME_NAME" \
  -configuration "$CONFIGURATION_NAME" \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$TEMP_ROOT/DerivedData" \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= \
  MARKETING_VERSION="$VERSION"

[ -d "$APP_PATH" ] || fail "archive did not contain MemStats.app"

printf 'Verifying code signature...\n'
codesign --verify --deep --strict "$APP_PATH"

printf 'Creating %s...\n' "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$TEMP_ZIP_PATH"

(cd "$TEMP_ROOT" && shasum -a 256 "$(basename "$TEMP_ZIP_PATH")" > "$(basename "$TEMP_CHECKSUM_PATH")")
mv -f "$TEMP_ZIP_PATH" "$ZIP_PATH"
mv -f "$TEMP_CHECKSUM_PATH" "$CHECKSUM_PATH"

awk -v version="$VERSION" '
  index($0, "## [" version "]") == 1 { found = 1 }
  found && index($0, "## [") == 1 && index($0, "## [" version "]") != 1 { exit }
  found { print }
' "$CHANGELOG_PATH" > "$TEMP_NOTES_PATH"
[ -s "$TEMP_NOTES_PATH" ] || fail "CHANGELOG.md has no section for $VERSION"
{
  printf '\n### SHA-256\n\n'
  cat "$CHECKSUM_PATH"
} >> "$TEMP_NOTES_PATH"
mv -f "$TEMP_NOTES_PATH" "$NOTES_PATH"

if [ "$TAG_RELEASE" -eq 1 ]; then
  git -C "$ROOT_DIR" tag -a "$TAG_NAME" -m "Release $TAG_NAME"
  printf 'Created local tag %s. Push it with: git push origin %s\n' "$TAG_NAME" "$TAG_NAME"
fi

printf '\nRelease artifacts:\n  %s\n  %s\n  %s\n' "$ZIP_PATH" "$CHECKSUM_PATH" "$NOTES_PATH"
