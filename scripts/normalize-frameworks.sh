#!/bin/sh
# Link against the framework already loaded by Adium, irrespective of its
# Versions directory name. Never bundle a second libpurple or GLib runtime.
set -eu
binary=$1
"${OTOOL:-otool}" -L "$binary" | awk 'NR > 1 {print $1}' | while IFS= read -r dependency; do
    case "$dependency" in
        @executable_path/../Frameworks/*.framework/Versions/*|@rpath/*.framework/Versions/*)
            framework=${dependency#*/Frameworks/}
            framework=${framework#@rpath/}
            framework=${framework%%.framework/*}
            "${INSTALL_NAME_TOOL:-install_name_tool}" -change "$dependency" "@rpath/$framework.framework/$framework" "$binary"
            ;;
    esac
done
