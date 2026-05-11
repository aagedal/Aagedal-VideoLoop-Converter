#!/usr/bin/env bash
# Aagedal Media Converter
# Copyright © 2026 Truls Aagedal
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Build, sign, notarize, and publish a new release. After completing the build
# pipeline this script signs the resulting .zip with Sparkle's EdDSA key and
# appends a new <item> to appcast.xml so existing installs auto-update.
#
# Prerequisites (one-time setup):
#   1. Sparkle SDK installed (via SPM, see plan file).
#   2. EdDSA keypair generated:
#        ./bin/generate_keys
#      The private key is stored in your Keychain; the public key prints to
#      stdout and must be set as SUPublicEDKey in the app's Info.plist.
#   3. notarytool credentials stored in Keychain as the profile name below.
#   4. Codeberg API token in $CODEBERG_TOKEN (or the script will skip the
#      upload step and just print the curl command for you to run manually).
#
# Usage:
#   scripts/release.sh                 # uses MARKETING_VERSION from the project
#   scripts/release.sh 4.1.2 520       # override version + build number
#
set -euo pipefail

echo "==> scripts/release.sh starting"

# -----------------------------------------------------------------------------
# Toolchain resolution
# -----------------------------------------------------------------------------
# `xcode-select` is sometimes left pointing at /Library/Developer/CommandLineTools
# (e.g. after a CLI-tools update). In that state `xcodebuild` errors out and,
# combined with `set -e`, would kill this script silently on the first line that
# touches it. Resolve a usable Xcode here so the rest of the script can assume
# it works.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    if ! xcrun --find xcodebuild >/dev/null 2>&1; then
        if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
            export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
            echo "    (auto-set DEVELOPER_DIR=$DEVELOPER_DIR — \`xcode-select -p\` pointed at CommandLineTools)"
        else
            echo "ERROR: xcodebuild not available. Run:" >&2
            echo "    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
            echo "or export DEVELOPER_DIR to a valid Xcode install." >&2
            exit 1
        fi
    fi
fi

# -----------------------------------------------------------------------------
# Config — edit these once after running `generate_keys` / setting up notarytool
# -----------------------------------------------------------------------------
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-AagedalMediaConverter}"
SIGN_UPDATE_BIN="${SIGN_UPDATE_BIN:-./bin/sign_update}"   # Sparkle tool path
CODEBERG_OWNER="taagedal"
CODEBERG_REPO="Aagedal-Media-Converter"
APPCAST="appcast.xml"

# Homebrew tap automation. Set TAP_LOCAL_PATH to a local checkout of the
# tap repo (codeberg.org/taagedal/homebrew-tap) to have this script bump
# the cask formula automatically. Leave unset to skip the tap update and
# get manual instructions printed instead.
TAP_LOCAL_PATH="${TAP_LOCAL_PATH:-}"
TAP_CASK_NAME="aagedal-media-converter"
TAP_CASK_FILE="${TAP_CASK_FILE:-Casks/$TAP_CASK_NAME.rb}"

# -----------------------------------------------------------------------------
# Resolve version / build
# -----------------------------------------------------------------------------
PROJECT="Aagedal Media Converter.xcodeproj"
SCHEME="Aagedal Media Converter"

if [[ -z "${1:-}" || -z "${2:-}" ]]; then
    echo "    Reading version from xcodebuild -showBuildSettings (takes a few seconds)…"
    BUILD_SETTINGS=$(xcodebuild -project "$PROJECT" -showBuildSettings -scheme "$SCHEME")
fi
if [[ -n "${1:-}" ]]; then
    MARKETING_VERSION="$1"
else
    MARKETING_VERSION=$(echo "$BUILD_SETTINGS" | awk -F' = ' '/^[[:space:]]*MARKETING_VERSION/{print $2; exit}')
fi
if [[ -n "${2:-}" ]]; then
    CURRENT_PROJECT_VERSION="$2"
else
    CURRENT_PROJECT_VERSION=$(echo "$BUILD_SETTINGS" | awk -F' = ' '/^[[:space:]]*CURRENT_PROJECT_VERSION/{print $2; exit}')
fi

echo "==> Building $MARKETING_VERSION ($CURRENT_PROJECT_VERSION)"

# -----------------------------------------------------------------------------
# Build & export
# -----------------------------------------------------------------------------
BUILD_DIR="$(pwd)/build"
ARCHIVE_PATH="$BUILD_DIR/AagedalMediaConverter.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORT_OPTIONS_PLIST="$BUILD_DIR/ExportOptions.plist"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Inline export options — Developer ID, no provisioning profile rewriting.
cat > "$EXPORT_OPTIONS_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>           <string>developer-id</string>
    <key>signingStyle</key>     <string>automatic</string>
    <key>destination</key>      <string>export</string>
</dict>
</plist>
EOF

# ARCHS=arm64 ONLY_ACTIVE_ARCH=NO: keep SwiftPM dependencies (SwiftExif, etc.)
# from also compiling an x86_64 slice that the arm64-only main target would
# discard at link time. The main target already sets EXCLUDED_ARCHS=x86_64
# but that setting doesn't always propagate into SPM package builds.
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"

APP_PATH="$EXPORT_DIR/$SCHEME.app"
[[ -d "$APP_PATH" ]] || { echo "Build produced no .app at $APP_PATH" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Notarize & staple
# -----------------------------------------------------------------------------
NOTARIZE_ZIP="$BUILD_DIR/notarize-input.zip"
/usr/bin/ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"

echo "==> Submitting to notarytool (profile: $NOTARYTOOL_PROFILE)"
xcrun notarytool submit "$NOTARIZE_ZIP" \
    --keychain-profile "$NOTARYTOOL_PROFILE" \
    --wait

xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

# -----------------------------------------------------------------------------
# Final zip for distribution + Sparkle signature
# -----------------------------------------------------------------------------
SAFE_VERSION="${MARKETING_VERSION//./-}"
RELEASE_ZIP_NAME="Aagedal_Media_Converter_${SAFE_VERSION}.zip"
RELEASE_ZIP="$BUILD_DIR/$RELEASE_ZIP_NAME"
/usr/bin/ditto -c -k --keepParent "$APP_PATH" "$RELEASE_ZIP"

ZIP_SIZE=$(/usr/bin/stat -f%z "$RELEASE_ZIP")
echo "==> Release zip: $RELEASE_ZIP ($ZIP_SIZE bytes)"

if [[ ! -x "$SIGN_UPDATE_BIN" ]]; then
    echo "ERROR: $SIGN_UPDATE_BIN not found. Build Sparkle's sign_update tool first." >&2
    echo "       (See Sparkle's docs — the binary lives in their built products dir.)" >&2
    exit 1
fi

ED_SIGNATURE_LINE=$("$SIGN_UPDATE_BIN" "$RELEASE_ZIP")
echo "==> Sparkle signature: $ED_SIGNATURE_LINE"

# `sign_update` prints something like:
#   sparkle:edSignature="abc..." length="12345"
# We already have length from stat, so just extract the signature value.
ED_SIGNATURE=$(echo "$ED_SIGNATURE_LINE" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')

# -----------------------------------------------------------------------------
# Upload to Codeberg release
# -----------------------------------------------------------------------------
DOWNLOAD_URL="https://codeberg.org/$CODEBERG_OWNER/$CODEBERG_REPO/releases/download/$MARKETING_VERSION/$RELEASE_ZIP_NAME"

if [[ -n "${CODEBERG_TOKEN:-}" ]]; then
    echo "==> Creating Codeberg release $MARKETING_VERSION"
    RELEASE_ID=$(curl -fsS -X POST \
        -H "Authorization: token $CODEBERG_TOKEN" \
        -H "Content-Type: application/json" \
        "https://codeberg.org/api/v1/repos/$CODEBERG_OWNER/$CODEBERG_REPO/releases" \
        -d "{\"tag_name\":\"$MARKETING_VERSION\",\"name\":\"$MARKETING_VERSION\",\"draft\":false,\"prerelease\":false}" \
        | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')

    echo "==> Uploading $RELEASE_ZIP_NAME to release $RELEASE_ID"
    curl -fsS -X POST \
        -H "Authorization: token $CODEBERG_TOKEN" \
        -H "Content-Type: multipart/form-data" \
        -F "attachment=@$RELEASE_ZIP" \
        "https://codeberg.org/api/v1/repos/$CODEBERG_OWNER/$CODEBERG_REPO/releases/$RELEASE_ID/assets?name=$RELEASE_ZIP_NAME"
    echo
else
    echo "==> CODEBERG_TOKEN not set — skipping upload. To upload manually:"
    echo "    1. Create release $MARKETING_VERSION at https://codeberg.org/$CODEBERG_OWNER/$CODEBERG_REPO/releases/new"
    echo "    2. Attach $RELEASE_ZIP"
fi

# -----------------------------------------------------------------------------
# Append appcast.xml entry
# -----------------------------------------------------------------------------
PUB_DATE=$(date "+%a, %d %b %Y %H:%M:%S %z")

# Generate inline release notes from CHANGELOG.md. Fall back to a "see release
# notes" link if the version isn't documented yet — Sparkle still renders that
# fine, and we'd rather ship than block on a missing CHANGELOG entry.
RELEASE_NOTES_HTML=""
if python3 scripts/changelog-to-html.py CHANGELOG.md "$MARKETING_VERSION" > /tmp/release-notes-$$.html 2>/dev/null; then
    # Indent each line so the CDATA reads nicely in raw XML.
    RELEASE_NOTES_HTML=$(sed 's/^/                /' /tmp/release-notes-$$.html)
    rm -f /tmp/release-notes-$$.html
    echo "==> Inline release notes extracted from CHANGELOG.md"
else
    rm -f /tmp/release-notes-$$.html
    RELEASE_NOTES_HTML="                <p>See <a href=\"https://codeberg.org/$CODEBERG_OWNER/$CODEBERG_REPO/releases/tag/$MARKETING_VERSION\">release notes</a>.</p>"
    echo "==> WARNING: $MARKETING_VERSION not found in CHANGELOG.md — using bare link in appcast"
fi

NEW_ITEM=$(cat <<EOF
        <item>
            <title>Version $MARKETING_VERSION</title>
            <pubDate>$PUB_DATE</pubDate>
            <sparkle:version>$CURRENT_PROJECT_VERSION</sparkle:version>
            <sparkle:shortVersionString>$MARKETING_VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
            <enclosure
                url="$DOWNLOAD_URL"
                length="$ZIP_SIZE"
                type="application/octet-stream"
                sparkle:edSignature="$ED_SIGNATURE" />
            <description><![CDATA[
$RELEASE_NOTES_HTML
            ]]></description>
        </item>
EOF
)

python3 - "$APPCAST" "$NEW_ITEM" <<'PYEOF'
import sys, pathlib
path = pathlib.Path(sys.argv[1])
new_item = sys.argv[2]
text = path.read_text()
needle = "    </channel>"
if needle not in text:
    raise SystemExit(f"Could not find '{needle.strip()}' in {path}")
text = text.replace(needle, new_item + "\n" + needle, 1)
path.write_text(text)
PYEOF

echo "==> Appended appcast entry. Review and commit:"
echo "    git diff $APPCAST"
echo "    git add $APPCAST && git commit -m \"Release $MARKETING_VERSION\" && git push"

# -----------------------------------------------------------------------------
# Update the Homebrew tap cask
# -----------------------------------------------------------------------------
SHA256=$(shasum -a 256 "$RELEASE_ZIP" | awk '{print $1}')
echo "==> SHA256 of release zip: $SHA256"

if [[ -n "$TAP_LOCAL_PATH" && -d "$TAP_LOCAL_PATH" ]]; then
    CASK_PATH="$TAP_LOCAL_PATH/$TAP_CASK_FILE"
    if [[ ! -f "$CASK_PATH" ]]; then
        echo "ERROR: cask file not found at $CASK_PATH" >&2
        echo "       Set TAP_CASK_FILE to override the path inside the tap repo." >&2
        exit 1
    fi

    echo "==> Updating cask at $CASK_PATH"
    (
        cd "$TAP_LOCAL_PATH"
        git pull --rebase --quiet
    )

    # Bump `version "..."` and `sha256 "..."`. Use a Python one-liner so the
    # quoting/escaping stays sane across versions of macOS sed.
    python3 - "$CASK_PATH" "$MARKETING_VERSION" "$SHA256" <<'PYEOF'
import sys, re, pathlib
path, version, sha = sys.argv[1], sys.argv[2], sys.argv[3]
src = pathlib.Path(path).read_text()
src = re.sub(r'(\bversion\s+)"[^"]*"', f'\\1"{version}"', src, count=1)
src = re.sub(r'(\bsha256\s+)"[^"]*"', f'\\1"{sha}"',     src, count=1)
pathlib.Path(path).write_text(src)
PYEOF

    (
        cd "$TAP_LOCAL_PATH"
        if git diff --quiet -- "$TAP_CASK_FILE"; then
            echo "==> Cask already at $MARKETING_VERSION ($SHA256). Nothing to commit."
        else
            git add "$TAP_CASK_FILE"
            git commit -m "$TAP_CASK_NAME $MARKETING_VERSION"
            git push
            echo "==> Tap updated and pushed."
        fi
    )
else
    cat <<EOF
==> TAP_LOCAL_PATH not set — skipping tap update. To update manually:
    cd <your tap checkout>
    # Edit $TAP_CASK_FILE:
    #   version "$MARKETING_VERSION"
    #   sha256 "$SHA256"
    git commit -am "$TAP_CASK_NAME $MARKETING_VERSION" && git push
EOF
fi
