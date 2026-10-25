# Dynamic Purple for Adium

Dynamic Purple 0.2.1 uses the system **libpurple 2** in a separate helper process.
The Adium plugin registers one service per discovered protocol and translates
accounts, contacts, messages, presence and chat events through a local pipe.
Adium's built-in libpurple remains responsible for its existing services.

## Install

On the Mac that runs Adium, install the backend dependencies through MacPorts:

```sh
sudo port install libpurple json-glib pkgconfig
```

Install protocol plugins and their dependencies for that same MacPorts runtime.
Place native macOS `.so` or `.dylib` protocol modules in `~/.purple/plugins/`;
libpurple's normal system plugin directories are searched as well. Protocols
must use libpurple 2's ABI and the helper's architecture. This release is built
and tested on Intel macOS 15 with MacPorts libpurple 2.14.14 and Adium 1.5.10.4.
It does not implement libpurple 3's different API.

Unzip `DynamicPurple-0.2.1.zip` and install `DynamicPurple.AdiumLibpurplePlugin`
in `~/Library/Application Support/Adium 2.0/PlugIns/`. Quit and reopen Adium.
Add an account in Preferences → Accounts, choosing **Protocol (system libpurple)**.
Existing Dynamic Purple account/service IDs are preserved from 0.1.x.
Credentials and saved account options remain in Adium; the helper does not
import `~/.purple/accounts.xml` or automatically log in discovered accounts.

Protocol options are generated from libpurple metadata. Masked options use the
macOS Keychain. Input, action, choice and fields requests are presented in native
windows, including authentication prompts. HTTP(S) authentication links open in
the default browser. Live chat fields are obtained from the connected protocol.

Restart Adium after changing protocol binaries or updating MacPorts libraries.
Protocol icons use the PRPL's `list_icon` name and are discovered in the loaded
libpurple prefix's `share/pixmaps/pidgin/protocols/{16,22,48,...}/` directories
(normally `/opt/local/share`), equivalent `purple` directories, and XDG user/
system data directories. Hicolor `icons/hicolor/SIZExSIZE/apps/` icons are also
recognized, including `pidgin-NAME` and `im-NAME` filenames. PNG, SVG, PDF and
ICNS candidates are passed to macOS; formats the host cannot decode are skipped.
Small/contact-list and large icons choose suitable available resolutions.
Missing or corrupt icons fall back to Adium's generic network icon. The frontend
provides both image objects and file paths for Adium message views. Restart after
installing icons; copying a protocol `.so` alone does not install its icons.

A cached protocol list preserves service registration if the helper cannot
start, allowing existing Adium accounts to remain recognizable.

## Architecture

```text
Adium + DynamicPurple bundle
    AIService / AIAccount / native windows
                 ↕ JSON over private stdin/stdout pipes
macports-purple-backend process
    MacPorts libpurple + GLib + protocol plugins + protocol dependencies
```

The bundle links Cocoa, Adium and AIUtilities only. It does not subclass
`CBPurpleAccount`, pass Purple objects to Adium's built-in adapter, interpose
symbols, rewrite protocol binaries, or load MacPorts libraries into Adium.
The backend installs its own libpurple UI ops and GLib event-loop ops, including
timers and socket watches. Native libpurple discovery and dependency loading
replace the former static-registration workaround.

Protocol callbacks are translated to JSON values. Account IDs, conversation IDs,
message text, metadata and status changes cross the pipe; pointers do not.
A backend crash disconnects its accounts while leaving Adium running. An explicit
reconnect starts a new helper. A helper exit affects every system-libpurple
account served by that helper.

## Diagnostics

Bridge startup, discovery counts and backend failures are recorded in:

```text
~/Library/Logs/DynamicPurple.log
```

The same bridge messages are sent to Adium's debug logger and NSLog. Raw IPC,
passwords, authentication codes and arbitrary third-party protocol debug output
are not copied into the bridge log. Protocol notifications appear as windows.

The helper uses a private profile directory:
`~/Library/Application Support/Adium DynamicPurple/backend/`.
Its account objects are not added to libpurple's persistent accounts list.
Protocol metadata is cached separately in `protocols.plist` beside that directory.

## Build and test

Xcode and MacPorts are required. Obtain the reference Adium headers/frameworks:

```sh
sh scripts/fetch-deps.sh
make
make test
make dist
```

To reuse the supplied VM's dependencies:

```sh
make DEPS=../adium-discord/deps
make DEPS=../adium-discord/deps test
make DEPS=../adium-discord/deps dist
```

The frontend uses the legacy SDK for compatibility with Adium's headers; it
requires macOS 10.8+ for Foundation JSON. The helper uses the current compiler
SDK and the installed MacPorts libraries, whose minimum OS requirements also
apply. `MACPORTS_PREFIX` / `PKG_CONFIG` configure the build's dependency location.
The release contains the helper executable, but does not bundle MacPorts dylibs.

`make test` exercises a native no-network protocol: timers/socket callbacks,
connection errors, IM delivery, authentication requests, group chats, option
changes and shutdown. Frontend tests use Adium's real account/service classes
with test controllers. A separate integration test loads the actual bundle,
launches the actual helper, checks library isolation, kills the helper and checks
account failure delivery and restart. These tests never log into user accounts.

## Ubuntu builds and GitHub releases

[Build status](https://github.com/EionRobb/adium-dynamic-purple/actions/workflows/build.yml)
· [Download releases](https://github.com/EionRobb/adium-dynamic-purple/releases)

GitHub Actions builds the Intel bundle and helper on Ubuntu 24.04 using a pinned
osxcross revision. SDK downloads are checked against SHA-256 hashes. The frontend
uses the 10.6 SDK and targets macOS 10.8; the helper uses the 11.3 SDK, targets
macOS 10.15, and links signed MacPorts binary packages for that target. Runtime
MacPorts libraries must still be installed on the Mac; they are not in the ZIP.
The actual minimum supported system also depends on those installed libraries.

Pushes to `main`, pull requests and manual runs upload a ZIP, checksum, dependency
manifest and linkage reports as workflow artifacts. The Ubuntu checks inspect
Mach-O architecture, runtime dependencies, bundle version and executable file
permissions. `make test` remains a macOS runtime test suite.

To publish, set `VERSION` in the Makefile, commit the change, then push a matching
tag such as `v0.2.1`. A successful tagged build creates a GitHub release and
attaches the ZIP and its SHA-256 checksum. Release binaries are unsigned.

For a local Linux build, provision the tools as shown in
[the workflow](.github/workflows/build.yml), then run:

```sh
OSXCROSS=/opt/osxcross bash scripts/build-cross.sh
```

## Current scope

Implemented: service discovery, account lifecycle, protocol options, basic buddy
presence, IM send/receive, typing, generic group-chat join/messages/membership,
and common authentication request windows. Protocol UI features requiring custom
widgets, file transfer, voice/video, room browsing, account registration, protocol
menus and comprehensive buddy authorization flows need additional adapters.
Proxy controls are not advertised by the frontend yet. Group-chat behavior and
authentication still need validation with real accounts for each protocol.

Only trusted native protocol modules should be installed: they execute inside
the helper with the user's permissions. Process separation protects Adium from
runtime collisions and many plugin crashes; it is not a security sandbox.
