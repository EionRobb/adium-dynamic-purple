"""Exercise the native libpurple backend without network access."""
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import time

root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="adp-backend-") as profile:
    icon_root = Path(profile, "icon-data")
    small_icon = icon_root / "pixmaps/pidgin/protocols/16/test.png"
    themed_icon = icon_root / "icons/hicolor/48x48/apps/im-test.png"
    for icon in (small_icon, themed_icon):
        icon.parent.mkdir(parents=True, exist_ok=True)
        icon.write_bytes(b"metadata discovery fixture")
    Path(profile, "accounts.xml").write_text('''<?xml version="1.0"?>
<account version="1.0"><account><protocol>prpl-adp-backend-fixture</protocol>
<name>stale-account</name><settings ui="adium-dynamic-purple">
<setting name="auto-login" type="bool">1</setting></settings>
<statuses><status type="available" name="Online" active="true"/></statuses>
</account></account>''')
    env = dict(os.environ, ADP_BACKEND_PROFILE=profile,
               ADP_BACKEND_PLUGIN_PATH=str(root / "build/backend-test/plugins"),
               ADP_ICON_DATA_DIR=str(icon_root))
    p = subprocess.Popen([str(root / "build/macports-purple-backend")], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, text=True)
    events = queue.Queue()
    seen = []
    def reader():
        for line in p.stdout:
            try:
                events.put(json.loads(line))
            except Exception as exc:
                events.put(exc)
        events.put(EOFError("helper exited"))
    threading.Thread(target=reader, daemon=True).start()
    def send(**command):
        p.stdin.write(json.dumps(command) + "\n")
        p.stdin.flush()
    def wait(event, predicate=lambda e: True):
        end = time.monotonic() + 8
        while time.monotonic() < end:
            e = events.get(timeout=max(.01, end - time.monotonic()))
            if isinstance(e, Exception):
                raise e
            seen.append(e)
            if e.get("event") == event and predicate(e):
                return e
        raise AssertionError("missing event " + event)
    try:
        protocols = wait("protocols")
        fixture = next(p for p in protocols["protocols"] if p["id"] == "prpl-adp-backend-fixture")
        assert fixture["iconName"] == "test"
        assert {"path": str(small_icon), "size": 16} in fixture["icons"]
        assert {"path": str(themed_icon), "size": 48} in fixture["icons"]
        assert len({entry["path"] for entry in fixture["icons"]}) == len(fixture["icons"])
        assert protocols["version"] and protocols["purpleVersion"]
        assert fixture["chat"] and fixture["noPassword"]
        assert fixture["path"].endswith("fixture.so")
        assert fixture["options"][0]["masked"]
        assert (os.stat(profile).st_mode & 0o777) == 0o700
        send(command="discover")
        wait("protocols")
        assert not any(e["event"] == "connected" for e in seen)
        send(command="connect", account="invalid", protocol="prpl-missing", username="test")
        invalid = wait("disconnected", lambda e: e["account"] == "invalid")
        assert invalid["error"] and invalid["reason"] == 7
        send(command="discover")
        wait("protocols")
        send(command="connect", account="unsupported", protocol=fixture["id"],
             username="unsupported", status="invisible")
        wait("disconnected", lambda e: e["account"] == "unsupported" and e["reason"] == 7)
        # Feed a partial JSON line: the core timer must remain responsive later.
        send(command="connect", account="test", protocol=fixture["id"], username="synthetic",
             password="never-save-password", options={"boolean": False, "integer": 12,
             "unknown-string": "opaque-from-client", "unknown-int": 37, "unknown-bool": True},
             status="available", statusMessage="Ready")
        wait("connected", lambda e: e["account"] == "test")
        fields = wait("chatInfo")["fields"]
        assert fields == [{"key": "room", "label": "Room Identifier", "type": "string",
                           "required": True, "masked": False, "default": "Synthetic Room"}]
        send(command="chatInfo", account="test")
        assert wait("chatInfo")["fields"] == fields
        send(command="sendIM", account="test", to="fixture", message="echo-roundtrip")
        incoming = wait("im", lambda e: e["message"] == "echo-roundtrip" and e["flags"] & 2)
        assert incoming["peer"] == "fixture"
        send(command="sendIM", account="test", to="remote-peer", message="remote-outgoing")
        remote = wait("im", lambda e: e["message"] == "remote-outgoing" and e["flags"] & 0x10000)
        assert remote["flags"] & 1
        assert remote["from"] == "synthetic"
        assert remote["peer"] == "remote-peer"
        for recipient, values, action, response in [
            ("input", {"value": "oauth-code"}, 0, "oauth-code"),
            ("input", {}, -1, "cancelled"),
            ("action", {}, 1, "action:1"),
            ("choice", {"value": 77}, 0, "action:77"),
            ("fields", {"token": "field-code", "number": 31, "remember": True}, 0, "fields:field-code:31:1"),
        ]:
            send(command="sendIM", account="test", to=recipient, message="request")
            request = wait("request")
            assert request["account"] == "test"
            if recipient == "input":
                assert request["fields"][0]["masked"]
            if recipient == "choice":
                assert [v["value"] for v in request["fields"][0]["values"]] == [42, 77]
            send(command="reply", request=request["request"], action=action, values=values)
            wait("im", lambda e: e["message"] == response)
            wait("requestClosed", lambda e: e["request"] == request["request"])
        send(command="sendIM", account="test", to="action", message="request")
        request = wait("request")
        send(command="reply", request=request["request"], action=-1)
        wait("requestClosed")
        send(command="sendIM", account="test", to="fields", message="request")
        request = wait("request")
        send(command="reply", request=request["request"], action=0, values={})
        wait("notification", lambda e: "Required fields" in e.get("primary", ""))
        send(command="reply", request=request["request"], action=-1)
        wait("requestClosed")
        # Closing a request from the protocol also dismisses the frontend panel.
        send(command="sendIM", account="test", to="input", message="request")
        request = wait("request")
        send(command="status", account="test", status="invisible")
        wait("notification", lambda e: "does not support" in e.get("primary", ""))
        send(command="joinChat", account="test", components={"room": "Synthetic Room"})
        chat = wait("chatJoined")
        wait("chatBuddy")
        send(command="sendChat", account="test", chat=chat["chat"], message="chat-roundtrip")
        wait("chatMessage", lambda e: e["message"] == "chat-roundtrip")
        send(command="leaveChat", account="test", chat=chat["chat"])
        wait("chatLeft")
        updated = wait("accountUpdated")
        assert updated["options"]["token"] == "echo-roundtrip"
        assert updated["options"]["boolean"] is False
        assert updated["options"]["integer"] == 12
        assert updated["options"]["unknown-string"] == "opaque-from-client"
        assert updated["options"]["unknown-int"] == 37
        assert updated["options"]["unknown-bool"] is True
        send(command="sendIM", account="test", to="refresh", message="refresh")
        wait("im", lambda e: e["message"] == "refresh")
        refreshed = wait("accountUpdated")
        assert refreshed["password"] == "synthetic-refreshed-token"
        assert refreshed["options"]["opaque-cursor"] == "cursor-17"
        assert refreshed["options"]["opaque-int"] == 19
        assert refreshed["options"]["opaque-bool"] is True
        assert refreshed["optionsComplete"] is True
        send(command="sendIM", account="test", to="clear", message="clear")
        wait("im", lambda e: e["message"] == "clear")
        cleared = wait("accountUpdated")
        assert cleared["optionsComplete"] is True
        assert cleared["options"]["token"] == ""
        assert "opaque-cursor" not in cleared["options"]
        assert "opaque-int" not in cleared["options"]
        assert "password" not in cleared
        send(command="disconnect", account="test")
        wait("requestClosed", lambda e: e["request"] == request["request"])
        wait("disconnected")
        send(command="connect", account="test", protocol=fixture["id"], username="synthetic",
             password="never-save-password", status="available")
        wait("connected", lambda e: e["account"] == "test")
        p.stdin.close()
        assert p.wait(timeout=8) == 0
        stderr = p.stderr.read()
        assert "CRITICAL" not in stderr, stderr
        for secret in ["never-save-password", "oauth-code", "field-code", "echo-roundtrip",
                       "synthetic-refreshed-token", "cursor-17"]:
            assert secret not in stderr
            for file in Path(profile).rglob("*"):
                if file.is_file():
                    assert secret.encode() not in file.read_bytes(), str(file)
        print("PASS: native discovery, GLib timer login, IM, OAuth input/action/choice/fields, cancellation, chat, options, EOF; no credential persistence")
    finally:
        if p.poll() is None:
            p.kill()
            p.wait()
