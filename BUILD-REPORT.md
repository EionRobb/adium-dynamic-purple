# Build and validation — 26 October 2026

## 0.2.0: system libpurple backend

Replaced the 0.1.x static Adium-libpurple loader and import rebinder with a
separate native helper using MacPorts libpurple 2.14.14 and JSON-GLib. The bundle
now subclasses AIService/AIAccount directly and links only Cocoa, Adium and
AIUtilities. No MacPorts Purple/GLib objects enter Adium's built-in adapter.
The bundle's existing identifier, extension, service IDs and account IDs remain
stable. The legacy import-rebinding implementation and its tests were removed.

Build environment: Intel macOS 15.7.7 VM, Xcode compiler 17, Adium 1.5.10.4.
Frontend headers/SDK: reference adium-discord dependency bundle (10.6 SDK with
10.8 deployment target for Foundation JSON). Helper SDK: current Xcode SDK.

Implemented metadata discovery, account lifecycle, presence, protocol options,
IM send/receive, typing, basic buddy updates, generic group chats, native
request windows, HTTP(S) URI handling, and backend failure/restart handling.
Protocol-generated passwords, masked options and opaque protocol settings are
stored through Adium/Keychain. Initial password echoes do not cause temporary
credentials to be saved. Complete snapshots clear invalidated protocol state.
The helper does not add runtime accounts to the persistent accounts list.

## Verification

`make DEPS=../adium-discord/deps all test dist` builds the bundle and packaged
helper and runs these checks:

- Actual MacPorts libpurple with a synthetic native PRPL, using a GLib timer and
  a pipe input watch for a no-network connection. Covers IMs, input/action/
  choice/fields requests, cancellation, required fields, generated chat forms,
  group messages/members, protocol setting changes and password refresh.
- Existing enabled profile accounts do not log in during discovery. Invalid
  connect/status requests report errors. EOF disconnects and quits cleanly.
  Test credentials do not appear in profile files or stderr.
- Real Adium AIService/AIAccount classes with in-memory test controllers:
  distinct service/account routing, connection/status events, contacts, IMs,
  typing, option state, Keychain write deduplication, password updates, opaque
  state reconnect/clearing/deletion and outgoing echo handling.
- Actual NSBundle frontend load and helper launch via private pipes: discovery,
  no MacPorts images in the frontend, forced backend termination, account error
  delivery and successful helper restart.
- Mach-O linkage check: frontend has no libpurple/AdiumLibpurple/MacPorts
  dependency; helper links `/opt/local/lib/libpurple.0.dylib` and its GLib stack.

A separate real-module discovery check found Discord (`prpl-eionrobb-discord`)
and Google Chat (`prpl-googlechat`) using MacPorts libpurple 2.14.14. Google Chat
was added to that check through its existing source build directory. The helper
exited with code 0 and no GLib criticals. No user account login or test message
was performed. Actual authentication and interactive Adium chat windows remain
for user validation; file transfers, audio/video and specialized protocol UI
features are outside this implementation.

Compiler output includes expected modern-linker warnings about old SDK binary
stubs. See `build/system-test-0.2.0.log` for the full verification output.

## Installation

The VM receives the 0.2.0 bundle under
`~/Library/Application Support/Adium 2.0/PlugIns/`, with its previous bundle
retained outside that directory under the project's `build/backup/`.
The release ZIP is also copied to `~/Downloads/DynamicPurple-0.2.0.zip`.
Restart Adium after installation. Bridge diagnostics remain at
`~/Library/Logs/DynamicPurple.log`.

Final installed-bundle verification also passed using only the normal plugin
search paths: Discord and Google Chat were both discovered by the installed
helper, libpurple reported 2.14.14, and EOF shutdown returned 0 without GLib
criticals. The existing Google Chat build was restored to ~/.purple/plugins/
without overwriting any existing module. Adium was left closed for user login.
Evidence: build/installed-discovery-0.2.0.log.

## 0.2.1: installed protocol icons

The backend now reports PRPL list_icon names and installed icon candidates from
its libpurple prefix (MacPorts /opt/local/share), XDG data roots, Pidgin/Purple
pixmap directories and hicolor application icon directories. Adium selects
small/list and large representations, exposes their file paths for message
views, and returns independent NSImages for flipped variants. Missing or corrupt
images fall back to the generic network icon.

The full backend/frontend/IPC suite passes, with new tests for Pidgin and hicolor
icon discovery, protocol icon names differing from PRPL IDs, size selection,
corrupt/deleted file fallback and independent image instances. Installed helper
verification finds actual MacPorts icons for XMPP, IRC, Gadu-Gadu, GroupWise,
SIMPLE and Zephyr. Discord and Google Chat have no installed icon files on this
VM, so those services keep the fallback until their artwork is installed.

Installed 0.2.1 with the previous bundle backed up; release ZIP copied to the VM
Downloads directory. Evidence: build/system-test-0.2.1.log and
build/icon-discovery-0.2.1.log. No user account login was attempted.

## Ubuntu cross-compilation and release workflow

Published https://github.com/EionRobb/adium-dynamic-purple with an Ubuntu 24.04
build using osxcross at 27d21e4977c9751d01199c7a226a6faf494c3dd9. The toolchain
uses the checksum-verified macOS 11.3 SDK. The frontend retains its 10.6 SDK and
10.8 deployment target; the helper targets 10.15 and links signed MacPorts
darwin_19 x86_64 packages. No MacPorts libraries are included in the ZIP.

Initial Ubuntu run 40239452501 passed: both Mach-O executables are x86_64,
frontend linkage is limited to the Adium/Cocoa side, helper linkage points to
/opt/local, and bundle version, executable permissions and archive contents are
checked. Workflow artifacts include package archive checksums and linkage reports.

Downloaded that run's ZIP and exercised the actual cross-compiled bundle and
helper on the Intel macOS 15.7.7 VM, against its installed libpurple 2.14.14.
The full backend fixture, frontend and real-helper IPC tests passed, including
discovery of eight installed protocols, runtime isolation and helper restart.
BACKEND_PREBUILT=1 prevents the fixture harness replacing the downloaded helper.
The installed plugin and real user accounts were not changed by these tests.
Local evidence: build/ci-first.log and build/ci-cross-vm.log.

Matching vVERSION tags publish a release ZIP and SHA-256 checksum after the
Ubuntu checks pass. Other builds upload artifacts without creating releases.
