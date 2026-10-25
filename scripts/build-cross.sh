#!/usr/bin/env bash
# Ubuntu build. See .github/workflows/build.yml for toolchain provisioning.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${OSXCROSS:?Set OSXCROSS to the installed osxcross target directory}"
export PATH="$OSXCROSS/bin:$PATH"
bin="$OSXCROSS/bin"
tool() {
    local matches=("$bin"/x86_64-apple-darwin*-"$1")
    [[ ${#matches[@]} == 1 && -x ${matches[0]} ]] || {
        echo "Expected one osxcross $1 tool" >&2; exit 1;
    }
    printf '%s\n' "${matches[0]}"
}
version=${VERSION:-$(sed -n 's/^VERSION ?= //p' Makefile)}
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]] || {
    echo "Invalid version: $version" >&2; exit 1;
}
export MACOSX_DEPLOYMENT_TARGET=10.15
make -j"$(nproc)" dist VERSION="$version" \
    CC_x86_64="$bin/o64-clang" BACKEND_CC="$bin/o64-clang" \
    BACKEND_CFLAGS=-mmacosx-version-min=10.15 \
    PKG_CONFIG="$(tool pkg-config)" LIPO="$(tool lipo)" \
    OTOOL="$(tool otool)" INSTALL_NAME_TOOL="$(tool install_name_tool)"

# Mach-O inspection works on Linux; runtime tests require macOS.
plugin=build/DynamicPurple.AdiumLibpurplePlugin/Contents/MacOS
otool=$(tool otool)
for executable in DynamicPurple macports-purple-backend; do
    "$(tool lipo)" "$plugin/$executable" -verify_arch x86_64
    "$otool" -L "$plugin/$executable" | tee "build/$executable-linkage.txt"
done
if tail -n +2 build/DynamicPurple-linkage.txt | grep -E '/opt/local|[Ll]ibpurple|libglib|libjson'; then
    echo 'Frontend must not link a Purple/GLib runtime' >&2; exit 1
fi
for library in libpurple libjson-glib libglib; do
    grep -E "/opt/local/lib/$library[^ /]*\.dylib" build/macports-purple-backend-linkage.txt
done
if grep -E '/home/|/tmp/|/runner/|/osxcross/' build/*-linkage.txt; then
    echo 'Build-machine paths leaked into Mach-O dependencies' >&2; exit 1
fi
python3 - "$version" <<'PY'
import pathlib, plistlib, sys, zipfile
version = sys.argv[1]
with zipfile.ZipFile(f'build/DynamicPurple-{version}.zip') as z:
    root = 'DynamicPurple.AdiumLibpurplePlugin/Contents/'
    assert plistlib.loads(z.read(root + 'Info.plist'))['CFBundleShortVersionString'] == version
    for name in ('DynamicPurple', 'macports-purple-backend'):
        assert z.getinfo(root + 'MacOS/' + name).external_attr >> 16 & 0o111
    assert not any(n.endswith(('.dylib', '.so')) for n in z.namelist())
PY
(cd build && sha256sum "DynamicPurple-$version.zip" > "DynamicPurple-$version.zip.sha256")
