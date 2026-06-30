#!/usr/bin/env python3
"""
Standalone tests for the opencode Gallager sidecar.

Drives `bin/sidecar` as a real subprocess over its stdio JSON-RPC transport and
asserts the `translate_event` mapping, the awaitingPermission form encoding, and
the `deliver_response` round-trip (HTTP reply against a mock opencode server, and
the keystroke fallback). Zero third-party deps — just the stdlib.

Run:  python3 tests/test_sidecar.py        (from the plugin root)
"""
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SIDECAR = os.path.join(ROOT, "bin", "sidecar")


# --- Sidecar RPC client -------------------------------------------------------
class Sidecar:
    def __init__(self, env=None):
        full_env = dict(os.environ)
        if env:
            full_env.update(env)
        self.proc = subprocess.Popen(
            [sys.executable, SIDECAR],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=full_env,
        )
        self._id = 0

    def _write(self, msg):
        body = json.dumps(msg).encode("utf-8")
        self.proc.stdin.write(b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
        self.proc.stdin.flush()

    def _read_frame(self):
        header = b""
        while b"\r\n\r\n" not in header:
            ch = self.proc.stdout.read(1)
            if not ch:
                return None
            header += ch
        length = 0
        for line in header.split(b"\r\n"):
            if line.lower().startswith(b"content-length:"):
                length = int(line.split(b":", 1)[1].strip())
        body = self.proc.stdout.read(length) if length else b""
        return json.loads(body)

    def request(self, method, params=None):
        """Send a request and return the matching response (skips notifications)."""
        self._id += 1
        rid = "req-%d" % self._id
        self._write({"id": rid, "method": method, "params": params})
        while True:
            frame = self._read_frame()
            if frame is None:
                raise RuntimeError("sidecar closed stdout while awaiting %s" % method)
            if frame.get("id") == rid:
                return frame

    def translate(self, payload, context):
        resp = self.request("translate_event", {
            "pluginID": "opencode",
            "context": context,
            "payload": payload,
        })
        return resp.get("result")

    def deliver_capture_keys(self, request_id, response, session_id="s1"):
        """Send deliver_response and return the send_keys payloads it emits."""
        self._id += 1
        rid = "req-%d" % self._id
        self._write({"id": rid, "method": "deliver_response",
                     "params": {"sessionID": session_id, "requestID": request_id, "response": response}})
        keys = []
        while True:
            frame = self._read_frame()
            if frame is None:
                raise RuntimeError("sidecar closed stdout")
            if frame.get("method") == "send_keys":
                keys.append(frame["params"]["keys"])
            if frame.get("id") == rid:
                return keys

    def close(self):
        try:
            self.request("shutdown")
        except Exception:
            pass
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        self.proc.wait(timeout=5)
        for stream in (self.proc.stdout, self.proc.stderr):
            try:
                stream.close()
            except Exception:
                pass


PANE = "%7"
CTX = {"TMUX_PANE": PANE, "OPENCODE_PROJECT_DIR": "/Users/test/AcmeApp"}


class TranslateEventTests(unittest.TestCase):
    def setUp(self):
        self.sc = Sidecar()
        self.assertEqual(self.sc.request("initialize", {"appVersion": "9.9"}).get("result"), {})

    def tearDown(self):
        self.sc.close()

    def evt(self, etype, properties, ctx=None):
        return self.sc.translate({"type": etype, "properties": properties}, ctx or CTX)

    def test_busy_is_working(self):
        r = self.evt("session.status", {"sessionID": "s1", "status": {"type": "busy"}})
        self.assertEqual(r["state"], {"working": {}})
        self.assertEqual(r["sessionID"], "s1")
        self.assertEqual(r["tmuxPane"], PANE)
        self.assertEqual(r["projectPath"], "/Users/test/AcmeApp")
        # appActions is non-optional in the host's PluginEvent — omitting it makes
        # the host drop the whole event (terminal-icon bug). Must always be present.
        self.assertEqual(r["appActions"], [])

    def test_idle_after_busy_is_done_with_notification(self):
        self.evt("session.status", {"sessionID": "s1", "status": {"type": "busy"}})
        r = self.evt("session.status", {"sessionID": "s1", "status": {"type": "idle"}})
        self.assertEqual(r["state"], {"doneWorking": {"summary": None}})
        self.assertEqual(r["notification"]["title"], "opencode")
        self.assertIn("AcmeApp", r["notification"]["body"])

    def test_fresh_idle_is_idle(self):
        r = self.evt("session.status", {"sessionID": "fresh", "status": {"type": "idle"}})
        self.assertEqual(r["state"], {"idle": {}})

    def test_second_idle_does_not_clear_attention(self):
        self.evt("session.status", {"sessionID": "s1", "status": {"type": "busy"}})
        self.evt("session.status", {"sessionID": "s1", "status": {"type": "idle"}})  # -> done
        r = self.evt("session.status", {"sessionID": "s1", "status": {"type": "idle"}})
        self.assertIsNone(r)  # no opinion → attention preserved

    def test_error_is_done_with_summary(self):
        r = self.evt("session.error", {"sessionID": "s1", "error": {"name": "ApiError", "data": {"message": "boom"}}})
        self.assertEqual(r["state"], {"doneWorking": {"summary": "boom"}})
        self.assertEqual(r["notification"]["body"], "boom")

    def test_permission_asked_builds_form(self):
        r = self.evt("permission.asked", {
            "id": "per_abc",
            "sessionID": "s1",
            "permission": "bash",
            "patterns": ["git push"],
            "always": ["git push *"],
            "metadata": {},
        })
        state = r["state"]["awaitingPermission"]
        self.assertEqual(state["requestID"], "s1:permission:per_abc")
        self.assertEqual(state["_0"]["title"], "Run shell command")
        self.assertEqual(state["_0"]["description"], "git push")
        self.assertTrue(state["_0"]["allowsCustomInstructions"])
        self.assertEqual(state["_0"]["suggestions"][0]["id"], "always")
        self.assertIn("Permission required", r["notification"]["body"])

    def test_permission_updated_legacy_shape(self):
        r = self.evt("permission.updated", {
            "id": "per_x", "sessionID": "s1", "type": "edit",
            "title": "Edit main.swift", "metadata": {"filepath": "main.swift"},
        })
        state = r["state"]["awaitingPermission"]
        self.assertEqual(state["requestID"], "s1:permission:per_x")
        self.assertEqual(state["_0"]["title"], "Edit file")

    def test_permission_then_idle_is_done(self):
        # A permission (even as the first event seen) marks the session working,
        # so the turn-ending idle resolves to doneWorking + notification.
        self.evt("permission.asked", {"id": "per_z", "sessionID": "p1", "permission": "bash", "patterns": ["x"]})
        r = self.evt("session.status", {"sessionID": "p1", "status": {"type": "idle"}})
        self.assertEqual(r["state"], {"doneWorking": {"summary": None}})

    def test_question_asked_builds_replies_form(self):
        r = self.evt("question.asked", {
            "id": "q_req_1",
            "sessionID": "s1",
            "questions": [{
                "question": "Pick a weekend plan",
                "header": "Plan",
                "options": [
                    {"label": "Hike", "description": "outdoors"},
                    {"label": "Beach", "description": "water"},
                ],
                "multiple": False,
                "custom": True,
            }],
        })
        form = r["state"]["awaitingReplies"]
        self.assertEqual(form["requestID"], "s1:question:q_req_1")
        q = form["_0"]["questions"][0]
        self.assertEqual(q["id"], "q0")
        self.assertEqual(q["question"], "Pick a weekend plan")
        self.assertEqual(q["header"], "Plan")
        self.assertFalse(q["multiSelect"])
        self.assertTrue(q["allowsFreeText"])
        self.assertEqual(q["options"][1], {"id": "q0-o1", "label": "Beach", "description": "water", "preview": None})
        self.assertIn("Question", r["notification"]["body"])

    def test_question_custom_defaults_on_when_absent(self):
        r = self.evt("question.asked", {
            "id": "q2", "sessionID": "s1",
            "questions": [{"question": "Q", "header": "H", "options": []}],  # no `custom`
        })
        self.assertTrue(r["state"]["awaitingReplies"]["_0"]["questions"][0]["allowsFreeText"])

    def test_permission_replied_returns_to_working(self):
        r = self.evt("permission.replied", {"sessionID": "s1", "requestID": "per_abc", "reply": "once"})
        self.assertEqual(r["state"], {"working": {}})

    def test_unknown_event_ignored(self):
        r = self.evt("message.part.updated", {"sessionID": "s1"})
        self.assertIsNone(r)

    def test_lifecycle_started_is_idle(self):
        # The bridge's synthetic "opencode loaded me" frame (no sessionID) →
        # session appears idle immediately, keyed by the pane (mirrors Claude's
        # SessionStart → .idle), with no notification.
        r = self.evt("gallager.lifecycle.started", {})
        self.assertEqual(r["state"], {"idle": {}})
        self.assertIsNone(r["notification"])
        self.assertEqual(r["appActions"], [])
        self.assertEqual(r["tmuxPane"], PANE)

    def test_lifecycle_stopped_ends_session(self):
        # The bridge's synthetic dispose frame → AppAction.sessionEnded keyed by
        # the PANE (the host's endAgentSession key), no state opinion, no
        # notification, pane left open by default.
        r = self.evt("gallager.lifecycle.stopped", {})
        self.assertIsNone(r["state"])
        self.assertIsNone(r["notification"])
        self.assertEqual(r["appActions"],
                         [{"sessionEnded": {"sessionID": PANE, "closePaneEligible": False}}])

    def test_lifecycle_stopped_honors_close_pane_setting(self):
        self.sc.request("apply_settings", {"settings": {"close_pane_on_session_end": True}})
        r = self.evt("gallager.lifecycle.stopped", {})
        self.assertEqual(r["appActions"],
                         [{"sessionEnded": {"sessionID": PANE, "closePaneEligible": True}}])

    def test_lifecycle_stopped_without_pane_is_noop(self):
        r = self.evt("gallager.lifecycle.stopped", {}, ctx={"OPENCODE_PROJECT_DIR": "/x"})
        self.assertIsNone(r)  # no pane → nothing the host can key on

    def test_idle_with_no_pane_still_maps(self):
        r = self.evt("session.status", {"sessionID": "s1", "status": {"type": "busy"}},
                     ctx={"TMUX_PANE": "%9"})
        self.assertEqual(r["state"], {"working": {}})
        self.assertEqual(r["tmuxPane"], "%9")


class DeliverResponseTests(unittest.TestCase):
    """Permission answers → keystrokes into the pane (opencode's TUI has no
    reachable HTTP server, so forms are answered the way the built-in agents are)."""

    def setUp(self):
        self.sc = Sidecar()
        self.sc.request("initialize", {})

    def tearDown(self):
        self.sc.close()

    def answer(self, decision, applied=None):
        return self.sc.deliver_capture_keys(
            "s1:permission:per_1",
            {"permission": {"decision": decision, "appliedSuggestionID": applied}})

    def test_allow_once_is_enter(self):
        self.assertEqual(self.answer({"allow": {}}), [[{"enter": {}}]])

    def test_allow_always_is_right_enter_enter(self):
        self.assertEqual(self.answer({"allow": {}}, applied="always"),
                         [[{"right": {}}, {"enter": {}}, {"enter": {}}]])

    def test_deny_is_escape(self):
        self.assertEqual(self.answer({"deny": {}}), [[{"escape": {}}]])

    def test_deny_with_feedback_is_escape(self):
        # No inline feedback box for a top-level session → reject (Escape).
        self.assertEqual(self.answer({"denyWithFeedback": "use tabs"}), [[{"escape": {}}]])

    def test_prompt_is_typed_then_submitted(self):
        keys = self.sc.deliver_capture_keys("rid", {"prompt": {"text": "hello"}})
        self.assertEqual(keys, [[{"text": {"_0": "hello"}}, {"enter": {}}]])


class QuestionDeliveryTests(unittest.TestCase):
    """Question answers → opencode TUI number-key sequences into the pane."""

    def setUp(self):
        self.sc = Sidecar()
        self.sc.request("initialize", {})

    def tearDown(self):
        self.sc.close()

    def _ask(self, questions):
        r = self.sc.translate({
            "type": "question.asked",
            "properties": {"id": "q_req_1", "sessionID": "s1", "questions": questions},
        }, CTX)
        return r["state"]["awaitingReplies"]["requestID"]

    @staticmethod
    def _opts(*labels):
        return [{"label": x, "description": ""} for x in labels]

    def _deliver(self, rid, answers):
        return self.sc.deliver_capture_keys(rid, {"askUserQuestion": {"answers": answers}})

    # --- single non-multi question: number key picks + submits, no tabs --------
    def test_single_select_picks_number_and_submits(self):
        rid = self._ask([{"question": "Pick", "header": "P", "options": self._opts("Hike", "Beach"), "multiple": False}])
        keys = self._deliver(rid, [{"questionID": "q0", "selectedOptionIDs": ["q0-o1"], "freeText": None}])
        self.assertEqual(keys, [[{"text": {"_0": "2"}}]])  # option 2 → pick → auto-submit

    def test_single_select_free_text(self):
        rid = self._ask([{"question": "Pick", "header": "P", "options": self._opts("Hike", "Beach"), "multiple": False}])
        keys = self._deliver(rid, [{"questionID": "q0", "selectedOptionIDs": [], "freeText": "Road trip"}])
        # "Type your own" = number 3 (2 options + 1); type; Enter commits + submits.
        self.assertEqual(keys, [[{"text": {"_0": "3"}}, {"text": {"_0": "Road trip"}}, {"enter": {}}]])

    # --- single multi-select: toggles, then Right to Confirm, Enter submits -----
    def test_multiselect_toggles_then_confirm(self):
        rid = self._ask([{"question": "Toppings", "header": "T",
                          "options": self._opts("Cheese", "Mushroom", "Onion"), "multiple": True}])
        keys = self._deliver(rid, [{"questionID": "q0", "selectedOptionIDs": ["q0-o0", "q0-o2"], "freeText": None}])
        self.assertEqual(keys, [[{"text": {"_0": "1"}}, {"text": {"_0": "3"}}, {"right": {}}, {"enter": {}}]])

    # --- two questions: multi (toggle+Right) then single (pick auto-advances) ---
    def test_two_questions_multi_then_single(self):
        rid = self._ask([
            {"question": "Toppings", "header": "T", "options": self._opts("Cheese", "Mushroom", "Onion"), "multiple": True},
            {"question": "Size", "header": "S", "options": self._opts("Small", "Large"), "multiple": False},
        ])
        keys = self._deliver(rid, [
            {"questionID": "q0", "selectedOptionIDs": ["q0-o0", "q0-o2"], "freeText": None},
            {"questionID": "q1", "selectedOptionIDs": ["q1-o1"], "freeText": None},
        ])
        # Q0 toggle 1,3 then Right → Size; Q1 pick 2 (auto-advance to Confirm); Enter submit.
        self.assertEqual(keys, [[{"text": {"_0": "1"}}, {"text": {"_0": "3"}}, {"right": {}}, {"text": {"_0": "2"}}, {"enter": {}}]])


class SettingsTests(unittest.TestCase):
    def test_command_for_launch_default(self):
        sc = Sidecar()
        try:
            sc.request("initialize", {})
            self.assertEqual(sc.request("command_for_launch").get("result"),
                             {"command": "opencode", "args": [], "env": {}})
        finally:
            sc.close()

    def test_command_path_override_via_initialize(self):
        sc = Sidecar()
        try:
            sc.request("initialize", {"settings": {"command_path": "/opt/oc/opencode", "auto_run": True}})
            self.assertEqual(sc.request("command_for_launch").get("result")["command"], "/opt/oc/opencode")
        finally:
            sc.close()

    def test_auto_run_off_returns_null(self):
        sc = Sidecar()
        try:
            sc.request("initialize", {})
            # apply_settings turns auto-run off → command_for_launch yields null.
            sc.request("apply_settings", {"settings": {"auto_run": False}})
            self.assertIsNone(sc.request("command_for_launch").get("result"))
        finally:
            sc.close()


class InstallTests(unittest.TestCase):
    def test_project_install_honors_config_root(self):
        with tempfile.TemporaryDirectory() as proj:
            env = {"GALLAGER_INGRESS_SOCK": "/tmp/s.sock", "GALLAGER_PLUGIN_ID": "opencode",
                   "GALLAGER_PLUGIN_ROOT": ROOT}
            sc = Sidecar(env)
            try:
                sc.request("initialize", {})
                # Additional-folder row passes an absolute project root.
                self.assertEqual(sc.request("install_status", {"configRoot": proj}).get("result"),
                                 {"notInstalled": {}})
                sc.request("install", {"configRoot": proj})
                dest = os.path.join(proj, ".opencode", "plugin", "gallager.js")
                self.assertTrue(os.path.exists(dest))
                self.assertEqual(sc.request("install_status", {"configRoot": proj}).get("result"),
                                 {"installed": {"version": "0.1.0"}})
            finally:
                sc.close()

    def test_install_substitutes_and_status(self):
        with tempfile.TemporaryDirectory() as cfg:
            env = {
                "GALLAGER_INGRESS_SOCK": "/tmp/fake-ingress.sock",
                "GALLAGER_PLUGIN_ID": "opencode",
                "GALLAGER_PLUGIN_ROOT": ROOT,
                "XDG_CONFIG_HOME": cfg,
            }
            sc = Sidecar(env)
            try:
                sc.request("initialize", {})
                self.assertEqual(sc.request("install_status").get("result"), {"notInstalled": {}})

                res = sc.request("install").get("result")
                self.assertIn("installed", res)

                dest = os.path.join(cfg, "opencode", "plugin", "gallager.js")
                with open(dest) as f:
                    content = f.read()
                self.assertIn("/tmp/fake-ingress.sock", content)
                self.assertNotIn("__GALLAGER_INGRESS_SOCK__", content)
                self.assertIn("GallagerMonitor", content)

                self.assertEqual(sc.request("install_status").get("result"),
                                 {"installed": {"version": "0.1.0"}})

                sc.request("uninstall")
                self.assertFalse(os.path.exists(dest))
                self.assertEqual(sc.request("install_status").get("result"), {"notInstalled": {}})
            finally:
                sc.close()


class ProjectDiscoveryTests(unittest.TestCase):
    def _refresh_and_capture(self, sc):
        sc._id += 1
        rid = "req-%d" % sc._id
        sc._write({"id": rid, "method": "refresh_projects", "params": None})
        projects = []
        while True:
            frame = sc._read_frame()
            if frame is None:
                self.fail("stdout closed")
            if frame.get("method") == "set_projects":
                projects = frame["params"]["projects"]
            if frame.get("id") == rid:
                return projects

    def test_refresh_projects_emits_from_db(self):
        with tempfile.TemporaryDirectory() as data_home, tempfile.TemporaryDirectory() as real_proj:
            dbdir = os.path.join(data_home, "opencode")
            os.makedirs(dbdir)
            db = os.path.join(dbdir, "opencode.db")
            conn = sqlite3.connect(db)
            conn.execute(
                "CREATE TABLE project (id TEXT PRIMARY KEY, worktree TEXT NOT NULL, name TEXT, time_updated INTEGER NOT NULL)"
            )
            conn.execute("INSERT INTO project VALUES (?,?,?,?)", ("p1", real_proj, "", 1782781263179))
            conn.execute("INSERT INTO project VALUES (?,?,?,?)", ("p2", "/no/such/dir/xyz", "Ghost", 1782781263179))
            conn.commit()
            conn.close()

            sc = Sidecar({"XDG_DATA_HOME": data_home})
            try:
                sc.request("initialize", {})  # also emits set_projects (skipped by request())
                projects = self._refresh_and_capture(sc)
                paths = [p["path"] for p in projects]
                self.assertIn(real_proj, paths)               # existing dir surfaces
                self.assertNotIn("/no/such/dir/xyz", paths)    # missing dir filtered out
                p = next(p for p in projects if p["path"] == real_proj)
                self.assertEqual(p["pluginID"], "opencode")
                self.assertEqual(p["name"], os.path.basename(real_proj))  # derived from path
                self.assertIsInstance(p["lastUsed"], (int, float))        # 2001-reference seconds
            finally:
                sc.close()

    def test_no_db_emits_empty(self):
        with tempfile.TemporaryDirectory() as data_home:
            sc = Sidecar({"XDG_DATA_HOME": data_home})
            try:
                sc.request("initialize", {})
                self.assertEqual(self._refresh_and_capture(sc), [])
            finally:
                sc.close()


if __name__ == "__main__":
    if not os.access(SIDECAR, os.X_OK):
        print("sidecar not executable: %s" % SIDECAR)
        sys.exit(1)
    unittest.main(verbosity=2)
