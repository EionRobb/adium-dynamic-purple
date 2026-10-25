#!/bin/sh
# Download and assemble everything needed to build against Adium 1.5.10 into deps/:
#
#   deps/MacOSX10.6.sdk.tar.xz   Mac OS X 10.6 SDK (also handed to osxcross on CI)
#   deps/MacOSX10.6.sdk          the same, unpacked
#   deps/Frameworks/             Adium 1.5.10's frameworks, with headers
#
# libpurple, glib and json-glib ship prebuilt (binaries + headers) in the Adium source tree.
# Adium.framework, AdiumLibpurple.framework and AIUtilities.framework are built from source
# there, so their binaries come from the official Adium 1.5.10 DMG and their headers from source.
#
# Works on macOS (hdiutil) and Linux (7z).
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEPS=$ROOT/deps

ADIUM_REPO=https://github.com/adium/adium.git
ADIUM_COMMIT=38a6995f2edfc6f8a1f0cc5dee0420a3adddb2c0   # "Adium 1.5.10"
DMG_URL=https://adiumx.cachefly.net/Adium_1.5.10.dmg
DMG_SHA256=bca3ac81d33265b71c95a3984be80715fbd98f38d7c463d0441d43a335ed399a
SDK_URL=https://github.com/phracker/MacOSX-SDKs/releases/download/11.3/MacOSX10.6.sdk.tar.xz
SDK_SHA256=ad93f3e25c1ee71e457ced1a9c106c2e6741afb96252f259a5b7c625d1156fe8

PREBUILT_FRAMEWORKS="libpurple libglib libgobject libgmodule libgthread libintl libjson-glib"

sha256() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
	else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

fetch() { # url dest sha256
	if [ -f "$2" ] && [ "$(sha256 "$2")" = "$3" ]; then return; fi
	echo "Downloading $1"
	curl -fsSL --retry 3 -o "$2.part" "$1"
	if [ "$(sha256 "$2.part")" != "$3" ]; then
		echo "error: checksum mismatch for $1" >&2
		exit 1
	fi
	mv "$2.part" "$2"
}

mkdir -p "$DEPS"

# --- SDK -----------------------------------------------------------------------------------
fetch "$SDK_URL" "$DEPS/MacOSX10.6.sdk.tar.xz" "$SDK_SHA256"
if [ ! -d "$DEPS/MacOSX10.6.sdk" ]; then
	tar -xJf "$DEPS/MacOSX10.6.sdk.tar.xz" -C "$DEPS"
fi

# --- Adium source (only the parts we need) -------------------------------------------------
SRC=$DEPS/adium-src
if [ ! -d "$SRC/.git" ]; then
	git init -q "$SRC"
	git -C "$SRC" remote add origin "$ADIUM_REPO"
fi
git -C "$SRC" sparse-checkout set --no-cone \
	'/Frameworks/Adium Framework/Source/' \
	'/Source/*.h' \
	'/Frameworks/AIUtilities Framework/Source/' \
	'/Plugins/Purple Service/*.h' \
	$(for f in $PREBUILT_FRAMEWORKS; do printf "/Frameworks/%s.framework/ " "$f"; done)
if [ "$(git -C "$SRC" rev-parse -q --verify HEAD 2>/dev/null || true)" != "$ADIUM_COMMIT" ]; then
	git -C "$SRC" fetch -q --depth 1 origin "$ADIUM_COMMIT"
	git -C "$SRC" checkout -q FETCH_HEAD
fi

# --- Adium 1.5.10 binaries ----------------------------------------------------------------
fetch "$DMG_URL" "$DEPS/Adium_1.5.10.dmg" "$DMG_SHA256"
APP=$DEPS/Adium.app
if [ ! -d "$APP" ]; then
	case "$(uname -s)" in
	Darwin)
		MNT=$(mktemp -d)
		hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MNT" "$DEPS/Adium_1.5.10.dmg"
		cp -R "$MNT/Adium.app" "$APP"
		hdiutil detach -quiet "$MNT"
		;;
	*)
		# Extract only the three framework binaries we need: a full extraction trips over a
		# symlink in the image that 7-Zip refuses ("Dangerous symbolic link path").
		X=$DEPS/dmg-extract
		rm -rf "$X"; mkdir -p "$X"
		WANT=$(7z l -slt "$DEPS/Adium_1.5.10.dmg" | sed -n 's/^Path = //p' |
			grep -E '/Adium\.app/Contents/Frameworks/(Adium|AdiumLibpurple|AIUtilities)\.framework/Versions/A/(Adium|AdiumLibpurple|AIUtilities)$')
		[ "$(printf '%s\n' "$WANT" | wc -l)" -eq 3 ] || { echo "error: framework binaries not found in DMG" >&2; exit 1; }
		printf '%s\n' "$WANT" > "$X/list"
		7z x -y -o"$X" "$DEPS/Adium_1.5.10.dmg" @"$X/list" >/dev/null
		mv "$X/$(printf '%s\n' "$WANT" | head -n 1 | sed 's|/Contents/.*||')" "$APP"
		rm -rf "$X"
		;;
	esac
fi

# --- Assemble deps/Frameworks --------------------------------------------------------------
FW=$DEPS/Frameworks
rm -rf "$FW"
mkdir -p "$FW"

for f in $PREBUILT_FRAMEWORKS; do
	cp -R "$SRC/Frameworks/$f.framework" "$FW/"
done

# name, header source directories (relative to the Adium source tree)
make_framework() {
	name=$1
	dir=$FW/$name.framework
	mkdir -p "$dir/Headers"
	cp "$APP/Contents/Frameworks/$name.framework/Versions/A/$name" "$dir/$name"
	shift
	for headers in "$@"; do
		find "$SRC/$headers" -name '*.h' -exec cp {} "$dir/Headers/" \;
	done
}
# Some of Adium.framework's public headers live in the app's Source/ directory.
make_framework Adium "Frameworks/Adium Framework/Source" Source
make_framework AIUtilities "Frameworks/AIUtilities Framework/Source"
make_framework AdiumLibpurple "Plugins/Purple Service"

echo "deps ready in $DEPS"
