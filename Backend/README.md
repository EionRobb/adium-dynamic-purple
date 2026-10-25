# System libpurple helper

The executable uses MacPorts libpurple 2 and its GLib stack exclusively. It does
not link any Adium frameworks. Adium objects never cross this process boundary.

Source list: `Backend/backend.c`.

Release-equivalent build:

```sh
clang -O2 -g -Wall -Wextra -Wno-unused-parameter Backend/backend.c \
  $(/opt/local/bin/pkg-config --cflags --libs purple json-glib-1.0) \
  -o build/macports-purple-backend
```

`sh tests/backend.sh` builds that release executable and a native no-network
protocol fixture, then runs `tests/backend.py`. The fixture exercises GLib
timers and pipe input watchers, explicit login, messages, input/action/choice/
fields requests, cancellation, group chats and protocol-generated chat forms,
password refresh and opaque settings. The harness also checks startup with a
previously enabled saved account, invalid connect commands, unsupported invisible
status, live-account EOF shutdown, private profile permissions and absence of
test credentials from stderr and files.

IPC consists of one UTF-8 JSON object per line. Commands use `command`; events
use `event`. Discovery is emitted on startup and in response to `discover`.
Its payload includes `version`, `backendVersion`, `purpleVersion`, `ipcVersion`
and `protocols`. IDs supplied in `account` are opaque strings. Chat IDs and action
indices are integers; request IDs are strings (numeric replies are accepted).

Commands: `discover`, `connect`, `disconnect`, `status`, `sendIM`, `typing`,
`addBuddy`, `removeBuddy`, `chatInfo`, `joinChat`, `sendChat`, `leaveChat`, `reply`.
Typing sends `to` and numeric `state` (0 stopped, 1 typing, 2 paused). Buddy
commands accept `name` or `to`, with optional `alias` and `group`. Chat components
are a dictionary of string values, including integer fields encoded as strings,
as required by libpurple. `chatInfo` is also emitted on connection and contains
the protocol's own field keys, labels, defaults, types, masking and constraints.

Events: `protocols`, `connected`, `disconnected`, `im`, `buddy`, `typing`,
`chatInfo`, `chatJoined`, `chatMessage`, `chatLeft`, `chatBuddy`, `request`,
`requestClosed`, `notification`, `accountUpdated`, `backendError`.
Connection validation failures emit `disconnected` with the supplied account ID.
Unsupported status changes leave the existing presence unchanged. Action -1
cancels input/choice/fields requests and closes action requests without invoking
an arbitrary action. Replies supply field values in the `values` dictionary;
single input/choice requests use `values.value`.

The helper polls account changes every two seconds and also captures them on
connection/disconnection/shutdown. `accountUpdated.options` contains all current
scalar protocol settings, including opaque keys. `optionsComplete: true` identifies a full snapshot:
the frontend must replace its opaque settings rather than merge them. Declared
options absent from account settings use their protocol defaults; NULL string
values reset declared options to defaults and omit opaque keys. An updated `password` is
included only when it changes. Identical snapshots emit no event. The frontend
must keep credentials and opaque settings in Keychain. Incoming known options
are checked against their schema; unknown scalar keys retain JSON scalar types.

libpurple 2 has no public accessor for an arbitrary account setting's type. The
helper reads only the leading `PurplePrefType` discriminator of the internal
setting record, then calls public typed getters. This is a deliberate, narrow
libpurple 2 compatibility dependency (present in 2.10 and verified against
MacPorts 2.14.14); libpurple 3 is not supported.

The profile defaults to `~/Library/Application Support/Adium DynamicPurple/backend`
with mode 0700 and umask 0077. Previous saved accounts are disabled and removed
before discovery. Runtime accounts are never added to the persistent account
list; even a protocol setting remember-password cannot persist them. Message
logging is disabled. Standard system plugin paths and `~/.purple/plugins` are
searched by libpurple. Tests can override `ADP_BACKEND_PROFILE` and add a search
path through `ADP_BACKEND_PLUGIN_PATH`.

stdout's original pipe is reserved for IPC, marked close-on-exec; ordinary native
module stdout is redirected to stderr. libpurple debug logging is disabled and
its debug UI sink drops payloads. Third-party stderr must not be stored by the
frontend. IPC uses the blocking pipe supplied by the frontend; the frontend must
continuously drain events. EOF disconnects accounts and shuts down the core.

Protocol metadata includes iconName (from the PRPL list_icon callback) and icons,
an array of {path,size} records for installed artwork. size=0 denotes scalable
artwork. The data prefix of the loaded libpurple and GLib XDG user/system data
directories are searched for Pidgin/Purple protocol pixmaps and hicolor app icons.
ADP_ICON_DATA_DIR adds a test data root. The frontend validates image decoding,
chooses an appropriate size and supplies a generic fallback if needed.
