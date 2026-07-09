#!/usr/bin/env python3
"""
Standalone tests for the pi Gallager sidecar.

Drives `bin/sidecar` as a real subprocess over its stdio JSON-RPC transport and
asserts the `translate_event` mapping (session lifecycle, working/done states),
the install/uninstall/install_status round-trip (placeholder substitution into
the pi bridge extension), project discovery from pi's session store, and the
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
            "pluginID": "pi",
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
SESSION = "019f3643-2895-7f0e-8298-b5843d4841e3"
CTX = {"TMUX_PANE": PANE, "PI_PROJECT_DIR": "/Users/test/AcmeApp"}


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
        r = self.evt("session_start", {"reason": "startup"})
        self.assertEqual(r["state"], {"idle": {}})
        self.assertEqual(r["sessionID"], SESSION)
        self.assertEqual(r["tmuxPane"], PANE)
        self.assertEqual(r["projectPath"], "/Users/test/AcmeApp")
        self.assertIsNone(r["notification"])
        # appActions is non-optional in the host's PluginEvent — omitting it makes
        # the host drop the whole event. Must always be present.
        self.assertEqual(r["appActions"], [])

    def test_session_start_on_resume_is_idle(self):
        r = self.evt("session_start", {"reason": "resume"})
        self.assertEqual(r["state"], {"idle": {}})

    def test_agent_start_is_working(self):
        r = self.evt("agent_start")
        self.assertEqual(r["state"], {"working": {}})
        self.assertEqual(r["appActions"], [])

    def test_agent_end_is_done_with_summary_and_notification(self):
        r = self.evt("agent_end", {"summary": "Fixed the bug.", "stopReason": "stop"})
        self.assertEqual(r["state"], {"doneWorking": {"summary": "Fixed the bug."}})
        self.assertEqual(r["notification"]["title"], "pi")
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
        self.assertEqual(r["state"], {"doneWorking": {"summary": "pi hit an error"}})

    def test_agent_end_aborted_is_interrupted(self):
        r = self.evt("agent_end", {"stopReason": "aborted"})
        self.assertEqual(r["state"], {"doneWorking": {"summary": "Interrupted"}})
        self.assertEqual(r["notification"]["body"], "Interrupted")

    def test_shutdown_quit_ends_session_keyed_by_pane(self):
        r = self.evt("session_shutdown", {"reason": "quit"})
        self.assertIsNone(r["state"])
        # sessionEnded is keyed by the PANE id (the host ends sessions by pane).
        self.assertEqual(r["appActions"], [
            {"sessionEnded": {"sessionID": PANE, "closePaneEligible": False}},
        ])

    def test_shutdown_for_session_replacement_is_ignored(self):
        # /new, /resume, /fork, /reload replace the session; a session_start
        # follows immediately. Ending here would flicker the sidebar row.
        for reason in ("new", "resume", "fork", "reload"):
            self.assertIsNone(self.evt("session_shutdown", {"reason": reason}))

    def test_shutdown_unknown_reason_still_ends_session(self):
        # Anything outside the finite replacement set is terminal — a signal path
        # a future pi might rename (SIGHUP → "hangup", say), or a missing reason,
        # still clears the sidebar row instead of stranding it.
        for reason in ("hangup", "terminated", None):
            r = self.evt("session_shutdown", {"reason": reason} if reason else {})
            self.assertIsNone(r["state"])
            self.assertEqual(r["appActions"], [
                {"sessionEnded": {"sessionID": PANE, "closePaneEligible": False}},
            ])

    def test_shutdown_quit_without_pane_is_ignored(self):
        r = self.evt("session_shutdown", {"reason": "quit"}, ctx={})
        self.assertIsNone(r)

    def test_close_pane_setting_honored_on_quit(self):
        self.sc.request("apply_settings", {"settings": {"close_pane_on_session_end": True}})
        r = self.evt("session_shutdown", {"reason": "quit"})
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


class LaunchAndSettingsTests(unittest.TestCase):
    def setUp(self):
        self.sc = Sidecar()
        self.sc.request("initialize", {})

    def tearDown(self):
        self.sc.close()

    def test_default_launch_command(self):
        r = self.sc.request("command_for_launch", {"projectPath": "/tmp"})
        self.assertEqual(r["result"], {"command": "pi", "args": [], "env": {}})

    def test_command_path_override(self):
        self.sc.request("apply_settings", {"settings": {"command_path": "/opt/pi/bin/pi"}})
        r = self.sc.request("command_for_launch", {"projectPath": "/tmp"})
        self.assertEqual(r["result"]["command"], "/opt/pi/bin/pi")

    def test_auto_run_off_suppresses_launch(self):
        self.sc.request("apply_settings", {"settings": {"auto_run": False}})
        r = self.sc.request("command_for_launch", {"projectPath": "/tmp"})
        self.assertIsNone(r["result"])

    def test_deliver_response_is_acknowledged(self):
        r = self.sc.request("deliver_response", {
            "sessionID": "s1", "requestID": "r1", "response": {"prompt": {"text": "hi"}},
        })
        self.assertEqual(r["result"], {})


class InstallTests(unittest.TestCase):
    """install/uninstall/install_status against a scratch HOME."""

    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="pi-sidecar-test-")
        self.sc = Sidecar(env={
            "HOME": self.home,
            "GALLAGER_INGRESS_SOCK": "/tmp/test-ingress.sock",
            "GALLAGER_PLUGIN_ID": "pi",
            "GALLAGER_PLUGIN_ROOT": ROOT,
        })
        self.sc.request("initialize", {"otlpReceiverEndpoint": "http://127.0.0.1:9999"})

    def tearDown(self):
        self.sc.close()
        import shutil
        shutil.rmtree(self.home, ignore_errors=True)

    def bridge_path(self):
        return os.path.join(self.home, ".pi", "agent", "extensions", "gallager.ts")

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
        self.assertIn("GallagerPiBridge", content)

        r = self.sc.request("install_status", {"configRoot": None})
        self.assertEqual(r["result"], {"installed": {"version": "0.1.0"}})

        r = self.sc.request("uninstall", {"configRoot": None})
        self.assertEqual(r["result"], {})
        self.assertFalse(os.path.exists(self.bridge_path()))
        r = self.sc.request("install_status", {"configRoot": None})
        self.assertEqual(r["result"], {"notInstalled": {}})

    def test_per_project_install_targets_local_pi_dir(self):
        project = os.path.join(self.home, "proj")
        os.makedirs(project)
        r = self.sc.request("install", {"configRoot": project})
        self.assertIn("installed", r["result"])
        local = os.path.join(project, ".pi", "extensions", "gallager.ts")
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
        # and make pi fail to load the extension).
        home = tempfile.mkdtemp(prefix="pi-sidecar-test-")
        nasty = '/tmp/a"b\\c'
        sc = Sidecar(env={
            "HOME": home,
            "GALLAGER_INGRESS_SOCK": nasty,
            "GALLAGER_PLUGIN_ID": "pi",
            "GALLAGER_PLUGIN_ROOT": ROOT,
        })
        try:
            sc.request("initialize", {})
            self.assertIn("installed", sc.request("install", {"configRoot": None})["result"])
            bridge = os.path.join(home, ".pi", "agent", "extensions", "gallager.ts")
            with open(bridge, "r", encoding="utf-8") as f:
                content = f.read()
            # The RAW_SOCK assignment is a single balanced, escaped string literal.
            self.assertIn("const RAW_SOCK = %s" % json.dumps(nasty), content)
        finally:
            sc.close()
            import shutil
            shutil.rmtree(home, ignore_errors=True)


class ProjectScanTests(unittest.TestCase):
    """refresh_projects reads session headers from pi's session store."""

    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="pi-sidecar-test-")
        self.sessions = os.path.join(self.home, ".pi", "agent", "sessions")
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

    def add_session(self, dirname, cwd, session_id="s", mtime=None, header_type="session"):
        d = os.path.join(self.sessions, dirname)
        os.makedirs(d, exist_ok=True)
        path = os.path.join(d, "2026-01-01T00-00-00-000Z_%s.jsonl" % session_id)
        with open(path, "w", encoding="utf-8") as f:
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
        self.add_session("--munged-acme--", proj_dir, "a1", mtime=then)
        projects = self.refresh()
        self.assertEqual(len(projects), 1)
        self.assertEqual(projects[0]["name"], "AcmeApp")
        self.assertEqual(projects[0]["path"], proj_dir)
        self.assertEqual(projects[0]["pluginID"], "pi")
        self.assertAlmostEqual(projects[0]["lastUsed"], then - EPOCH_2001, delta=2)

    def test_newest_session_wins_per_directory(self):
        proj_dir = os.path.join(self.home, "proj")
        os.makedirs(proj_dir)
        gone = os.path.join(self.home, "gone")  # never created on disk
        now = time.time()
        self.add_session("--d--", gone, "old", mtime=now - 100)
        self.add_session("--d--", proj_dir, "new", mtime=now)
        projects = self.refresh()
        self.assertEqual([p["path"] for p in projects], [proj_dir])

    def test_missing_cwd_dir_is_skipped(self):
        self.add_session("--x--", os.path.join(self.home, "deleted-project"), "x1")
        self.assertEqual(self.refresh(), [])

    def test_non_session_header_is_skipped(self):
        proj_dir = os.path.join(self.home, "p2")
        os.makedirs(proj_dir)
        self.add_session("--y--", proj_dir, "y1", header_type="other")
        self.assertEqual(self.refresh(), [])

    def test_duplicate_cwd_keeps_most_recent(self):
        proj_dir = os.path.join(self.home, "dup")
        os.makedirs(proj_dir)
        now = time.time()
        self.add_session("--dup-a--", proj_dir, "a", mtime=now - 500)
        self.add_session("--dup-b--", proj_dir, "b", mtime=now)
        projects = self.refresh()
        self.assertEqual(len(projects), 1)
        self.assertAlmostEqual(projects[0]["lastUsed"], now - EPOCH_2001, delta=2)

    def test_empty_store_yields_no_projects(self):
        self.assertEqual(self.refresh(), [])

    def test_initialize_seeds_projects(self):
        proj_dir = os.path.join(self.home, "seeded")
        os.makedirs(proj_dir)
        self.add_session("--seed--", proj_dir, "s1")
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
