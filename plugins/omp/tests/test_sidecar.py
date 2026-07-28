#!/usr/bin/env python3
"""
Standalone tests for the omp Gallager sidecar.

Drives `bin/sidecar` as a real subprocess over its stdio JSON-RPC transport and
asserts the `translate_event` mapping (session lifecycle, working/done states,
approval forms), deliver_response keystroke injection, the
install/uninstall/install_status round-trip (placeholder substitution into the
omp bridge extension), project discovery from omp's session store, and the
generic-settings handlers. Zero third-party deps — just the stdlib.

Run:  python3 tests/test_sidecar.py        (from the plugin root)
"""
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SIDECAR = os.path.join(ROOT, "bin", "sidecar")

# Seconds between 1970-01-01 and 2001-01-01 (AgentProject.lastUsed reference).
EPOCH_2001 = 978307200.0


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

    def request_capture(self, method, params, capture):
        """Send a request; return (response, [captured notification params])."""
        self._id += 1
        rid = "req-%d" % self._id
        self._write({"id": rid, "method": method, "params": params})
        captured = []
        while True:
            frame = self._read_frame()
            if frame is None:
                raise RuntimeError("sidecar closed stdout while awaiting %s" % method)
            if frame.get("method") == capture:
                captured.append(frame.get("params"))
            if frame.get("id") == rid:
                return frame, captured

    def translate(self, payload, context):
        resp = self.request("translate_event", {
            "pluginID": "omp",
            "context": context,
            "payload": payload,
        })
        return resp.get("result")

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
SESSION = "019faa36-242f-7000-bfc6-e8e80a7aeaa2"
CTX = {"TMUX_PANE": PANE, "OMP_PROJECT_DIR": "/Users/test/AcmeApp"}


class TranslateEventTests(unittest.TestCase):
    def setUp(self):
        self.sc = Sidecar()
        self.assertEqual(self.sc.request("initialize", {"appVersion": "9.9"}).get("result"), {})

    def tearDown(self):
        self.sc.close()

    def evt(self, etype, extra=None, ctx=None):
        payload = {"type": etype, "sessionId": SESSION}
        if extra:
            payload.update(extra)
        return self.sc.translate(payload, ctx if ctx is not None else CTX)

    def test_session_start_is_idle(self):
        r = self.evt("session_start")
        self.assertEqual(r["state"], {"idle": {}})
        self.assertEqual(r["sessionID"], SESSION)
        self.assertEqual(r["tmuxPane"], PANE)
        self.assertEqual(r["projectPath"], "/Users/test/AcmeApp")
        self.assertIsNone(r["notification"])
        # appActions is non-optional in the host's PluginEvent — omitting it makes
        # the host drop the whole event. Must always be present.
        self.assertEqual(r["appActions"], [])

    def test_session_start_with_switch_reason_is_idle(self):
        # The bridge re-labels session_switch/branch/tree as session_start with
        # the replacement reason attached — same idle mapping.
        for reason in ("new", "resume", "fork", "handoff"):
            r = self.evt("session_start", {"reason": reason})
            self.assertEqual(r["state"], {"idle": {}})

    def test_agent_start_is_working(self):
        r = self.evt("agent_start")
        self.assertEqual(r["state"], {"working": {}})
        self.assertEqual(r["appActions"], [])

    def test_agent_end_is_done_with_summary_and_notification(self):
        r = self.evt("agent_end", {"summary": "Fixed the bug.", "stopReason": "stop"})
        self.assertEqual(r["state"], {"doneWorking": {"summary": "Fixed the bug."}})
        self.assertEqual(r["notification"]["title"], "omp")
        self.assertIn("AcmeApp", r["notification"]["body"])

    def test_agent_end_without_summary(self):
        r = self.evt("agent_end", {"stopReason": "stop"})
        self.assertEqual(r["state"], {"doneWorking": {"summary": None}})
        self.assertIn("AcmeApp", r["notification"]["body"])

    def test_agent_end_without_project_path(self):
        r = self.evt("agent_end", {"stopReason": "stop"}, ctx={"TMUX_PANE": PANE})
        self.assertEqual(r["notification"]["body"], "Finished working")

    def test_agent_end_error_uses_error_message(self):
        r = self.evt("agent_end", {"stopReason": "error", "errorMessage": "rate limited"})
        self.assertEqual(r["state"], {"doneWorking": {"summary": "rate limited"}})
        self.assertEqual(r["notification"]["body"], "rate limited")

    def test_agent_end_error_without_message_falls_back(self):
        r = self.evt("agent_end", {"stopReason": "error"})
        self.assertEqual(r["state"], {"doneWorking": {"summary": "omp hit an error"}})

    def test_agent_end_aborted_is_interrupted(self):
        r = self.evt("agent_end", {"stopReason": "aborted"})
        self.assertEqual(r["state"], {"doneWorking": {"summary": "Interrupted"}})
        self.assertEqual(r["notification"]["body"], "Interrupted")

    def test_shutdown_ends_session_keyed_by_pane(self):
        # omp's session_shutdown fires on process exit only (session replacement
        # has its own events), so EVERY shutdown ends the Gallager session.
        r = self.evt("session_shutdown")
        self.assertIsNone(r["state"])
        # sessionEnded is keyed by the PANE id (the host ends sessions by pane).
        self.assertEqual(r["appActions"], [
            {"sessionEnded": {"sessionID": PANE, "closePaneEligible": False}},
        ])

    def test_shutdown_without_pane_is_ignored(self):
        r = self.evt("session_shutdown", ctx={})
        self.assertIsNone(r)

    def test_close_pane_setting_honored_on_shutdown(self):
        self.sc.request("apply_settings", {"settings": {"close_pane_on_session_end": True}})
        r = self.evt("session_shutdown")
        self.assertTrue(r["appActions"][0]["sessionEnded"]["closePaneEligible"])

    def test_unknown_event_is_ignored(self):
        self.assertIsNone(self.evt("message_end"))
        self.assertIsNone(self.evt("something_else"))

    def test_missing_session_id_falls_back_to_pane(self):
        r = self.sc.translate({"type": "agent_start"}, CTX)
        self.assertEqual(r["sessionID"], PANE)

    def test_unknown_method_fails_cleanly(self):
        resp = self.sc.request("bogus_method")
        self.assertEqual(resp["error"]["code"], "method_not_found")


class ApprovalFormTests(unittest.TestCase):
    """tool_approval_requested/resolved → awaitingPermission → deliver_response
    keystrokes. Dialog layout (Approve pre-selected / Deny below / Enter
    confirms) verified against omp v17.1.8's uiContext.select."""

    def setUp(self):
        self.sc = Sidecar()
        self.sc.request("initialize", {})

    def tearDown(self):
        self.sc.close()

    def evt(self, etype, extra=None):
        payload = {"type": etype, "sessionId": SESSION}
        if extra:
            payload.update(extra)
        return self.sc.translate(payload, CTX)

    def request_approval(self, tool_call_id="call-1", **extra):
        return self.evt("tool_approval_requested", dict(
            {"toolCallId": tool_call_id, "toolName": "bash", "approvalMode": "always-ask"},
            **extra,
        ))

    def deliver(self, response, request_id="call-1"):
        resp, keys = self.sc.request_capture("deliver_response", {
            "sessionID": SESSION, "requestID": request_id, "response": response,
        }, "send_keys")
        self.assertEqual(resp["result"], {})
        return keys

    def test_approval_requested_opens_permission_form(self):
        r = self.request_approval(detail="rm -rf build/", reason="Critical pattern detected")
        awaiting = r["state"]["awaitingPermission"]
        self.assertEqual(awaiting["requestID"], "call-1")
        req = awaiting["_0"]
        self.assertEqual(req["title"], "Allow bash")
        self.assertIn("rm -rf build/", req["description"])
        self.assertIn("Critical pattern detected", req["description"])
        self.assertFalse(req["isAutoApprovable"])
        self.assertEqual(req["suggestions"], [])
        self.assertTrue(req["allowsCustomInstructions"])

    def test_approval_requested_without_detail(self):
        r = self.request_approval(toolName="browser")
        req = r["state"]["awaitingPermission"]["_0"]
        self.assertEqual(req["title"], "Allow browser")
        self.assertEqual(req["description"], "")

    def test_approval_resolved_returns_to_working(self):
        self.request_approval()
        r = self.evt("tool_approval_resolved", {"toolCallId": "call-1", "approved": True})
        self.assertEqual(r["state"], {"working": {}})

    def test_allow_sends_enter(self):
        self.request_approval()
        keys = self.deliver({"permission": {"decision": "allow", "appliedSuggestionID": None}})
        self.assertEqual(len(keys), 1)
        self.assertEqual(keys[0]["sessionID"], SESSION)
        self.assertEqual(keys[0]["keys"], [{"enter": {}}])

    def test_deny_sends_down_enter(self):
        self.request_approval()
        keys = self.deliver({"permission": {"decision": "deny", "appliedSuggestionID": None}})
        self.assertEqual(len(keys), 1)
        # Down + Enter, with pacing delays interleaved by _emit_keys.
        real = [k for k in keys[0]["keys"] if "delay" not in k]
        self.assertEqual(real, [{"down": {}}, {"enter": {}}])

    def test_deny_with_feedback_types_steer_message(self):
        self.request_approval()
        keys = self.deliver({"permission": {
            "decision": {"denyWithFeedback": "use tabs instead"}, "appliedSuggestionID": None,
        }})
        real = [k for k in keys[0]["keys"] if "delay" not in k]
        self.assertEqual(real, [
            {"down": {}}, {"enter": {}},
            {"text": {"_0": "use tabs instead"}}, {"enter": {}},
        ])

    def test_prompt_response_types_text(self):
        keys = self.deliver({"prompt": {"text": "keep going"}})
        real = [k for k in keys[0]["keys"] if "delay" not in k]
        self.assertEqual(real, [{"text": {"_0": "keep going"}}, {"enter": {}}])

    def test_empty_reply_after_stop_sends_nothing(self):
        keys = self.deliver({"replyAfterStop": {"text": ""}})
        self.assertEqual(keys, [])


class AskFormTests(unittest.TestCase):
    """ask_started/ask_ended → awaitingReplies → deliver_response keystrokes.
    Rich-dialog layout (per-question tabs + Submit tab when >1 question or any
    multi; options + an Other row; clamped cursor starting on `recommended`)
    verified against omp v17.1.8's ask-dialog.ts."""

    def setUp(self):
        self.sc = Sidecar()
        self.sc.request("initialize", {})

    def tearDown(self):
        self.sc.close()

    def evt(self, etype, extra=None):
        payload = {"type": etype, "sessionId": SESSION}
        if extra:
            payload.update(extra)
        return self.sc.translate(payload, CTX)

    def start_ask(self, questions, tool_call_id="ask-1"):
        return self.evt("ask_started", {"toolCallId": tool_call_id, "questions": questions})

    def deliver(self, answers, request_id="ask-1"):
        resp, keys = self.sc.request_capture("deliver_response", {
            "sessionID": SESSION, "requestID": request_id,
            "response": {"askUserQuestion": {"answers": answers}},
        }, "send_keys")
        self.assertEqual(resp["result"], {})
        return keys

    @staticmethod
    def real_keys(captured):
        """The emitted keys with pacing/explicit delays stripped."""
        return [k for k in captured[0]["keys"] if "delay" not in k]

    def q(self, n_options, multi=False, question="Which?", recommended=None):
        opts = [{"label": "opt %d" % j, "description": "d%d" % j} for j in range(n_options)]
        out = {"id": "x", "question": question, "options": opts, "multi": multi}
        if recommended is not None:
            out["recommended"] = recommended
        return out

    def test_ask_started_opens_replies_form(self):
        r = self.start_ask([{
            "id": "pick", "question": "Which approach?", "header": "Approach",
            "multi": False, "recommended": 1,
            "options": [
                {"label": "Rewrite", "description": "from scratch", "preview": "code"},
                {"label": "Patch"},
            ],
        }])
        awaiting = r["state"]["awaitingReplies"]
        self.assertEqual(awaiting["requestID"], "ask-1")
        qs = awaiting["_0"]["questions"]
        self.assertEqual(len(qs), 1)
        self.assertEqual(qs[0]["id"], "q0")
        self.assertEqual(qs[0]["question"], "Which approach?")
        self.assertEqual(qs[0]["header"], "Approach")
        self.assertFalse(qs[0]["multiSelect"])
        self.assertTrue(qs[0]["allowsFreeText"])
        self.assertEqual(qs[0]["options"][0]["id"], "q0-o0")
        self.assertEqual(qs[0]["options"][0]["label"], "Rewrite")
        self.assertEqual(qs[0]["options"][0]["preview"], "code")
        self.assertEqual(qs[0]["options"][1]["description"], "")
        self.assertEqual(r["notification"]["title"], "omp")
        self.assertIn("Which approach?", r["notification"]["body"])

    def test_ask_header_falls_back_to_numbered_chip(self):
        r = self.start_ask([self.q(2), self.q(2)])
        qs = r["state"]["awaitingReplies"]["_0"]["questions"]
        self.assertEqual([x["header"] for x in qs], ["Question 1", "Question 2"])

    def test_ask_started_without_questions_is_ignored(self):
        self.assertIsNone(self.evt("ask_started", {"toolCallId": "ask-1", "questions": []}))

    def test_ask_ended_returns_to_working(self):
        self.start_ask([self.q(2)])
        r = self.evt("ask_ended", {"toolCallId": "ask-1"})
        self.assertEqual(r["state"], {"working": {}})

    def test_single_select_answer_keys(self):
        # 3 options → 4 rows with Other. Lone single-select question has no
        # Submit tab: normalize Up×4, Down to row 1, Enter picks + submits.
        self.start_ask([self.q(3)])
        keys = self.deliver([{"questionID": "q0", "selectedOptionIDs": ["q0-o1"], "freeText": None}])
        self.assertEqual(self.real_keys(keys), [
            {"up": {}}, {"up": {}}, {"up": {}}, {"up": {}},
            {"down": {}}, {"enter": {}},
        ])

    def test_single_free_text_keys(self):
        # Free text → navigate to the Other row (index 3 of 4), Enter opens the
        # prompt editor, type + Enter accepts (and auto-advances/submits).
        self.start_ask([self.q(3)])
        keys = self.deliver([{"questionID": "q0", "selectedOptionIDs": [], "freeText": "my own"}])
        self.assertEqual(self.real_keys(keys), [
            {"up": {}}, {"up": {}}, {"up": {}}, {"up": {}},
            {"down": {}}, {"down": {}}, {"down": {}},
            {"enter": {}}, {"text": {"_0": "my own"}}, {"enter": {}},
        ])

    def test_multi_select_keys(self):
        # A multi question forces the Submit tab even when it's the only
        # question: Space toggles each pick, Right advances, Enter submits.
        self.start_ask([self.q(3, multi=True)])
        keys = self.deliver([{"questionID": "q0", "selectedOptionIDs": ["q0-o0", "q0-o2"], "freeText": None}])
        self.assertEqual(self.real_keys(keys), [
            {"up": {}}, {"up": {}}, {"up": {}}, {"up": {}},
            {"space": {}},
            {"down": {}}, {"down": {}}, {"space": {}},
            {"right": {}}, {"enter": {}},
        ])

    def test_two_questions_keys(self):
        # q0 single-select auto-advances to q1's tab; q1 multi needs an explicit
        # Right onto the Submit tab; final Enter submits.
        self.start_ask([self.q(2), self.q(2, multi=True)])
        keys = self.deliver([
            {"questionID": "q0", "selectedOptionIDs": ["q0-o1"], "freeText": None},
            {"questionID": "q1", "selectedOptionIDs": ["q1-o0"], "freeText": None},
        ])
        self.assertEqual(self.real_keys(keys), [
            {"up": {}}, {"up": {}}, {"up": {}},
            {"down": {}}, {"enter": {}},
            {"up": {}}, {"up": {}}, {"up": {}},
            {"space": {}},
            {"right": {}}, {"enter": {}},
        ])

    def test_answer_after_ask_ended_sends_no_keys(self):
        self.start_ask([self.q(2)])
        self.evt("ask_ended", {"toolCallId": "ask-1"})
        keys = self.deliver([{"questionID": "q0", "selectedOptionIDs": ["q0-o0"], "freeText": None}])
        self.assertEqual(keys, [])


class LaunchAndSettingsTests(unittest.TestCase):
    def setUp(self):
        self.sc = Sidecar()
        self.sc.request("initialize", {})

    def tearDown(self):
        self.sc.close()

    def test_default_launch_command(self):
        r = self.sc.request("command_for_launch", {"projectPath": "/tmp"})
        self.assertEqual(r["result"], {"command": "omp", "args": [], "env": {}})

    def test_command_path_override(self):
        self.sc.request("apply_settings", {"settings": {"command_path": "/opt/omp/bin/omp"}})
        r = self.sc.request("command_for_launch", {"projectPath": "/tmp"})
        self.assertEqual(r["result"]["command"], "/opt/omp/bin/omp")

    def test_auto_run_off_suppresses_launch(self):
        self.sc.request("apply_settings", {"settings": {"auto_run": False}})
        r = self.sc.request("command_for_launch", {"projectPath": "/tmp"})
        self.assertIsNone(r["result"])


class InstallTests(unittest.TestCase):
    """install/uninstall/install_status against a scratch HOME."""

    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="omp-sidecar-test-")
        self.sc = Sidecar(env={
            "HOME": self.home,
            "GALLAGER_INGRESS_SOCK": "/tmp/test-ingress.sock",
            "GALLAGER_PLUGIN_ID": "omp",
            "GALLAGER_PLUGIN_ROOT": ROOT,
        })
        self.sc.request("initialize", {"otlpReceiverEndpoint": "http://127.0.0.1:9999"})

    def tearDown(self):
        self.sc.close()
        import shutil
        shutil.rmtree(self.home, ignore_errors=True)

    def bridge_path(self):
        return os.path.join(self.home, ".omp", "agent", "extensions", "gallager.ts")

    def test_install_bakes_tokens_and_status_roundtrip(self):
        r = self.sc.request("install_status", {"configRoot": None})
        self.assertEqual(r["result"], {"notInstalled": {}})

        r = self.sc.request("install", {"configRoot": None})
        self.assertIn("installed", r["result"])

        with open(self.bridge_path(), "r", encoding="utf-8") as f:
            content = f.read()
        self.assertIn('"/tmp/test-ingress.sock"', content)
        self.assertIn('"http://127.0.0.1:9999"', content)
        self.assertNotIn("__GALLAGER_INGRESS_SOCK__", content)
        self.assertNotIn("__GALLAGER_PLUGIN_ID__", content)
        self.assertNotIn("__GALLAGER_OTLP_ENDPOINT__", content)
        self.assertIn("GallagerOmpBridge", content)

        r = self.sc.request("install_status", {"configRoot": None})
        self.assertEqual(r["result"], {"installed": {"version": "0.1.0"}})

        r = self.sc.request("uninstall", {"configRoot": None})
        self.assertEqual(r["result"], {})
        self.assertFalse(os.path.exists(self.bridge_path()))
        r = self.sc.request("install_status", {"configRoot": None})
        self.assertEqual(r["result"], {"notInstalled": {}})

    def test_per_project_install_targets_local_omp_dir(self):
        project = os.path.join(self.home, "proj")
        os.makedirs(project)
        r = self.sc.request("install", {"configRoot": project})
        self.assertIn("installed", r["result"])
        local = os.path.join(project, ".omp", "extensions", "gallager.ts")
        self.assertTrue(os.path.exists(local))
        r = self.sc.request("install_status", {"configRoot": project})
        self.assertEqual(r["result"], {"installed": {"version": "0.1.0"}})
        # The global row is unaffected.
        r = self.sc.request("install_status", {"configRoot": None})
        self.assertEqual(r["result"], {"notInstalled": {}})

    def test_uninstall_missing_bridge_is_fine(self):
        r = self.sc.request("uninstall", {"configRoot": None})
        self.assertEqual(r["result"], {})

    def test_install_json_escapes_special_chars_in_socket_path(self):
        # A socket path holding a quote/backslash must be JSON-escaped into the
        # TS string literal, not spliced raw (which would break out of the string
        # and make omp fail to load the extension).
        home = tempfile.mkdtemp(prefix="omp-sidecar-test-")
        nasty = '/tmp/a"b\\c'
        sc = Sidecar(env={
            "HOME": home,
            "GALLAGER_INGRESS_SOCK": nasty,
            "GALLAGER_PLUGIN_ID": "omp",
            "GALLAGER_PLUGIN_ROOT": ROOT,
        })
        try:
            sc.request("initialize", {})
            self.assertIn("installed", sc.request("install", {"configRoot": None})["result"])
            bridge = os.path.join(home, ".omp", "agent", "extensions", "gallager.ts")
            with open(bridge, "r", encoding="utf-8") as f:
                content = f.read()
            # The RAW_SOCK assignment is a single balanced, escaped string literal.
            self.assertIn("const RAW_SOCK = %s" % json.dumps(nasty), content)
        finally:
            sc.close()
            import shutil
            shutil.rmtree(home, ignore_errors=True)


class ProjectScanTests(unittest.TestCase):
    """refresh_projects reads session headers from omp's session store."""

    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="omp-sidecar-test-")
        self.sessions = os.path.join(self.home, ".omp", "agent", "sessions")
        os.makedirs(self.sessions)
        self.sc = Sidecar(env={"HOME": self.home})
        self.sc.request("initialize", {})
        # initialize pushes a set_projects seed AFTER its response — drain it so
        # it doesn't leak into the next request's capture window.
        frame = self.sc._read_frame()
        assert frame.get("method") == "set_projects", frame

    def tearDown(self):
        self.sc.close()
        import shutil
        shutil.rmtree(self.home, ignore_errors=True)

    def add_session(self, dirname, cwd, session_id="s", mtime=None, header_type="session",
                    title_line=True):
        d = os.path.join(self.sessions, dirname)
        os.makedirs(d, exist_ok=True)
        path = os.path.join(d, "2026-01-01T00-00-00-000Z_%s.jsonl" % session_id)
        with open(path, "w", encoding="utf-8") as f:
            # omp writes a rewritable title record BEFORE the session header.
            if title_line:
                f.write(json.dumps({"type": "title", "v": 1, "title": "t", "pad": " "}) + "\n")
            f.write(json.dumps({"type": header_type, "version": 3, "id": session_id, "cwd": cwd}) + "\n")
        if mtime is not None:
            os.utime(path, (mtime, mtime))
        return path

    def refresh(self):
        resp, captured = self.sc.request_capture("refresh_projects", None, "set_projects")
        self.assertEqual(resp["result"], {})
        self.assertEqual(len(captured), 1)
        return captured[0]["projects"]

    def test_projects_come_from_session_headers(self):
        proj_dir = os.path.join(self.home, "code", "AcmeApp")
        os.makedirs(proj_dir)
        then = time.time() - 5000
        self.add_session("-code-AcmeApp", proj_dir, "a1", mtime=then)
        projects = self.refresh()
        self.assertEqual(len(projects), 1)
        self.assertEqual(projects[0]["name"], "AcmeApp")
        self.assertEqual(projects[0]["path"], proj_dir)
        self.assertEqual(projects[0]["pluginID"], "omp")
        self.assertAlmostEqual(projects[0]["lastUsed"], then - EPOCH_2001, delta=2)

    def test_header_on_first_line_also_works(self):
        # Defensive: if omp ever drops the leading title record, the header scan
        # still finds a first-line header.
        proj_dir = os.path.join(self.home, "firstline")
        os.makedirs(proj_dir)
        self.add_session("-firstline", proj_dir, "f1", title_line=False)
        self.assertEqual([p["path"] for p in self.refresh()], [proj_dir])

    def test_artifact_subdirs_are_ignored(self):
        # Each session has a sibling artifact directory (e.g. __advisor.jsonl
        # inside) — the scan must only read .jsonl files directly in the project
        # dir, not recurse into per-session artifact dirs.
        proj_dir = os.path.join(self.home, "arty")
        os.makedirs(proj_dir)
        self.add_session("-arty", proj_dir, "a1")
        artifact_dir = os.path.join(self.sessions, "-arty", "2026-01-01T00-00-00-000Z_a1")
        os.makedirs(artifact_dir)
        with open(os.path.join(artifact_dir, "__advisor.jsonl"), "w") as f:
            f.write(json.dumps({"type": "session", "cwd": os.path.join(self.home, "bogus")}) + "\n")
        self.assertEqual([p["path"] for p in self.refresh()], [proj_dir])

    def test_newest_session_wins_per_directory(self):
        proj_dir = os.path.join(self.home, "proj")
        os.makedirs(proj_dir)
        gone = os.path.join(self.home, "gone")  # never created on disk
        now = time.time()
        self.add_session("-d", gone, "old", mtime=now - 100)
        self.add_session("-d", proj_dir, "new", mtime=now)
        projects = self.refresh()
        self.assertEqual([p["path"] for p in projects], [proj_dir])

    def test_missing_cwd_dir_is_skipped(self):
        self.add_session("-x", os.path.join(self.home, "deleted-project"), "x1")
        self.assertEqual(self.refresh(), [])

    def test_non_session_header_is_skipped(self):
        proj_dir = os.path.join(self.home, "p2")
        os.makedirs(proj_dir)
        self.add_session("-y", proj_dir, "y1", header_type="other")
        self.assertEqual(self.refresh(), [])

    def test_duplicate_cwd_keeps_most_recent(self):
        proj_dir = os.path.join(self.home, "dup")
        os.makedirs(proj_dir)
        now = time.time()
        self.add_session("-dup-a", proj_dir, "a", mtime=now - 500)
        self.add_session("-dup-b", proj_dir, "b", mtime=now)
        projects = self.refresh()
        self.assertEqual(len(projects), 1)
        self.assertAlmostEqual(projects[0]["lastUsed"], now - EPOCH_2001, delta=2)

    def test_empty_store_yields_no_projects(self):
        self.assertEqual(self.refresh(), [])

    def test_initialize_seeds_projects(self):
        proj_dir = os.path.join(self.home, "seeded")
        os.makedirs(proj_dir)
        self.add_session("-seed", proj_dir, "s1")
        sc = Sidecar(env={"HOME": self.home})
        resp, captured = sc.request_capture("initialize", {}, "set_projects")
        # initialize responds first, then pushes set_projects — read one more frame.
        if not captured:
            frame = sc._read_frame()
            self.assertEqual(frame.get("method"), "set_projects")
            captured = [frame.get("params")]
        self.assertEqual([p["path"] for p in captured[0]["projects"]], [proj_dir])
        sc.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
