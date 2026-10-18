#!/usr/bin/env python3
"""End-to-end check of the view:counter flow against a running server.

Expects ziggy on ws://127.0.0.1:9224 (start with `zig build run`).
"""
import base64
import json
import os
import re
import socket
import struct
import sys
import urllib.error
import urllib.request


class WS:
    def __init__(self, host="127.0.0.1", port=9224, path="/ws"):
        self.sock = socket.create_connection((host, port), timeout=5)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall(
            (
                f"GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\n"
                "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
            ).encode()
        )
        resp = b""
        while b"\r\n\r\n" not in resp:
            resp += self.sock.recv(4096)
        assert b"101" in resp.split(b"\r\n")[0], resp

    def send(self, obj):
        self.send_raw(json.dumps(obj).encode())

    def send_raw(self, data):
        mask = os.urandom(4)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
        header = bytes([0x81])
        if len(data) < 126:
            header += bytes([0x80 | len(data)])
        elif len(data) < 65536:
            header += bytes([0x80 | 126]) + struct.pack(">H", len(data))
        else:
            header += bytes([0x80 | 127]) + struct.pack(">Q", len(data))
        self.sock.sendall(header + mask + masked)

    def recv_exact(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("closed")
            buf += chunk
        return buf

    def recv(self):
        hdr = self.recv_exact(2)
        opcode, ln = hdr[0] & 0x0F, hdr[1] & 0x7F
        if ln == 126:
            ln = struct.unpack(">H", self.recv_exact(2))[0]
        elif ln == 127:
            ln = struct.unpack(">Q", self.recv_exact(8))[0]
        return opcode, json.loads(self.recv_exact(ln))

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def as_json(obj):
    return json.dumps(obj, ensure_ascii=False)


def flat(node):
    """Join a render/patch payload into HTML.

    A payload is a nested array of segments, so an attribute like
    data-variant="link" arrives as three separate slots ("data-variant=\\"",
    "link", "\\" data-size=\\""). Substring checks that span a slot boundary
    have to run against this, not against json.dumps.
    """
    if isinstance(node, str):
        return node
    if isinstance(node, list):
        return "".join(flat(x) for x in node)
    return str(node)


def global_total(html):
    """The process-wide counter out of a rendered room page."""
    m = re.search(r"total clicks \(global\): <b>(\d+)</b>", html)
    return int(m.group(1)) if m else None


def expect_silent(ws, seconds=0.4):
    """True when nothing arrives within `seconds`.

    A scoped change must reach exactly its scope: "the other room did not
    hear about this" is only testable by waiting. A *closed* socket is a
    real failure, so only a timeout counts as silence.
    """
    old_timeout = ws.sock.gettimeout()
    ws.sock.settimeout(seconds)
    try:
        ws.recv()
        return False
    except TimeoutError:
        return True
    finally:
        ws.sock.settimeout(old_timeout)


def flat_payload(payload):
    """Flatten a patch payload (path -> segment tree) into HTML text.

    Only *changed* slots are in a patch, so this is fragments, not a page:
    attribute names that did not change are absent, which is why the checks
    below assert on values as much as on substrings.
    """
    return "".join(flat(v) for v in payload.values())


def toast_ids(html):
    """Every rendered toast's id, oldest first (the stack's render order)."""
    return re.findall(r'id="zc-toast-(\d+)"', html)


def set_in(node, indices, value):
    for i in indices[:-1]:
        node = node[int(i)]
    node[int(indices[-1])] = value


class Slot:
    """One children slot, kept the way the browser keeps it.

    The client writes every patch value into its own tree and then morphs the
    DOM from the flattened result, so a check that looks only at the last
    patch cannot see a stack's *contents*. This mirrors that slot: a path
    inside it either replaces the whole slot (the framework emits
    `{"<slot>": [...]}` when one side of the diff is empty), replaces,
    appends or clears a direct child, or addresses a slot nested in a child.
    """

    def __init__(self, prefix):
        self.prefix = prefix
        self.items = []

    def apply(self, payload):
        for path, value in payload.items():
            if path == self.prefix:
                self.items = list(value)
                continue
            if not path.startswith(self.prefix + "."):
                continue
            rest = path[len(self.prefix) + 1:].split(".")
            i = int(rest[0])
            if len(rest) == 1:
                if value == []:
                    if i < len(self.items):
                        self.items.pop(i)
                elif i < len(self.items):
                    self.items[i] = value
                else:
                    self.items.append(value)
            elif i < len(self.items):
                set_in(self.items[i], rest[1:], value)
            else:
                raise SystemExit(
                    f"slot patch addresses child {i} of {len(self.items)} in "
                    f"{self.prefix}: {path} (payload {list(payload)})")

    def html(self):
        return "".join(flat(v) for v in self.items)

    def messages(self):
        return re.findall(r'data-slot="toast-description">([^<]*)<', self.html())


def path_of(node, needle, path=()):
    """The path of the first segment whose text contains `needle`.

    Checks that care about *where* something was patched derive the path from
    the render instead of hardcoding indices — the same discipline the brief
    asks of the rest of this script.
    """
    if isinstance(node, str):
        return path if needle in node else None
    if isinstance(node, list):
        for i, child in enumerate(node):
            found = path_of(child, needle, path + (i,))
            if found is not None:
                return found
    return None


def dotted(path):
    return ".".join(str(i) for i in path)


def common_prefix(paths):
    """The longest leading path every path in `paths` shares."""
    out = []
    for parts in zip(*paths):
        if len(set(parts)) != 1:
            break
        out.append(parts[0])
    return tuple(out)


class Tree:
    """The client's own tree: patches written into it, then flattened.

    The browser runtime does exactly this (write each patch value at its path,
    then morph the DOM from the flattened result), so flattening it here is
    the closest thing to looking at the page: it catches a patch that is
    *minimal* but wrong, and it lets a check diff two rendered states instead
    of guessing at slot indices.
    """

    def __init__(self, payload):
        self.tree = payload

    def apply(self, payload):
        for path, value in payload.items():
            idx = [int(i) for i in path.split(".")]
            node = self.tree
            for i in idx[:-1]:
                node = node[i]
            if idx[-1] == len(node):
                node.append(value)      # what JS does for node[i] = v
            else:
                node[idx[-1]] = value

    def html(self):
        return flat(self.tree)


failures = []


def check(name, cond, detail=""):
    status = "ok" if cond else "FAIL"
    print(f"[{status}] {name}" + (f" -- {detail}" if detail and not cond else ""))
    if not cond:
        failures.append(name)


def envelope(event, ref=None, topic="view:counter", session=None, version=1, payload=None):
    if session is not None:
        payload = {"session": session, **(payload or {})}
    msg = {"version": version, "type": "publish", "topic": topic, "event": event,
           "payload": payload, "ref": ref}
    return msg


def main():
    # Pages are source templates with inheritance, rendered at build time.
    # What the server sends is still one complete static document per route:
    # no template syntax, no duplicated shell.
    page_paths = ["/", "/counter", "/table", "/form", "/tabs", "/countries",
                  "/room", "/sidebar", "/themes", "/test-morph.html",
                  "/test-floating.html", "/test-dd.html"]
    live = [path for path in page_paths if not path.startswith("/test-")]
    probes = [path for path in page_paths if path.startswith("/test-")]

    statuses, docs = {}, {}
    for path in page_paths:
        try:
            with urllib.request.urlopen(
                    "http://127.0.0.1:9224" + path, timeout=5) as response:
                statuses[path] = response.status
                docs[path] = response.read().decode()
        except urllib.error.HTTPError as err:
            statuses[path] = err.code
            docs[path] = ""

    check("every page is served",
          all(statuses[path] == 200 for path in page_paths),
          str({path: statuses[path] for path in page_paths
               if statuses[path] != 200}))
    check("every page is a complete document after inheritance",
          all(docs[path].startswith("<!DOCTYPE html>")
              and docs[path].rstrip().endswith("</html>")
              and docs[path].count("<!DOCTYPE html>") == 1
              and docs[path].count("<head>") == 1
              and docs[path].count("<body>") == 1
              for path in page_paths))
    check("...with no template syntax and no duplicated stylesheet",
          all("{%" not in docs[path] and "{{" not in docs[path]
              and docs[path].count("/zc.css") <= 1 for path in page_paths))
    check("the app layout gives every live page the live shell",
          all('id="lv"' in docs[path] and 'id="log"' in docs[path]
              and docs[path].count('src="client.js"') == 1
              and 'src="hooks.js"' in docs[path]
              and 'src="theme.js"' in docs[path] for path in live))
    check("the dev probes extend the document layout alone",
          all("zc.css" not in docs[path] and 'id="lv"' not in docs[path]
              for path in probes)
          and "client.js" not in docs["/test-morph.html"]
          and "client.js" not in docs["/test-floating.html"])
    check("page titles survive the inheritance chain",
          "<title>ziggy view:table</title>" in docs["/table"]
          and "<title>ziggy sidebar" in docs["/sidebar"]
          and "<title>ziggy themes" in docs["/themes"])
    check("the floating-ui partial is included where menus can open",
          all("floating-ui.core" in docs[path]
              for path in ["/", "/table", "/sidebar"])
          and all("floating-ui.core" not in docs[path]
                  for path in ["/counter", "/tabs", "/form"]))

    ws = WS()

    # The live session registry is process-wide and keyed by this token, so a
    # fresh token per run keeps the script re-runnable against a server that
    # has already served it (a fixed token resumes at the old count).
    session_id = "e2e-session-" + os.urandom(4).hex()

    # join -> server mounts the view and sends the full render tree
    ws.send(envelope("join", ref=1))
    op, render = ws.recv()
    check("join gets render", op == 1 and render["event"] == "render", str(render))
    check("render echoes join ref", render["ref"] == 1, str(render))
    check("render payload is full tree",
          render["payload"][0].startswith("<p>count:")
          and render["payload"][1] == 0
          and len(render["payload"]) == 4          # counter + empty flash slot
          and render["payload"][3] == [],
          str(render["payload"]))

    # inc -> mutate -> re-render -> diff -> patch, ref paired on the reply
    ws.send(envelope("inc", ref=2))
    op, patch = ws.recv()
    check("inc gets patch", op == 1 and patch["event"] == "patch", str(patch))
    check("patch touches one slot", patch["payload"] == {"1": 1}, str(patch))
    check("patch echoes inc ref", patch["ref"] == 2, str(patch))

    ws.send(envelope("inc", ref=3))
    op, patch = ws.recv()
    check("second inc patches next value", patch["payload"] == {"1": 2}, str(patch))
    check("second inc ref paired", patch["ref"] == 3, str(patch))

    # unknown event -> err reply, ref preserved
    ws.send(envelope("bogus", ref=4))
    op, err = ws.recv()
    check("unknown event gets err", err["type"] == "err", str(err))
    check("err carries reason", err["payload"]["reason"] == "unknown_event", str(err))
    check("err echoes ref", err["ref"] == 4, str(err))
    ws.close()

    # inc before join -> not_joined
    ws2 = WS()
    ws2.send(envelope("inc", ref=5))
    op, err = ws2.recv()
    check("inc before join gets not_joined",
          err["type"] == "err" and err["payload"]["reason"] == "not_joined", str(err))
    check("not_joined echoes ref", err["ref"] == 5, str(err))
    ws2.close()

    # reconnect recovery: a session token in join lets a new connection
    # restore the disconnected view's state
    ws3 = WS()
    ws3.send(envelope("join", ref=10, session=session_id))
    ws3.recv()  # render, count 0
    ws3.send(envelope("inc", ref=11))
    ws3.recv()
    ws3.send(envelope("inc", ref=12))
    op, patch = ws3.recv()
    check("session view counted to 2", patch["payload"] == {"1": 2}, str(patch))
    ws3.close()
    import time
    time.sleep(0.3)  # let the server process the disconnect

    ws4 = WS()
    ws4.send(envelope("join", ref=13, session=session_id))
    op, render = ws4.recv()
    check("rejoin restores disconnected state",
          render["event"] == "render" and render["payload"][1] == 2, str(render))
    ws4.close()

    # unknown session -> fresh mount
    ws5 = WS()
    ws5.send(envelope("join", ref=14, session="never-seen"))
    op, render = ws5.recv()
    check("unknown session remounts fresh",
          render["event"] == "render" and render["payload"][1] == 0, str(render))
    ws5.close()

    # protocol version mismatch -> version_mismatch error event
    ws6 = WS()
    ws6.send(envelope("join", ref=15, version=99))
    op, err = ws6.recv()
    check("version mismatch gets error event",
          err["type"] == "err" and err["event"] == "version_mismatch", str(err))
    check("error echoes claimed version", err["payload"]["version"] == 99, str(err))
    ws6.close()

    # malformed JSON -> malformed error event (connection stays usable)
    ws7 = WS()
    ws7.send_raw(b"this is not json")
    op, err = ws7.recv()
    check("malformed json gets error event",
          err["type"] == "err" and err["event"] == "malformed", str(err))
    ws7.send(envelope("join", ref=17, session="after-malformed"))
    op, render = ws7.recv()
    check("connection usable after malformed message",
          render["event"] == "render" and render["payload"][1] == 0, str(render))
    ws7.close()

    # oversized envelope (over the 4 KiB app cap, under the 16 KiB transport
    # cap) -> message_too_large error event
    ws8 = WS()
    big = envelope("join", ref=18, session="big")
    big["payload"] = {"blob": "a" * 6000}
    ws8.send(big)
    op, err = ws8.recv()
    check("oversized message gets error event",
          err["type"] == "err" and err["payload"]["reason"] == "message_too_large", str(err))
    check("too_large echoes ref", err["ref"] == 18, str(err))
    ws8.close()

    # flash: server-pushed banner, auto-dismissed by a server-side timer
    ws9 = WS()
    ws9.send(envelope("join", ref=20, session="flash-e2e"))
    ws9.recv()
    ws9.send(envelope("flash", ref=21, payload={"message": "Saved!", "ttl_ms": 400}))
    op, patch = ws9.recv()
    check("flash pushes patch with the flash subtree",
          patch["event"] == "patch"
          and patch["ref"] == 21
          and "Saved!" in json.dumps(patch["payload"].get("3", "")),
          str(patch))
    op, dismiss = ws9.recv()
    check("flash auto-dismisses via server-side timer",
          dismiss["event"] == "patch" and dismiss["payload"].get("3") == [],
          str(dismiss))
    ws9.close()

    # table: 100-row live-editable table
    wt = WS()
    wt.send(envelope("join", ref=30, topic="view:table"))
    op, render = wt.recv()
    # The toolbar grew a popover trigger + tooltip, so the row list sits at
    # root index 32 (toolbar segments 0..20, thead 21..31, rows 32).
    check("table renders 100 rows",
          render["event"] == "render" and len(render["payload"][32]) == 100,
          str(render)[:200])

    # edit a name cell -> exactly one patch at that cell's path
    wt.send(envelope("edit_cell", ref=31, topic="view:table",
                     payload={"row": 7, "col": 0, "value": "Lucky"}))
    op, patch = wt.recv()
    check("cell edit patches exactly that cell",
          patch["event"] == "patch"
          and len(patch["payload"]) == 1
          and patch["payload"].get("32.7.2") == "Lucky",  # toolbar+thead -> rows at 32
          str(patch)[:200])

    # sort by name -> patch covering the reordered rows
    wt.send(envelope("sort", ref=32, topic="view:table", payload={"col": 0}))
    op, patch = wt.recv()
    check("sort produces a patch",
          patch["event"] == "patch" and len(patch["payload"]) > 0,
          str(patch)[:200])

    # dropdown inside a table row: toggle opens it (one patch), the menu
    # action patches the row's score cell, outside-close empties the cell
    wt.send(envelope("zc:dropdown:toggle", ref=34, topic="view:table",
                     payload={"id": "row-menu-5", "value": "5"}))
    op, patch = wt.recv()
    check("row dropdown opens as a patch",
          patch["event"] == "patch"
          and "zc-dropdown" in as_json(patch["payload"])
          and any("menuitem" in as_json(v) for v in patch["payload"].values()),
          str(patch)[:300])
    wt.send(envelope("menu_boost", ref=35, topic="view:table",
                     payload={"id": "row-menu-5", "value": "5"}))
    op, patch = wt.recv()
    check("menu action patches the row",
          patch["event"] == "patch"
          and any(v == 100 for v in patch["payload"].values()),
          str(patch)[:300])
    wt.send(envelope("zc:dropdown:toggle", ref=36, topic="view:table",
                     payload={"id": "row-menu-9", "value": "9"}))
    wt.recv()
    wt.send(envelope("zc:dropdown:close", ref=37, topic="view:table",
                     payload={"id": "row-menu-9"}))
    op, patch = wt.recv()
    check("outside-click close empties the menu slot",
          patch["event"] == "patch"
          and len(patch["payload"]) == 1
          and list(patch["payload"].values())[0] == [],
          str(patch)[:300])

    # styled native select drives sorting (back to score: the header-click
    # test above already left the table sorted by name)
    wt.send(envelope("input", ref=38, topic="view:table",
                     payload={"id": "sort-col", "value": "score"}))
    op, patch = wt.recv()
    check("native select re-sorts via input event",
          patch["event"] == "patch" and len(patch["payload"]) > 0,
          str(patch)[:200])

    # popover toggle + close
    wt.send(envelope("zc:popover:toggle", ref=39, topic="view:table"))
    op, patch = wt.recv()
    check("popover opens as a patch",
          patch["event"] == "patch" and "zc-popover" in as_json(patch["payload"]),
          str(patch)[:300])
    wt.send(envelope("zc:popover:close", ref=40, topic="view:table"))
    op, patch = wt.recv()
    check("popover closes as a patch",
          patch["event"] == "patch" and any(v == [] for v in patch["payload"].values()),
          str(patch)[:300])

    # XSS guard: markup in a cell name is escaped
    wt.send(envelope("edit_cell", ref=41, topic="view:table",
                     payload={"row": 2, "col": 0, "value": "<img src=x>"}))
    op, patch = wt.recv()
    check("markup in cell values is escaped",
          patch["event"] == "patch"
          and "&lt;img src=x&gt;" in as_json(patch["payload"])
          and "<img" not in as_json(patch["payload"]).replace("&lt;", ""),
          str(patch)[:300])

    # invalid edit -> error event
    wt.send(envelope("edit_cell", ref=33, topic="view:table",
                     payload={"row": 1, "col": 1, "value": "abc"}))
    op, err = wt.recv()
    check("non-numeric score rejected",
          err["type"] == "err" and err["payload"]["reason"] == "invalid_value",
          str(err))
    wt.close()

    # form: errors appear (and clear) as diffs while typing; submit shows a
    # server-side loading state
    wf = WS()
    wf.send(envelope("join", ref=40, topic="view:form"))
    op, render = wf.recv()
    check("form renders", render["event"] == "render" and render["ref"] == 40)

    wf.send(envelope("input", ref=41, topic="view:form",
                     payload={"id": "f-email", "value": "bad"}))
    op, patch = wf.recv()
    check("validation error appears as a diff",
          patch["event"] == "patch"
          and any("must contain @" in json.dumps(v) for v in patch["payload"].values()),
          str(patch)[:300])

    wf.send(envelope("input", ref=42, topic="view:form",
                     payload={"id": "f-email", "value": "a@b.c"}))
    op, patch = wf.recv()
    check("error clears as a diff",
          patch["event"] == "patch"
          and any(v == "" for v in patch["payload"].values()),
          str(patch)[:300])

    # submit with an incomplete form -> rejected
    wf.send(envelope("submit", ref=43, topic="view:form"))
    op, err = wf.recv()
    check("submit with invalid form rejected",
          err["type"] == "err" and err["payload"]["reason"] == "invalid_form",
          str(err))

    # complete the form, submit -> loading state then saved
    wf.send(envelope("input", ref=44, topic="view:form",
                     payload={"id": "f-name", "value": "Alice"}))
    wf.recv()
    wf.send(envelope("submit", ref=45, topic="view:form"))
    op, loading = wf.recv()

    check("submit shows server-side loading state",
          loading["event"] == "patch"
          and "Saving…" in as_json(loading["payload"])
          and any("disabled" in as_json(v) for v in loading["payload"].values()),
          str(loading)[:300])
    op, done = wf.recv()
    check("submit completes with saved status",
          done["event"] == "patch" and "Saved!" in as_json(done["payload"]),
          str(done)[:300])

    # REGRESSION: an error clearing on the next keystroke must be a minimal
    # diff (exactly the error span -> ""), not a full re-render. The form
    # tree is Form(children)[1] holding TextInput(fields)[14] +
    # TextInput(fields)[14] + Select(children)[7] + Checkbox(controls)[16] +
    # SubmitButton(children)[3] + secondary button + status[3], nested under
    # form[5]; the email field's value echo and error span are at 5.18/5.24.
    # each keystroke's reply touches only the email field's two slots:
    # the value echo ("5.18") and the error span ("5.24")
    wf.send(envelope("input", ref=46, topic="view:form",
                     payload={"id": "f-email", "value": "bad"}))
    op, patch = wf.recv()
    check("regression: error appears as a tight diff",
          patch["event"] == "patch"
          and set(patch["payload"].keys()) == {"5.18", "5.24"}
          and patch["payload"]["5.24"] == "must contain @",
          str(patch)[:300])
    wf.send(envelope("input", ref=47, topic="view:form",
                     payload={"id": "f-email", "value": "bad@ok.com"}))
    op, patch = wf.recv()
    check("regression: error clears on the next keystroke as a diff",
          patch["event"] == "patch"
          and set(patch["payload"].keys()) == {"5.18", "5.24"}
          and patch["payload"]["5.24"] == "",
          str(patch)[:300])

    # REGRESSION: a background patch (another field changing) must not touch
    # the name/email inputs at all.
    wf.send(envelope("input", ref=48, topic="view:form",
                     payload={"id": "f-name", "value": "Zoe"}))
    wf.recv()  # echo patch for the name field itself
    wf.send(envelope("input", ref=49, topic="view:form",
                     payload={"id": "f-sub", "value": False}))
    op, patch = wf.recv()
    check("regression: background patch leaves other inputs' slots alone",
          patch["event"] == "patch"
          and "Zoe" not in as_json(patch["payload"])
          and not any(k in ("5.5", "5.18", "5.23") for k in patch["payload"]),
          str(patch)[:300])

    # REGRESSION: rapid inputs - every reply is a small patch and the final
    # echo converges to the last typed value
    wf.send(envelope("input", ref=50, topic="view:form",
                     payload={"id": "f-name", "value": "A"}))
    wf.send(envelope("input", ref=51, topic="view:form",
                     payload={"id": "f-name", "value": "Al"}))
    wf.send(envelope("input", ref=52, topic="view:form",
                     payload={"id": "f-name", "value": "Alice"}))
    op, p1 = wf.recv()
    op, p2 = wf.recv()
    op, p3 = wf.recv()
    check("regression: fast typing yields small patches",
          all(p["event"] == "patch" and len(p["payload"]) <= 2 for p in (p1, p2, p3)),
          str(p1)[:200])
    check("regression: final echo converges",
          any(v == "Alice" for v in p3["payload"].values()),
          str(p3)[:200])
    wf.close()

    # dialog: a validated form inside a hook-managed, root-level container
    wd = WS()
    wd.send(envelope("join", ref=60, topic="view:form"))
    wd.recv()

    # portal rule: opening is exactly one root-level (undotted) patch
    wd.send(envelope("open_dialog", ref=61, topic="view:form"))
    op, patch = wd.recv()
    keys = list(patch["payload"].keys())
    check("dialog opens as one root-level patch",
          patch["event"] == "patch"
          and len(keys) == 1
          and "." not in keys[0]
          and "zc-dialog" in as_json(patch["payload"]),
          str(patch)[:300])
    slot = keys[0]

    # the form inside the dialog validates as you type, as diffs
    wd.send(envelope("input", ref=62, topic="view:form",
                     payload={"id": "d-email", "value": "bad"}))
    op, patch = wd.recv()
    check("dialog form validates as you type",
          patch["event"] == "patch" and "must contain @" in as_json(patch["payload"]),
          str(patch)[:300])
    wd.send(envelope("input", ref=63, topic="view:form",
                     payload={"id": "d-email", "value": "ok@x.com"}))
    op, patch = wd.recv()
    check("dialog form error clears as a diff",
          patch["event"] == "patch" and '""' in as_json(patch["payload"]).replace(" ", ""),
          str(patch)[:300])

    # zc:dialog:close removes it: one empty patch at the same root slot
    wd.send(envelope("zc:dialog:close", ref=64, topic="view:form"))
    op, patch = wd.recv()
    check("dialog closes as one empty root-level patch",
          patch["event"] == "patch" and patch["payload"] == {slot: []},
          str(patch)[:300])
    wd.close()

    # tabs + accordion: zero hooks, server state, patches via stable ids
    wt2 = WS()
    wt2.send(envelope("join", ref=70, topic="view:tabs"))
    op, render = wt2.recv()
    check("tabs render with active chart",
          render["event"] == "render" and "revenue" in as_json(render["payload"]),
          str(render)[:200])

    # switching tabs: the active indicators + chart region patch; each Tabs
    # tab is a Button(children)[11] nested in the tab list, so the " active"
    # class slot is 0.3.<tab>.7 (revenue 0.3.0.7, users 0.3.1.7); with
    # revenue[0]=42 vs users[0]=12 every bar differs, plus the <h3> title,
    # so expect a small bounded patch (not a re-render)
    wt2.send(envelope("switch_tab", ref=71, topic="view:tabs",
                      payload={"id": "demo-tab-users", "value": "users"}))
    op, patch = wt2.recv()
    keys = list(patch["payload"].keys())
    check("tab switch patches indicators and region",
          patch["event"] == "patch"
          and "0.3.0.7" in keys and "0.3.1.7" in keys  # active indicators
          and any(k.startswith("0.7.2.1.") for k in keys),  # chart bars
          str(patch)[:300])
    n_patches = len(keys)

    # accordion toggle: exactly two patches (aria-expanded + body children)
    wt2.send(envelope("toggle_section", ref=72, topic="view:tabs",
                      payload={"id": "faq-head-recovery", "value": "recovery"}))
    op, patch = wt2.recv()
    check("accordion toggle is two patches",
          patch["event"] == "patch" and len(patch["payload"]) == 2
          and "true" in as_json(patch["payload"]),
          str(patch)[:300])

    # switching back to the first tab: revenue vs users also differ in
    # every bar; patch count should be in the same small range as before
    # countries: master-detail table over the full world dataset, with
    # pagination and a page-size switch
    total = open("src/countries_data.zig").read().count(".{ .name =")
    def find_rows(payload):
        # the rows node is an array of row arrays; each row's first
        # segment is its "<tr id=...>" open tag
        for i, seg in enumerate(payload):
            if (isinstance(seg, list) and seg
                    and isinstance(seg[0], list) and seg[0]
                    and isinstance(seg[0][0], str)
                    and seg[0][0].startswith("<tr id=")):
                return i
        return None

    wc = WS()
    wc.send(envelope("join", ref=80, topic="view:countries"))
    op, render = wc.recv()
    rows_at = find_rows(render["payload"])
    check("countries render first page of the full dataset",
          render["event"] == "render"
          and rows_at is not None
          and len(render["payload"][rows_at]) == 10   # default page size
          and render["payload"][-2] == []             # detail slot empty
          and f"of {total}" in as_json(render["payload"]),
          str(render)[:200])

    # selecting a country patches the detail card (+ the row's button)
    wc.send(envelope("select_country", ref=81, topic="view:countries",
                     payload={"id": "country-2", "value": "2"}))
    op, patch = wc.recv()
    detail_key = str(len(render["payload"]) - 2)
    detail = as_json(patch["payload"].get(detail_key, ""))
    check("selecting a country patches the detail card",
          patch["event"] == "patch"
          and "Algeria" in detail
          and "Algiers" in detail
          and "Arabic" in detail,
          str(patch)[:300])

    wc.send(envelope("close_details", ref=82, topic="view:countries"))
    wc.recv()

    # pagination: next page re-renders the rows and updates the indicator
    wc.send(envelope("paginate", ref=83, topic="view:countries",
                     payload={"value": "next"}))
    op, patch = wc.recv()
    check("next page patches rows and indicator",
          patch["event"] == "patch"
          and "Page 2 /" in as_json(patch["payload"])
          and any(k.startswith(f"{rows_at}.") for k in patch["payload"]),
          str(patch)[:300])

    # prev back to page 1
    wc.send(envelope("paginate", ref=84, topic="view:countries",
                     payload={"value": "prev"}))
    op, patch = wc.recv()
    check("prev page returns to page 1",
          "Page 1 /" in as_json(patch["payload"]),
          str(patch)[:200])

    # prev at the first page is a no-op (clamped, empty diff)
    wc.send(envelope("paginate", ref=85, topic="view:countries",
                     payload={"value": "prev"}))
    op, patch = wc.recv()
    check("prev at first page is a no-op",
          patch["event"] == "patch" and patch["payload"] == {},
          str(patch)[:200])

    # page size switch: rows grow, page resets to 1
    wc.send(envelope("input", ref=86, topic="view:countries",
                     payload={"id": "page-size", "value": "25"}))
    op, patch = wc.recv()
    check("page size switch grows the table and resets the page",
          patch["event"] == "patch"
          and "Page 1 /" in as_json(patch["payload"])
          and any(k == f"{rows_at}.10" or k.startswith(f"{rows_at}.10.") for k in patch["payload"]),
          str(patch)[:300])

    # selection survives sorting (index-based, not position-based)
    wc.send(envelope("select_country", ref=87, topic="view:countries",
                     payload={"id": "country-7", "value": "7"}))
    wc.recv()
    wc.send(envelope("sort", ref=88, topic="view:countries", payload={"col": 3}))
    op, patch = wc.recv()
    check("sorting keeps the selection",
          "India" in as_json(patch["payload"]),
          str(patch)[:200])

    wc.send(envelope("close_details", ref=89, topic="view:countries"))
    op, patch = wc.recv()
    check("closing empties the detail slot",
          patch["event"] == "patch"
          and any(v == [] for v in patch["payload"].values()),
          str(patch)[:300])
    wc.close()

    # kitchen sink: every component on one view
    wk = WS()
    wk.send(envelope("join", ref=90, topic="view:kitchen"))
    op, render = wk.recv()
    whole = as_json(render["payload"])
    whole_html = flat(render["payload"])
    check("kitchen sink renders all components",
          render["event"] == "render"
          and all(s in whole for s in (
              "Counter", "Flash", "Tabs", "Accordion", "Form",
              "Overlays", "Table", "Card", "ks-tabs", "ks-acc", "ks-form",
              "Open dialog", "hover for tooltip")),
          whole[:200])
    # the Card section is composed from the layout primitives, so its slots
    # are the only place these classes appear on the page
    check("kitchen card composes the layout primitives",
          all(s in whole for s in (
              "ks-card-demo", "zc-card-header", "zc-card-title",
              "zc-stack", "zc-sep", "zc-cluster", "zc-card-footer")),
          whole[:200])
    # shadcn parity surface: the six variants, the size scale, and the
    # CardAction slot + compact card size
    check("kitchen shows shadcn's button variants and sizes",
          all(s in whole_html for s in (
              'data-variant="default"', 'data-variant="outline"',
              'data-variant="secondary"', 'data-variant="ghost"',
              'data-variant="destructive"', 'data-variant="link"',
              'data-size="xs"', 'data-size="lg"',
              'data-size="icon-xs"', 'data-size="icon-lg"')),
          whole[:300])
    check("kitchen toast region is mounted, in its default corner",
          'data-slot="toast-region"' in whole_html
          and 'data-corner="bottom-right"' in whole_html
          # the region is empty until something is shown
          and re.search(r'data-corner="bottom-right"></div>', whole_html) is not None,
          whole_html[:300])
    check("kitchen offers all four toast corners",
          all(f'data-lv-value="{c}"' in whole_html for c in
              ("top-left", "top-right", "bottom-left", "bottom-right")),
          whole_html[:300])

    check("kitchen card exposes the action slot and the sm size",
          'data-slot="card-action"' in whole_html
          and 'id="ks-card-sm"' in whole_html
          and 'data-size="sm"' in whole_html,
          whole_html[:300])

    wk.send(envelope("inc", ref=91, topic="view:kitchen"))
    op, patch = wk.recv()
    check("kitchen counter increments",
          any(v == 1 for v in patch["payload"].values()),
          str(patch)[:200])
    # the card reads no server state: same props, same tree, no patch
    check("static card section contributes no patch",
          "ks-card-demo" not in as_json(patch["payload"]),
          str(patch)[:200])

    wk.send(envelope("switch_tab", ref=92, topic="view:kitchen",
                     payload={"value": "beta"}))
    op, patch = wk.recv()
    check("kitchen tabs switch",
          "The second tab" in as_json(patch["payload"]),
          str(patch)[:200])

    wk.send(envelope("input", ref=93, topic="view:kitchen",
                     payload={"id": "ks-email", "value": "bad"}))
    op, patch = wk.recv()
    check("kitchen form validates",
          "must contain @" in as_json(patch["payload"]),
          str(patch)[:200])

    wk.send(envelope("open_dialog", ref=94, topic="view:kitchen"))
    op, patch = wk.recv()
    check("kitchen dialog opens at root",
          patch["event"] == "patch"
          and any("zc-dialog" in as_json(v) for v in patch["payload"].values()),
          str(patch)[:300])
    wk.send(envelope("zc:dialog:close", ref=95, topic="view:kitchen"))
    op, patch = wk.recv()
    check("kitchen dialog closes",
          patch["event"] == "patch" and any(v == [] for v in patch["payload"].values()),
          str(patch)[:200])

    # The kitchen's popover: the trigger is a Button in the Overlays section
    # and the panel is an overlay appended at the root. (It used to append
    # `popover[1]` — one *dynamic* segment of the trigger — so the panel never
    # rendered and the anchor id showed up as loose text in the page.)
    wk.send(envelope("zc:popover:toggle", ref=121, topic="view:kitchen",
                     payload={"id": "ks-pop-trigger", "value": "ks-pop-trigger"}))
    op, patch = wk.recv()
    pop_html = flat_payload(patch["payload"])
    check("kitchen popover opens with its body",
          patch["event"] == "patch" and 'class="zc-popover"' in pop_html
          and "positioned by Floating UI" in pop_html,
          str(patch)[:300])
    check("...and renders no loose anchor text",
          not any(isinstance(v, str) and v == "ks-pop-trigger"
                  for v in patch["payload"].values()),
          str(patch)[:200])
    wk.send(envelope("zc:popover:close", ref=122, topic="view:kitchen",
                     payload={"id": "ks-pop-trigger"}))
    op, patch = wk.recv()
    check("kitchen popover closes",
          patch["event"] == "patch"
          and not any(isinstance(v, list) and flat(v).find("zc-popover") >= 0
                      for v in patch["payload"].values()),
          str(patch)[:200])

    wk.send(envelope("zc:dropdown:toggle", ref=96, topic="view:kitchen"))
    op, patch = wk.recv()
    check("kitchen dropdown opens",
          any("menuitem" in as_json(v) for v in patch["payload"].values()),
          str(patch)[:300])
    # the full shadcn row taxonomy on one menu
    opened = flat_payload(patch["payload"])
    check("kitchen dropdown renders shadcn's row kinds",
          all(s in opened for s in (
              "dropdown-menu-label", "dropdown-menu-separator",
              "dropdown-menu-checkbox-item", "dropdown-menu-radio-item",
              "dropdown-menu-sub-trigger", "dropdown-menu-shortcut",
              # the first radio row is checked, so its aria-checked is true
              # and its indicator renders; the last row is destructive
              'aria-checked="true"', "dropdown-menu-radio-item-indicator",
              'data-variant="destructive"')),
          opened[:300])
    check("kitchen dropdown submenu starts closed",
          'aria-expanded="false"' in opened and "dropdown-menu-sub-content" not in opened,
          opened[:300])
    # every row kind carries shadcn's data-slot name

    # the sub-trigger opens a nested panel anchored to it, without closing
    # the menu (the panel is a child of the menu, so outside-click ignores it)
    wk.send(envelope("zc:dropdown:sub", ref=108, topic="view:kitchen",
                     payload={"value": "share"}))
    op, patch = wk.recv()
    opened = flat_payload(patch["payload"])
    check("kitchen submenu opens nested, keeping the menu",
          "dropdown-menu-sub-content" in opened
          and 'data-zc-anchor="ks-dd-trigger-sub-share"' in opened
          and 'data-zc-placement="right-start"' in opened
          and "menuitem" in opened
          # the nested menu carries its own rows, including a disabled one
          and "disabled data-disabled=\"true\"" in opened
          and all(v != [] for v in patch["payload"].values()),
          opened[:300])
    wk.send(envelope("zc:dropdown:sub", ref=109, topic="view:kitchen",
                     payload={"value": "share"}))
    op, patch = wk.recv()
    check("kitchen submenu closes on the same trigger",
          "dropdown-menu-sub-content" not in flat_payload(patch["payload"]),
          str(patch)[:300])

    # a checkbox row patches aria-checked and the mirrored state line, and
    # (unlike a plain row) leaves the menu open — shadcn's behaviour
    wk.send(envelope("ks_dd_details", ref=110, topic="view:kitchen",
                     payload={"value": "details"}))
    op, patch = wk.recv()
    values = list(patch["payload"].values())
    check("kitchen checkbox row toggles and keeps the menu open",
          "true" in values                     # the row's aria-checked slot
          and "on" in values                   # the state line outside the menu
          and any("dropdown-menu-checkbox-item-indicator" in flat(v) for v in values)
          # a closed menu is an emptied list somewhere in the patch
          and not any(v == [] for v in values),
          str(patch["payload"])[:300])

    # a radio row moves the check between rows and updates the state line
    wk.send(envelope("ks_dd_sort", ref=111, topic="view:kitchen",
                     payload={"value": "2"}))
    op, patch = wk.recv()
    values = list(patch["payload"].values())
    check("kitchen radio row moves the check",
          "date" in values                     # the state line outside the menu
          and "true" in values                 # the row gaining the check
          and "false" in values                # the row losing it
          and not any(v == [] for v in values),
          str(patch["payload"])[:300])
    check("kitchen radio row moves the marker, not the whole menu",
          0 < len(patch["payload"]) <= 6,
          f"{len(patch['payload'])} slots: {whole[:200]}")

    wk.send(envelope("ks_action", ref=97, topic="view:kitchen",
                     payload={"value": "bump"}))
    op, patch = wk.recv()
    whole = as_json(patch["payload"])
    check("kitchen dropdown action bumps the count and closes",
          any(v == 11 for v in patch["payload"].values()) and "menuitem" not in whole,
          whole[:300])

    wk.send(envelope("flash", ref=98, topic="view:kitchen",
                     payload={"message": "Hi!", "ttl_ms": 400}))
    op, patch = wk.recv()
    check("kitchen flash shows",
          "Hi!" in as_json(patch["payload"]),
          str(patch)[:200])
    # the dismiss must target the SAME slot the show patch wrote
    show_keys = [k for k, v in patch["payload"].items()
                 if isinstance(v, list) and "Hi!" in as_json(v)]
    op, dismiss = wk.recv()
    dkeys = list(dismiss["payload"].keys())
    check("kitchen flash auto-dismisses",
          dismiss["event"] == "patch"
          and len(dkeys) == 1
          and dkeys[0] in show_keys          # exact slot, not just any "0.*"
          and dismiss["payload"][dkeys[0]] == [],
          str(dismiss)[:200])

    # ------------------------------------------------------------------
    # Kitchen toasts: a *stack* of notifications, not one message.
    #
    # The region is mounted from the start, so a toast is a child patch
    # inside it. The queue renders its items oldest-first, so showing one
    # appends (the newest ends up nearest the corner: CSS reverses the stack
    # in the top corners) and dismissing one compacts the list. Every item
    # has its own deadline, and its close button reports that item's id —
    # with a stack up, "dismiss" would otherwise be ambiguous.
    #
    # `Slot` mirrors the client's copy of the region's children slot, so the
    # checks below can assert on what a user would see, not only on the last
    # patch.
    # ------------------------------------------------------------------
    wk.send(envelope("toast_show", ref=112, topic="view:kitchen",
                     payload={"message": "Saved to your workspace",
                              "level": "success", "ttl_ms": 30000}))
    op, patch = wk.recv()
    toast_keys = [k for k, v in patch["payload"].items()
                  if re.fullmatch(r"0\.\d+\.3", k)]
    toast_html = flat_payload(patch["payload"])
    check("kitchen toast appears in the region's children slot",
          patch["event"] == "patch"
          and len(patch["payload"]) == 1
          and len(toast_keys) == 1
          and 'data-slot="toast"' in toast_html
          # because the [data-corner] rules position the *region*, a toast
          # inherits the corner without knowing it
          and "Saved to your workspace" in toast_html,
          str(patch)[:300])
    check("kitchen success toast is a status region, not an alert",
          'data-level="success"' in toast_html and 'role="status"' in toast_html,
          toast_html[:200])
    # the region's own slot path (its corner is at .1) and its children slot
    # (the stack itself), so the checks below can address both
    region_prefix = toast_keys[0].rsplit(".", 1)[0]
    toast_slot = toast_keys[0]
    stack = Slot(toast_slot)
    stack.apply(patch["payload"])
    first_id = toast_ids(toast_html)[0]
    check("a toast's close button reports that toast's id",
          f'data-lv-value="{first_id}"' in toast_html,
          toast_html[:200])

    # A second toast appends exactly one slot: the first toast's slots are
    # untouched, so nothing in the stack re-animates when one arrives.
    wk.send(envelope("toast_show", ref=113, topic="view:kitchen",
                     payload={"message": "Draft saved", "level": "info",
                              "ttl_ms": 30000}))
    op, patch = wk.recv()
    stack.apply(patch["payload"])
    check("a second toast appends exactly one slot",
          list(patch["payload"]) == [toast_slot + ".1"],
          str(patch)[:300])
    check("the stack holds both toasts, oldest first",
          stack.messages() == ["Saved to your workspace", "Draft saved"],
          stack.html()[:300])
    second_id = toast_ids(stack.html())[-1]  # the newest is the last child
    check("each toast in the stack carries its own id",
          second_id != first_id,
          f"{first_id} vs {second_id}")

    # A third with a much shorter deadline: it expires alone, while the two
    # older ones stay. The expiry patch comes from the queue's reaper
    # re-rendering the view through the ordinary diff, so it carries no ref
    # (nothing asked for it) and no stale-cache special case.
    wk.send(envelope("toast_show", ref=114, topic="view:kitchen",
                     payload={"message": "Upload failed", "level": "err",
                              "ttl_ms": 400}))
    op, patch = wk.recv()
    stack.apply(patch["payload"])
    check("a third toast appends and is an alert",
          list(patch["payload"]) == [toast_slot + ".2"]
          and 'role="alert"' in flat_payload(patch["payload"]),
          str(patch)[:300])
    op, patch = wk.recv()
    stack.apply(patch["payload"])
    check("each toast has its own deadline: the short one expires alone",
          patch["topic"] == "view:kitchen" and patch["ref"] is None
          and patch["payload"] == {toast_slot + ".2": []},
          str(patch)[:300])
    check("the expiry leaves the other toasts alone",
          stack.messages() == ["Saved to your workspace", "Draft saved"],
          stack.html()[:300])

    # ...and the view's cached tree knows it: the next render must not repeat
    # that clear. (Expiry now goes through the render path, so this is a
    # regression guard rather than the special case it used to be.)
    wk.send(envelope("toast_corner", ref=115, topic="view:kitchen",
                     payload={"value": "bottom-left"}))
    op, patch = wk.recv()
    check("kitchen does not repeat a timer-driven clear",
          not any(p.startswith(toast_slot) for p in patch["payload"])
          and patch["payload"].get(region_prefix + ".1") == "bottom-left",
          str(patch)[:200])

    # Closing addresses one toast by id. Removing the middle one compacts the
    # list, so the survivor shifts down and the vacated tail slot is cleared.
    wk.send(envelope("zc:toast:dismiss", ref=116, topic="view:kitchen",
                     payload={"id": "", "value": second_id}))
    op, patch = wk.recv()
    stack.apply(patch["payload"])
    check("the close button removes the toast it was rendered for",
          stack.messages() == ["Saved to your workspace"],
          stack.html()[:300])
    check("the vacated slot is cleared and the survivor keeps its id",
          patch["payload"].get(toast_slot + ".1") == []
          and f'id="zc-toast-{first_id}"' in stack.html(),
          str(patch)[:300])

    # An id that is not in the stack is an error, and an error is all it is:
    # no patch rides along behind it.
    wk.send(envelope("zc:toast:dismiss", ref=117, topic="view:kitchen",
                     payload={"id": "", "value": "999999"}))
    op, err = wk.recv()
    check("dismissing an unknown toast is an error",
          err["type"] == "err"
          and err["payload"]["reason"] == "unknown_notification",
          str(err)[:200])

    # A full stack drops the oldest, so the newest message is never the one
    # lost. This is the demo's "Show three" button: three shows in one event.
    wk.send(envelope("toast_burst", ref=118, topic="view:kitchen"))
    op, patch = wk.recv()
    stack.apply(patch["payload"])
    check("a burst past the capacity keeps the three newest",
          stack.messages() == ["First: the stack grows",
                               "Second: its own deadline",
                               "Third: close one and the rest close the gap"],
          stack.html()[:400])
    check("the oldest toast was evicted, not kept alongside",
          "Saved to your workspace" not in stack.html()
          and stack.html().count('data-slot="toast"') == 3,
          stack.html()[:300])

    # Moving the corner is one patch on the region (plus the two buttons
    # whose active state flips) — the stack inside is untouched, which is why
    # the corner lives on the region and not on each toast.
    wk.send(envelope("toast_corner", ref=119, topic="view:kitchen",
                     payload={"value": "top-left"}))
    op, patch = wk.recv()
    check("kitchen corner switch patches the region",
          patch["payload"].get(region_prefix + ".1") == "top-left"
          and "data-corner" not in flat_payload(patch["payload"]),
          str(patch)[:200])
    check("kitchen corner switch leaves the stack alone",
          not any(isinstance(v, list) and flat(v).find("zc-toast") >= 0
                  for v in patch["payload"].values()),
          str(patch)[:300])

    wk.send(envelope("toast_corner", ref=120, topic="view:kitchen",
                     payload={"value": "middle"}))
    op, patch = wk.recv()
    check("kitchen rejects an unknown corner",
          patch.get("type") == "err"
          and patch["payload"].get("reason") == "invalid_value",
          str(patch)[:200])

    # Drain the stack: three closes, and the region is empty again. (Also
    # leaves no reaper timing a toast while the checks below run, so no
    # unsolicited patch can be mistaken for a reply.)
    burst_ids = toast_ids(stack.html())
    check("every toast in the stack has a distinct id",
          len(burst_ids) == 3 and len(set(burst_ids)) == 3,
          str(burst_ids))
    for toast in burst_ids:
        wk.send(envelope("zc:toast:dismiss", topic="view:kitchen",
                         payload={"id": "", "value": toast}))
        op, patch = wk.recv()
        stack.apply(patch["payload"])
    check("closing every toast empties the region",
          stack.html() == "", stack.html()[:200])

    # Teardown race: sessions that show notifications and vanish before the
    # deadlines. Each queue's reaper is sleeping when the connection's slot
    # registry is torn down, so it must wake to a disarmed queue and drop its
    # own reference — touching neither the freed connection nor the message.
    # (Repeated because the failure mode is a race, not a state.)
    for i in range(3):
        wdie = WS()
        wdie.send(envelope("join", topic="view:kitchen"))
        wdie.recv()
        wdie.send(envelope("flash", topic="view:kitchen",
                           payload={"message": f"vanishing banner {i}", "ttl_ms": 200}))
        wdie.recv()
        wdie.send(envelope("toast_show", topic="view:kitchen",
                           payload={"message": f"vanishing toast {i}", "ttl_ms": 200}))
        wdie.recv()
        wdie.close()
    time.sleep(0.6)  # both deadlines pass with every connection long gone
    wlive = WS()
    wlive.send(envelope("join", topic="view:kitchen"))
    op, render = wlive.recv()
    check("a connection that vanishes mid-notification leaves the server serving",
          render["event"] == "render"
          and 'data-slot="toast-region"' in flat(render["payload"]),
          str(render)[:200])
    wlive.close()

    # kitchen table: the full countries feature set
    wk.send(envelope("paginate", ref=104, topic="view:kitchen",
                     payload={"value": "next"}))
    op, patch = wk.recv()
    check("kitchen table paginates",
          patch["event"] == "patch" and "Page 2 /" in as_json(patch["payload"]),
          str(patch)[:200])
    # sorting is a component feature: the header sends {id, value} via
    # data-lv-value (exactly what buildCountriesParts renders), and the
    # sorted column shows a direction marker (asc after the first click)
    wk.send(envelope("sort", ref=105, topic="view:kitchen",
                     payload={"id": "", "value": "3"}))
    op, patch = wk.recv()
    check("kitchen table sorts with a direction marker",
          patch["event"] == "patch"
          and len(patch["payload"]) > 0
          and "▲" in as_json(patch["payload"]),
          str(patch)[:200])
    wk.send(envelope("input", ref=106, topic="view:kitchen",
                     payload={"id": "page-size", "value": "25"}))
    op, patch = wk.recv()
    check("kitchen table page size switch",
          patch["event"] == "patch" and "Page 1 /" in as_json(patch["payload"]),
          str(patch)[:200])
    wk.send(envelope("select_country", ref=107, topic="view:kitchen",
                     payload={"id": "country-2", "value": "2"}))
    op, patch = wk.recv()
    check("kitchen table row details",
          patch["event"] == "patch" and "Algiers" in as_json(patch["payload"]),
          str(patch)[:200])

    # REGRESSION (user-reported segfault): two flashes in a row - the first
    # timer fires while superseded; its early return must not free the
    # FlashState while the handler still holds a pointer
    wk.send(envelope("flash", ref=100, topic="view:kitchen",
                     payload={"message": "first", "ttl_ms": 300}))
    wk.recv()
    wk.send(envelope("flash", ref=101, topic="view:kitchen",
                     payload={"message": "second", "ttl_ms": 1500}))
    wk.recv()
    import time as _t
    _t.sleep(0.6)  # first timer fires here (superseded -> early return)
    wk.send(envelope("inc", ref=102, topic="view:kitchen"))
    op, patch = wk.recv()  # would crash the server before the fix
    check("superseded flash timer does not corrupt flash state",
          patch["event"] == "patch",
          str(patch)[:200])
    wk.send(envelope("zc:dialog:close", ref=103, topic="view:kitchen"))
    op, patch = wk.recv()  # connection still fully alive
    check("connection alive after superseded timer",
          patch["event"] == "patch",
          str(patch)[:200])
    # Let the superseding timer fire too, so shutdown starts with no flash
    # timer still holding its message (a pending timer is not a leak, but a
    # clean run should not rely on the process outliving it).
    _t.sleep(1.2)
    wk.close()

    wt2.send(envelope("switch_tab", ref=73, topic="view:tabs",
                      payload={"id": "demo-tab-revenue", "value": "revenue"}))
    op, patch = wt2.recv()
    check("tab switch back is a bounded diff",
          patch["event"] == "patch" and 3 <= len(patch["payload"]) <= n_patches + 6,
          str(patch)[:300])
    wt2.close()

    # ------------------------------------------------------------------
    # Scoped state (view:room): session, group and global on one page.
    #
    # Three sockets: two in room "alpha", one in room "beta". The point of
    # the checks below is not that a click patches its own tab — that is
    # every other view — but that it patches *exactly* the right other tabs.
    # ------------------------------------------------------------------
    # Group and global state outlive a run (that is the point of parking), so
    # a fresh room id per run keeps the absolute assertions honest; the global
    # total is process-wide by definition and is asserted as a delta.
    suffix = os.urandom(3).hex()
    room_a = "alpha-" + suffix
    room_b = "beta-" + suffix

    ra = WS()
    ra.send(envelope("join", ref=200, topic="view:room", payload={"room": room_a}))
    op, render = ra.recv()
    ra_html = flat(render["payload"])
    check("room mounts with the room id from the join payload",
          render["event"] == "render" and f"<b>{room_a}</b>" in ra_html
          and "members: <b>1</b>" in ra_html,
          ra_html[:200])
    total_base = global_total(ra_html)
    check("the mount reports the process-wide total as a number",
          total_base is not None,
          ra_html[:200])

    rb = WS()
    rb.send(envelope("join", ref=201, topic="view:room", payload={"room": room_a}))
    op, render = rb.recv()
    rb_html = flat(render["payload"])
    check("the second member of a room sees the shared state",
          render["event"] == "render" and "members: <b>2</b>" in rb_html,
          rb_html[:200])
    # ...and the first member is *told*, without asking: joining changed a
    # value (the member count) that the other member renders
    op, patch = ra.recv()
    check("joining a room patches the other members' count",
          patch["event"] == "patch" and patch["ref"] is None
          and 2 in patch["payload"].values(),
          str(patch)[:200])

    rbeta = WS()
    rbeta.send(envelope("join", ref=202, topic="view:room", payload={"room": room_b}))
    op, render = rbeta.recv()
    beta_html = flat(render["payload"])
    check("a different room is a different group",
          render["event"] == "render" and f"<b>{room_b}</b>" in beta_html
          and "members: <b>1</b>" in beta_html
          and "room clicks: <b>0</b>" in beta_html,
          beta_html[:200])

    # A group write: the room's members hear it, the other room does not
    ra.send(envelope("inc", ref=203, topic="view:room"))
    op, patch = ra.recv()
    check("a room click patches the clicker",
          patch["event"] == "patch" and patch["ref"] == 203
          and 1 in patch["payload"].values()          # the room count
          and total_base + 1 in patch["payload"].values(),  # the global total
          str(patch)[:200])
    op, patch = rb.recv()
    check("a room click is pushed to the other members",
          patch["event"] == "patch" and patch["ref"] is None
          and 1 in patch["payload"].values()
          and total_base + 1 in patch["payload"].values(),
          str(patch)[:200])
    check("a room click does not leave the group",
          expect_silent(rbeta),
          "room beta received a patch for room alpha")

    # Session scope: this one must NOT be shared
    ra.send(envelope("panel", ref=204, topic="view:room"))
    op, patch = ra.recv()
    check("a session-scoped change patches only its own session",
          "room-details" in flat_payload(patch["payload"]),
          str(patch)[:200])
    check("a session-scoped change is invisible to the room",
          expect_silent(rb) and expect_silent(rbeta),
          "the room heard about a session-local toggle")

    # Global scope: every session, in every room
    rb.send(envelope("inc_global", ref=205, topic="view:room"))
    op, patch = rb.recv()
    check("a global change patches its originator",
          patch["event"] == "patch" and patch["ref"] == 205
          and total_base + 2 in patch["payload"].values(),
          str(patch)[:200])
    op, patch = ra.recv()
    check("a global change reaches the other room's session too",
          patch["event"] == "patch" and patch["ref"] is None
          and total_base + 2 in patch["payload"].values(),
          str(patch)[:200])
    op, patch = rbeta.recv()
    check("a global change reaches every room",
          patch["event"] == "patch"
          and total_base + 2 in patch["payload"].values(),
          str(patch)[:200])

    # Leaving is the mirror of joining
    rb.close()
    op, patch = ra.recv()
    check("leaving a room patches the remaining members' count",
          patch["event"] == "patch" and 1 in patch["payload"].values(),
          str(patch)[:200])
    check("leaving one room does not disturb another",
          expect_silent(rbeta),
          "room beta heard about a departure in room alpha")

    # Parking: the group's state outlives its members (TTL), so a rejoin
    # finds the room count intact rather than reset
    ra.close()
    rbeta.close()
    _t.sleep(0.3)
    rr = WS()
    rr.send(envelope("join", ref=206, topic="view:room", payload={"room": room_a}))
    op, render = rr.recv()
    rejoin_html = flat(render["payload"])
    check("an emptied room is parked, not forgotten",
          "members: <b>1</b>" in rejoin_html
          and "room clicks: <b>1</b>" in rejoin_html          # survived the leave
          and global_total(rejoin_html) == total_base + 2,    # and so did the global
          rejoin_html[:300])
    rr.close()

    # ------------------------------------------------------------------
    # The sidebar block (view:sidebar) — shadcn's `sidebar-07`.
    #
    # The point of the checks below is not that the page looks like the
    # block's markup (the snapshot checks do that): it is that the sidebar's
    # open state is *one server-owned attribute*. Collapsing the whole
    # sidebar — gap, width, labels, sub-menus, rail, header height, all of it
    # CSS — must be exactly one patched slot, and the rest of the document
    # byte-identical. `Tree` holds the client's copy of the render so a check
    # can diff the two states instead of guessing at slot indices.
    # ------------------------------------------------------------------
    sb = WS()
    sb.send(envelope("join", ref=300, topic="view:sidebar"))
    op, render = sb.recv()
    tree = Tree(render["payload"])
    sb_html = tree.html()
    check("the sidebar block mounts as a provider + sidebar + inset",
          render["event"] == "render"
          and 'data-slot="sidebar-wrapper"' in sb_html
          and 'data-state="expanded"' in sb_html
          and 'data-side="left"' in sb_html
          and 'data-variant="sidebar"' in sb_html
          and 'data-collapsible="icon"' in sb_html
          and 'data-slot="sidebar-container"' in sb_html
          and 'data-slot="sidebar-inset"' in sb_html
          and 'data-slot="sidebar-scrim"' in sb_html,
          sb_html[:300])
    check("the frame is a SidebarLayout with a full-width sticky SiteHeader",
          'data-slot="site-header"' in sb_html
          and 'data-sticky="true"' in sb_html
          and 'data-slot="site-header-bar"' in sb_html
          and 'class="zc-sep zc-sep-vertical dash-header-sep"' in sb_html
          and 'data-header="full"' in sb_html
          and 'data-slot="sidebar-body"' in sb_html
          and sb_html.index('data-slot="site-header"') < sb_html.index('data-slot="sidebar-body"'),
          sb_html[:500])
    check("the team switcher shows the active team and its plan",
          'class="dash-logo"' in sb_html
          and 'data-icon="gallery_vertical_end"' in sb_html
          and ">Acme Inc<" in sb_html
          and ">Enterprise<" in sb_html
          and 'data-lv-value="sb-team"' in sb_html,
          sb_html[:300])
    check("the Platform group has the block's four nav rows, one current",
          ">Platform<" in sb_html
          and all(f'data-icon="{icon}"' in sb_html for icon in
                  ("square_terminal", "bot", "book_open", "settings_2"))
          and sb_html.count('data-lv-click="zc:sidebar:nav"') == 4
          # Playground starts current and expanded
          and 'data-lv-value="playground"' in sb_html
          and sb_html.count('data-active="true"') == 1,
          sb_html[:300])
    check("the current nav row's sub-items are in the tree",
          all(f">{label}<" in sb_html for label in
              ("History", "Starred", "Settings"))
          and 'data-lv-click="zc:sidebar:select"' in sb_html,
          sb_html[:300])
    check("the Projects group is marked to disappear in the icon rail",
          "zc-hide-collapsed" in sb_html
          and ">Projects<" in sb_html
          and all(f">{name}<" in sb_html for name in
                  ("Design Engineering", "Sales & Marketing", "Travel"))
          # each project has one row and one row action, and the action's id
          # is what its dropdown panel anchors to
          and sb_html.count('data-lv-value="sb-project-') == 3
          and sb_html.count('id="sb-project-') == 3,
          sb_html[:400])
    check("the footer user row is an avatar and two lines",
          'data-slot="avatar"' in sb_html and ">CN<" in sb_html
          and ">shadcn<" in sb_html and ">m@example.com<" in sb_html
          and 'data-lv-value="sb-user"' in sb_html,
          sb_html[:300])
    check("the header holds the trigger, a vertical separator and the breadcrumb",
          'data-slot="sidebar-trigger"' in sb_html
          and 'class="zc-sep zc-sep-vertical dash-header-sep"' in sb_html
          and ">Build Your Application<" in sb_html
          and 'data-slot="breadcrumb-page"' in sb_html
          and ">Playground<" in sb_html
          and 'data-slot="sidebar-rail"' in sb_html,
          sb_html[:300])
    check("the layout popover's trigger is on the page, closed",
          'class="zc-popover-trigger"' in sb_html
          and 'class="zc-popover"' not in sb_html,
          sb_html[-400:])

    # ---- one attribute, one patch -------------------------------------
    # Where is the state? One segment after the wrapper's attributes — derived
    # from the render, so this check cannot pass by accident if the markup is
    # reordered.
    wrapper = path_of(tree.tree, 'data-slot="sidebar-wrapper"')
    state_path = dotted(wrapper[:-1] + (wrapper[-1] + 1,))
    before = tree.html()
    sb.send(envelope("zc:sidebar:toggle", ref=301, topic="view:sidebar"))
    op, patch = sb.recv()
    check("collapsing the sidebar is one patched slot",
          patch["event"] == "patch" and patch["ref"] == 301
          and list(patch["payload"]) == [state_path]
          and patch["payload"][state_path] == "collapsed",
          f"{state_path}: {str(patch)[:200]}")
    tree.apply(patch["payload"])
    check("...and the rest of the page is byte-identical",
          tree.html() == before.replace('data-state="expanded"', 'data-state="collapsed"'),
          tree.html()[:300])

    # The rail and the trigger send the same event, so the rail is one patch
    # too (and the sidebar comes back).
    sb.send(envelope("zc:sidebar:toggle", ref=302, topic="view:sidebar"))
    op, patch = sb.recv()
    tree.apply(patch["payload"])
    check("the rail's toggle is the same one-slot patch",
          len(patch["payload"]) == 1 and tree.html() == before,
          str(patch)[:200])

    # ---- the layout switches ------------------------------------------
    sb.send(envelope("zc:sidebar:side", ref=303, topic="view:sidebar",
                     payload={"id": "", "value": "right"}))
    op, patch = sb.recv()
    tree.apply(patch["payload"])
    check("switching the side is one patched slot",
          len(patch["payload"]) == 1 and 'data-side="right"' in tree.html(),
          str(patch)[:200])
    sb.send(envelope("zc:sidebar:side", ref=304, topic="view:sidebar",
                     payload={"id": "", "value": "left"}))
    op, patch = sb.recv()
    tree.apply(patch["payload"])

    sb.send(envelope("zc:sidebar:variant", ref=305, topic="view:sidebar",
                     payload={"id": "", "value": "floating"}))
    op, patch = sb.recv()
    tree.apply(patch["payload"])
    check("switching the variant is one patched slot",
          len(patch["payload"]) == 1 and 'data-variant="floating"' in tree.html(),
          str(patch)[:200])
    sb.send(envelope("zc:sidebar:variant", ref=306, topic="view:sidebar",
                     payload={"id": "", "value": "inset"}))
    op, patch = sb.recv()
    tree.apply(patch["payload"])
    check("the inset variant reaches the provider",
          'data-variant="inset"' in tree.html(), tree.html()[:200])

    # Collapse first: the option checks below flip the mode while the
    # sidebar is in both states, and reopening it is one slot like any other
    # toggle.
    sb.send(envelope("zc:sidebar:toggle", ref=307, topic="view:sidebar"))
    op, patch = sb.recv()
    tree.apply(patch["payload"])
    check("the sidebar is collapsed before the option checks",
          'data-state="collapsed"' in tree.html(), tree.html()[:200])

    # ---- the layout options (component props) ---------------------------
    # The frame is two components: SidebarLayout (open / side / variant /
    # mini) and SiteHeader (sticky_header). Every option is one attribute on
    # the frame, so flipping one is one patched slot.
    sb.send(envelope("zc:sidebar:toggle", ref=307, topic="view:sidebar"))
    op, patch = sb.recv()
    tree.apply(patch["payload"])
    check("the sidebar comes back before the option checks",
          len(patch["payload"]) == 1 and 'data-state="expanded"' in tree.html(),
          str(patch)[:200])

    sb.send(envelope("zc:sidebar:mini", ref=308, topic="view:sidebar",
                     payload={"id": "", "value": "off"}))
    op, patch = sb.recv()
    tree.apply(patch["payload"])
    check("turning the mini sidebar off switches the collapse to offcanvas",
          len(patch["payload"]) == 1 and 'data-collapsible="offcanvas"' in tree.html(),
          str(patch)[:200])
    sb.send(envelope("zc:sidebar:mini", ref=309, topic="view:sidebar",
                     payload={"id": "", "value": "on"}))
    op, patch = sb.recv()
    tree.apply(patch["payload"])
    check("...and back on restores the icon rail in one slot",
          len(patch["payload"]) == 1 and 'data-collapsible="icon"' in tree.html(),
          str(patch)[:200])

    # The header placement moves the bar out of the content column and above
    # the whole frame (sidebar-16's structure): a structure patch, not an
    # attribute, so the count is not pinned — the resulting order is.
    sb.send(envelope("zc:sidebar:placement", ref=3090, topic="view:sidebar",
                     payload={"id": "", "value": "inset"}))
    op, patch = sb.recv()
    tree.apply(patch["payload"])
    inset_html = tree.html()
    check("the header can move into the content column",
          'data-header="inset"' in inset_html
          and inset_html.index('data-slot="sidebar-body"')
          < inset_html.index('data-slot="sidebar-inset"')
          < inset_html.index('data-slot="site-header"'),
          inset_html[:500])

    sb.send(envelope("zc:sidebar:sticky", ref=3091, topic="view:sidebar",
                     payload={"id": "", "value": "off"}))
    op, patch = sb.recv()
    tree.apply(patch["payload"])
    check("the site header's sticky option is one patched attribute",
          len(patch["payload"]) == 1 and 'data-sticky="false"' in tree.html(),
          str(patch)[:200])
    sb.send(envelope("zc:sidebar:sticky", ref=3092, topic="view:sidebar",
                     payload={"id": "", "value": "on"}))
    op, patch = sb.recv()
    tree.apply(patch["payload"])
    check("...and switching it back on is one slot too",
          len(patch["payload"]) == 1 and 'data-sticky="true"' in tree.html(),
          str(patch)[:200])

    # ---- the nav --------------------------------------------------------
    # A nav row is a link *and* a disclosure: it becomes current and toggles
    # its own sub-list. Only that row's subtree and the breadcrumb change.
    sb.send(envelope("zc:sidebar:nav", ref=310, topic="view:sidebar",
                     payload={"id": "sb-nav-models", "value": "models"}))
    op, patch = sb.recv()
    tree.apply(patch["payload"])
    check("a nav row opens its sub-list and becomes current",
          ">Models<" in tree.html()
          and 'data-lv-value="models"' in tree.html()
          and patch["payload"].get("0.4") is None,      # not a sidebar collapse
          str(patch)[:200])
    # Two rows change (the old current one loses the highlight, the clicked one
    # gains it and opens) plus the breadcrumb. Nothing else in the sidebar is
    # in the patch set: another nav row's slots would show up here.
    # The nav list's own path, from the four rows' id slots (their common
    # prefix), so the rows are `<rows>.0` .. `<rows>.3`.
    rows = dotted(common_prefix([
        path_of(tree.tree, f"sb-nav-{key}")
        for key in ("playground", "models", "documentation", "settings")
    ]))
    crumb = dotted(path_of(tree.tree, 'data-slot="breadcrumb-page"')[:-1])
    strays = [k for k in patch["payload"]
              if not (k.startswith(rows + ".0") or k.startswith(rows + ".1")
                      or k.startswith(crumb))]
    check("a nav change is confined to the two rows it changed, plus the breadcrumb",
          not strays and len(patch["payload"]) <= 6,
          f"{strays} in {str(patch)[:300]}")
    check("...and the breadcrumb follows the current row",
          re.search(r'data-slot="breadcrumb-page"[^>]*>Models<', tree.html()) is not None,
          tree.html()[:200])

    # A sub-item click moves the highlight and the breadcrumb page.
    sb.send(envelope("zc:sidebar:select", ref=311, topic="view:sidebar",
                     payload={"id": "", "value": "Changelog"}))
    op, patch = sb.recv()
    tree.apply(patch["payload"])
    check("a sub-item becomes the current page",
          re.search(r'data-slot="breadcrumb-page"[^>]*>Changelog<', tree.html()) is not None,
          tree.html()[:200])
    check("the highlight moves off the previous row",
          tree.html().count('data-active="true"') == 1,
          tree.html()[:200])

    # ---- the dropdowns --------------------------------------------------
    sb.send(envelope("zc:dropdown:toggle", ref=312, topic="view:sidebar",
                     payload={"id": "sb-team", "value": "sb-team"}))
    op, patch = sb.recv()
    tree.apply(patch["payload"])
    panel_html = tree.html()
    check("the team switcher opens a menu anchored to its row",
          'data-slot="dropdown-menu-content"' in panel_html
          and 'data-zc-anchor="sb-team"' in panel_html
          # the shortcut is a span after the label, so match the label alone
          and all(name in panel_html for name in ("Acme Inc", "Acme Corp.", "Evil Corp."))
          and "⌘1" in panel_html and "⌘3" in panel_html,
          panel_html[-600:])
    check("...and the trigger says it is expanded",
          'id="sb-team"' in panel_html and 'aria-expanded="true"' in panel_html,
          panel_html[:300])

    # Selecting a team: the row's logo, name and plan change, and the menu
    # closes in the same patch.
    sb.send(envelope("zc:sidebar:team", ref=313, topic="view:sidebar",
                     payload={"id": "", "value": "2"}))
    op, patch = sb.recv()
    tree.apply(patch["payload"])
    check("picking a team re-renders the switcher",
          ">Evil Corp.<" in tree.html() and ">Free<" in tree.html()
          and 'data-icon="command"' in tree.html(),
          tree.html()[:300])
    check("...and closes the menu in the same patch",
          'data-slot="dropdown-menu-content"' not in tree.html(),
          tree.html()[-300:])

    sb.send(envelope("zc:dropdown:toggle", ref=314, topic="view:sidebar",
                     payload={"id": "sb-user", "value": "sb-user"}))
    op, patch = sb.recv()
    tree.apply(patch["payload"])
    check("the user menu opens with the account rows",
          'data-zc-anchor="sb-user"' in tree.html()
          and all(f">{row}<" in tree.html() for row in
                  ("Upgrade to Pro", "Account", "Billing", "Notifications", "Log out")),
          tree.html()[-700:])
    sb.send(envelope("zc:sidebar:menu", ref=315, topic="view:sidebar",
                     payload={"id": "", "value": "account"}))
    op, patch = sb.recv()
    tree.apply(patch["payload"])
    check("a menu row closes its menu",
          'data-slot="dropdown-menu-content"' not in tree.html(),
          tree.html()[-200:])

    sb.send(envelope("zc:dropdown:toggle", ref=316, topic="view:sidebar",
                     payload={"id": "sb-project-1", "value": "sb-project-1"}))
    op, patch = sb.recv()
    tree.apply(patch["payload"])
    check("a project row's action opens its own menu",
          'data-zc-anchor="sb-project-1"' in tree.html()
          and all(f">{row}<" in tree.html() for row in
                  ("View Project", "Share Project", "Delete Project")),
          tree.html()[-700:])
    sb.send(envelope("zc:dropdown:close", ref=317, topic="view:sidebar",
                     payload={"id": "sb-project-1"}))
    op, patch = sb.recv()
    tree.apply(patch["payload"])

    # ---- the layout popover --------------------------------------------
    sb.send(envelope("zc:popover:toggle", ref=318, topic="view:sidebar",
                     payload={"id": "sb-layout", "value": "sb-layout"}))
    op, patch = sb.recv()
    tree.apply(patch["payload"])
    check("the layout popover exposes the component options",
          'data-zc-anchor="sb-layout"' in tree.html()
          and all(f">{label}<" in tree.html() for label in
                  ("Side", "Variant", "Mini sidebar", "Placement", "Sticky"))
          and all(f">{label}<" in tree.html() for label in
                  ("left", "right", "sidebar", "floating", "inset", "full", "off", "on")),
          tree.html()[-900:])
    sb.send(envelope("zc:popover:close", ref=319, topic="view:sidebar",
                     payload={"id": "sb-layout"}))
    op, patch = sb.recv()
    tree.apply(patch["payload"])
    check("the layout popover closes",
          'class="zc-popover"' not in tree.html(),
          tree.html()[-200:])

    # Back to the full-width bar: it is above the sidebar's body again, and a
    # full-width header is sticky by construction.
    sb.send(envelope("zc:sidebar:placement", ref=3191, topic="view:sidebar",
                     payload={"id": "", "value": "full"}))
    op, patch = sb.recv()
    tree.apply(patch["payload"])
    full_html = tree.html()
    check("switching the placement back puts the header above the sidebar",
          'data-header="full"' in full_html
          and full_html.index('data-slot="site-header"')
          < full_html.index('data-slot="sidebar-body"')
          and 'data-sticky="true"' in full_html,
          full_html[:500])

    # ---- errors ---------------------------------------------------------
    sb.send(envelope("zc:sidebar:bogus", ref=320, topic="view:sidebar"))
    op, err = sb.recv()
    check("an unknown sidebar event is an error, with no patch",
          err["type"] == "err" and err["payload"]["reason"] == "unknown_event",
          str(err)[:200])
    sb.send(envelope("zc:sidebar:variant", ref=321, topic="view:sidebar",
                     payload={"id": "", "value": "diagonal"}))
    op, err = sb.recv()
    check("an unknown variant is rejected before any state changes",
          err["type"] == "err" and err["payload"]["reason"] == "invalid_value",
          str(err)[:200])
    sb.send(envelope("zc:sidebar:mini", ref=3211, topic="view:sidebar",
                     payload={"id": "", "value": "maybe"}))
    op, err = sb.recv()
    check("a toggle value other than on/off is rejected",
          err["type"] == "err" and err["payload"]["reason"] == "invalid_value",
          str(err)[:200])
    sb.send(envelope("zc:dropdown:toggle", ref=322, topic="view:sidebar",
                     payload={"id": "", "value": "nope"}))
    op, err = sb.recv()
    check("an unknown menu id is rejected",
          err["type"] == "err" and err["payload"]["reason"] == "invalid_value",
          str(err)[:200])
    sb.close()

    # The page reads shadcn's cookie and passes it in the join payload, so a
    # reload comes back the way it was left: "0" mounts collapsed.
    sbc = WS()
    sbc.send(envelope("join", ref=330, topic="view:sidebar", payload={"sidebar": "0"}))
    op, render = sbc.recv()
    collapsed_html = flat(render["payload"])
    check("the join payload carries the sidebar's last state",
          render["event"] == "render" and 'data-state="collapsed"' in collapsed_html,
          collapsed_html[:200])
    check("...and the page still renders everything, just collapsed",
          ">Platform<" in collapsed_html and ">Acme Inc<" in collapsed_html
          and 'data-slot="sidebar-trigger"' in collapsed_html,
          collapsed_html[:200])

    # ---- the icon rail's popup menus -----------------------------------
    # A rail row is 2rem wide, so its sub-list has nowhere to go. The same
    # `zc:sidebar:nav` click opens one in a popup beside the rail instead:
    # the server knows the collapsed mode, so the row's markup does not
    # change (which is why collapsing is still one patched slot).
    stree = Tree(render["payload"])
    # The popup is a new root child: the render has exactly one (the
    # provider), so the patch appends at that index. Taken before the tree
    # is mutated — Tree wraps the payload list, not a copy of it.
    next_slot = str(len(render["payload"]))
    rail = {"id": "sb-nav-models", "value": "models"}
    sbc.send(envelope("zc:sidebar:nav", ref=331, topic="view:sidebar", payload=rail))
    op, patch = sbc.recv()
    stree.apply(patch["payload"])
    popup = stree.html()
    check("a nav row in the icon rail opens its sub-items in a popup",
          'data-slot="dropdown-menu-content"' in popup
          and 'data-zc-anchor="sb-nav-models"' in popup
          and 'data-zc-placement="right-start"' in popup
          and ">Models<" in popup
          and all(f">{label}<" in popup for label in
                  ("Genesis", "Explorer", "Quantum")),
          popup[-700:])
    check("...as one appended slot, with the rail left collapsed",
          list(patch["payload"]) == [next_slot]
          and 'data-state="collapsed"' in popup
          and popup.count('id="sb-nav-models"') == 1,
          str(patch)[:200])

    sbc.send(envelope("zc:sidebar:nav", ref=332, topic="view:sidebar", payload=rail))
    op, patch = sbc.recv()
    stree.apply(patch["payload"])
    check("clicking the same row again puts the popup away",
          'data-slot="dropdown-menu-content"' not in stree.html(),
          stree.html()[-200:])

    sbc.send(envelope("zc:sidebar:nav", ref=333, topic="view:sidebar", payload=rail))
    op, patch = sbc.recv()
    stree.apply(patch["payload"])
    sbc.send(envelope("zc:sidebar:select", ref=334, topic="view:sidebar",
                      payload={"id": "", "value": "Quantum"}))
    op, patch = sbc.recv()
    stree.apply(patch["payload"])
    check("picking a sub-item in the rail's popup navigates and closes it",
          'data-slot="dropdown-menu-content"' not in stree.html()
          and re.search(r'data-slot="breadcrumb-page"[^>]*>Quantum<', stree.html()) is not None,
          stree.html()[-300:])

    # Re-open: the current page is marked, because the popup's checked row is
    # server state like every other menu's.
    sbc.send(envelope("zc:sidebar:nav", ref=335, topic="view:sidebar", payload=rail))
    op, patch = sbc.recv()
    stree.apply(patch["payload"])
    check("...and the popup marks the current page",
          re.search(r'aria-checked="true"[^>]*data-lv-value="Quantum"', stree.html()) is not None,
          stree.html()[-700:])

    # Expanding the sidebar takes the rail's popup with it.
    sbc.send(envelope("zc:sidebar:toggle", ref=336, topic="view:sidebar"))
    op, patch = sbc.recv()
    stree.apply(patch["payload"])
    check("expanding the sidebar takes the rail's popup with it",
          'data-state="expanded"' in stree.html()
          and 'data-slot="dropdown-menu-content"' not in stree.html(),
          stree.html()[-300:])
    sbc.close()

    # ------------------------------------------------------------------
    # The theme gallery (view:themes) — shadcn's whole registry, rendered
    # from the same generated list the stylesheet is built from.
    #
    # The page is deliberately stateless: a theme is a client preference
    # (`data-base` / `data-accent` on <html>, see pages/theme.js), so the
    # server renders it once and every picker button is inline `onclick`
    # rather than a `data-lv-click`. The checks below pin both halves of
    # that: the palettes are all there, and nothing on the page talks to
    # the server.
    # ------------------------------------------------------------------
    th = WS()
    th.send(envelope("join", ref=400, topic="view:themes"))
    op, render = th.recv()
    tree = Tree(render["payload"])
    th_html = tree.html()
    bases = ['neutral', 'stone', 'zinc', 'mauve', 'olive', 'mist', 'taupe']
    accents = ['amber', 'blue', 'cyan', 'emerald', 'fuchsia', 'green', 'indigo',
               'lime', 'orange', 'pink', 'purple', 'red', 'rose', 'sky', 'teal',
               'violet', 'yellow']
    check("the gallery renders a base card per shadcn base color",
          render["event"] == "render"
          and all(f'data-base="{name}"' in th_html for name in bases)
          and th_html.count('class="tm-card"') == len(bases) + len(accents),
          th_html[:200])
    check("...and an accent card per shadcn accent theme",
          all(f'data-accent="{name}"' in th_html for name in accents)
          and th_html.count("data-tm-accent=") == len(accents) + 1,
          th_html[:200])
    check("the picker drives the browser, not the socket",
          th_html.count("data-lv-click") == 0
          and "zcTheme.setBase('zinc')" in th_html
          and "zcTheme.setAccent('blue')" in th_html
          and "zcTheme.setAccent('')" in th_html,
          th_html[:200])
    check("the gallery previews components inside its own palettes",
          'class="tm-sidebar"' in th_html or 'class="tm-sidebar ' in th_html
          and th_html.count('data-variant="destructive"') >= len(bases)
          and "tm-chart-5" in th_html,
          th_html[:200])
    check("the palette wrappers are balanced markup",
          th_html.count("<div") == th_html.count("</div>"),
          f"{th_html.count('<div')} divs vs {th_html.count('</div>')} closes")
    th.send(envelope("zc:sidebar:toggle", ref=401, topic="view:themes"))
    op, err = th.recv()
    check("the gallery rejects server events, as designed",
          err["type"] == "err" and err["payload"]["reason"] == "unknown_event",
          str(err)[:200])
    expect_silent(th)
    th.close()

    print()
    if failures:
        print(f"{len(failures)} check(s) failed")
        sys.exit(1)
    print("all checks passed")


if __name__ == "__main__":
    main()
