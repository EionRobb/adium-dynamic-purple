#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
PKG_CONFIG=${PKG_CONFIG:-/opt/local/bin/pkg-config}
CC=${CC:-cc}
mkdir -p build/backend-test/plugins
# Deliberately links only the system libpurple and JSON/GLib stack.
$CC -O2 -g -Wall -Wextra -Wno-unused-parameter Backend/backend.c -o build/macports-purple-backend $($PKG_CONFIG --cflags --libs purple json-glib-1.0)
$CC -std=c99 -Wall -Wextra -DPURPLE_PLUGINS -dynamiclib tests/backend-fixture.c -o build/backend-test/plugins/fixture.so $($PKG_CONFIG --cflags --libs purple)
python3 tests/backend.py
