#!/usr/bin/env python3
"""
Standalone tests for the pi Gallager sidecar.

Drives `bin/sidecar` as a real subprocess over its stdio JSON-RPC transport and
asserts the `translate_event` mapping (working / idle / doneWorking / sessionEnded),
the install/uninstall round-trip (dropping the pi extension), and the project scan
(reading real cwds out of pi's session JSONL headers). Zero third-party deps.

Run:  python3 tests/test_sidecar.py        (from the plugin root)
"""
import json
import os
import queue
import subprocess
import sys
import tempfile
import threading
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SIDECAR = os.path.join(ROOT, "bin", "sidecar")


# --- Sidecar RPC client -------------------------------------------------------
# A background reader thread drains every frame into a queue, so notifications
# (which the sidecar may emit either before OR after a request's response — e.g.
# initialize responds {} then pushes set_projects) are never lost to ordering.
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
        self._frames = queue.Queue()
        self._reader = threading.Thread(target=self._read_loop, daemon=True)
        self._reader.start()

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

    def _read_loop(self):
        while True:
            try:
                frame = self._read_frame()
            except Exception:
                frame = None
            self._frames.put(frame)
            if frame is None:
                return  # EOF

    def request(self, method, params=None, timeout=5):
        """Send a request; return the matching response frame. Notifications seen
        along the way are re-queued so wait_notifications() can drain them."""
        self._id += 1
        rid = "req-%d" % self._id
        self._write({"id": rid, "method": method, "params": params})
        while True:
            frame = self._frames.get(timeout=timeout)
            if frame is None:
                raise RuntimeError("sidecar closed stdout while awaiting %s" % method)
            if frame.get("id") == rid:
                return frame
            # a notification that arrived before the response — keep it available
            self._frames.put(frame)

    def wait_notifications(self, method, timeout=1.0):
        """Drain and return the params of every queued notification with `method`."""
        out = []
        leftover = []
        try:
            while True:
                frame = self._frames.get(timeout=timeout)
                if frame is None:
                    break
                if frame.get("method") == method:
                    out.append(frame.get("params"))
                elif frame.get("id") is None:
                    leftover.append(frame)  # a different notification
                else:
                    leftover.append(frame)
                # only wait the full timeout for the first frame; then drain fast
                timeout = 0.15
        except queue.Empty:
            pass
        for frame in leftover:
            self._frames.put(frame)
        return out

    def request_collect(self, method, params=None, collect_method=None):
        """Send a request; return (response_result, [params of collect_method notifications])."""
        result = self.request(method, params).get("result")
        notes = self.wait_notifications(collect_method) if collect_method else []
        return result, notes

    def translate(self, payload, context, plugin_id="pi"):
        resp = self.request("translate_event", {
            "pluginID": plugin_id,
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
SID = "019f362c-60f9-7a52-9b05-33d0862b4d29"
CTX = {"TMUX_PANE": PANE, "PI_PROJECT_DIR": "/Users/test/AcmeApp"}


class TranslateEventTests(unittest.TestCase):
    def setUp(self):
        self.sc = Sidecar()
        self.assertEqual(self.sc.request("initialize", {"appVersion": "9.9"}).get("result"), {})

    def tearDown(self):
        self.sc.close()

    def evt(self, etype, properties, ctx=None):
        return self.sc.translate({"type": etype, "properties": properties}, CTX if ctx is None else ctx)

    def test_session_start_is_idle_and_appears(self):
        r = self.evt("pi.session.start", {"sessionID": SID, "reason": "startup"})
        self.assertEqual(r["state"], {"idle": {}})
        self.assertEqual(r["sessionID"], SID)
        self.assertEqual(r["tmuxPane"], PANE)
        self.assertEqual(r["projectPath"], "/Users/test/AcmeApp")
        # appActions is non-optional in the host's PluginEvent — omitting it makes
        # the host drop the whole event. Must always be present.
        self.assertEqual(r["appActions"], [])
        self.assertIsNone(r["notification"])

    def test_agent_start_is_working(self):
        r = self.evt("pi.agent.start", {"sessionID": SID})
        self.assertEqual(r["state"], {"working": {}})
        self.assertEqual(r["appActions"], [])

    def test_agent_end_is_done_with_summary_and_notification(self):
        r = self.evt("pi.agent.end", {"sessionID": SID, "summary": "Fixed the bug."})
        self.assertEqual(r["state"], {"doneWorking": {"summary": "Fixed the bug."}})
        self.assertEqual(r["notification"], {"title": "pi", "body": "Fixed the bug."})
        self.assertEqual(r["appActions"], [])

    def test_agent_end_without_summary_falls_back_to_project(self):
        r = self.evt("pi.agent.end", {"sessionID": SID})
        self.assertEqual(r["state"], {"doneWorking": {"summary": None}})
        self.assertEqual(r["notification"]["body"], "Finished — AcmeApp")

    def test_agent_end_without_project_uses_generic_body(self):
        r = self.evt("pi.agent.end", {"sessionID": SID}, ctx={"TMUX_PANE": PANE})
        self.assertEqual(r["notification"]["body"], "Ready for input")

    def test_session_quit_ends_session_keyed_by_pane(self):
        r = self.evt("pi.session.shutdown", {"sessionID": SID, "reason": "quit"})
        self.assertIsNone(r["state"])
        self.assertEqual(
            r["appActions"],
            [{"sessionEnded": {"sessionID": PANE, "closePaneEligible": False}}],
        )

    def test_session_reload_does_not_end_session(self):
        # /reload tears down + re-creates the runtime; the following session.start
        # re-announces the session. Ending here would flicker the sidebar row.
        r = self.evt("pi.session.shutdown", {"sessionID": SID, "reason": "reload"})
        self.assertIsNone(r)  # nothing interesting → ignored

    def test_session_switch_does_not_end_session(self):
        for reason in ("new", "resume", "fork"):
            r = self.evt("pi.session.shutdown", {"sessionID": SID, "reason": reason})
            self.assertIsNone(r, "reason %s should not end the session" % reason)

    def test_close_pane_setting_flows_into_session_end(self):
        self.assertEqual(
            self.sc.request("apply_settings", {"settings": {"close_pane_on_session_end": True}}).get("result"),
            {"applied": {}},
        )
        r = self.evt("pi.session.shutdown", {"sessionID": SID, "reason": "quit"})
        self.assertEqual(
            r["appActions"],
            [{"sessionEnded": {"sessionID": PANE, "closePaneEligible": True}}],
        )

    def test_missing_session_id_falls_back_to_pane(self):
        r = self.evt("pi.agent.start", {})
        self.assertEqual(r["sessionID"], PANE)

    def test_unknown_event_is_ignored(self):
        self.assertIsNone(self.evt("pi.something.else", {"sessionID": SID}))

    def test_no_pane_still_maps_state(self):
        # translate_event doesn't require a pane (the extension's forward() gates
        # on TMUX_PANE upstream); the sidecar just maps whatever it gets.
        r = self.evt("pi.agent.start", {"sessionID": SID}, ctx={})
        self.assertEqual(r["state"], {"working": {}})
        self.assertIsNone(r["tmuxPane"])


class LaunchAndSettingsTests(unittest.TestCase):
    def setUp(self):
        self.sc = Sidecar()
        self.sc.request("initialize", {"appVersion": "9.9"})

    def tearDown(self):
        self.sc.close()

    def test_command_for_launch_default(self):
        r = self.sc.request("command_for_launch", {}).get("result")
        self.assertEqual(r, {"command": "pi", "args": [], "env": {}})

    def test_command_for_launch_honors_command_path(self):
        self.sc.request("apply_settings", {"settings": {"command_path": "/opt/bin/pi"}})
        r = self.sc.request("command_for_launch", {}).get("result")
        self.assertEqual(r["command"], "/opt/bin/pi")

    def test_command_for_launch_auto_run_off(self):
        self.sc.request("apply_settings", {"settings": {"auto_run": False}})
        self.assertIsNone(self.sc.request("command_for_launch", {}).get("result"))

    def test_unknown_method_is_method_not_found(self):
        resp = self.sc.request("bogus_method", {})
        self.assertEqual(resp["error"]["code"], "method_not_found")


class InstallTests(unittest.TestCase):
    """Install/uninstall the pi extension into a temp PI_CODING_AGENT_DIR."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.sock = "/tmp/gallager-test.sock"
        self.sc = Sidecar(env={
            "PI_CODING_AGENT_DIR": self.tmp,
            "GALLAGER_INGRESS_SOCK": self.sock,
            "GALLAGER_PLUGIN_ID": "pi",
            "GALLAGER_PLUGIN_ROOT": ROOT,
        })
        self.sc.request("initialize", {"appVersion": "9.9", "otlpReceiverEndpoint": "http://127.0.0.1:24318"})
        self.dest = os.path.join(self.tmp, "extensions", "gallager.ts")

    def tearDown(self):
        self.sc.close()
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_install_status_starts_not_installed(self):
        r = self.sc.request("install_status", {"configRoot": None}).get("result")
        self.assertEqual(r, {"notInstalled": {}})

    def test_install_writes_extension_with_substituted_tokens(self):
        r = self.sc.request("install", {"configRoot": None}).get("result")
        self.assertIn("installed", r)
        self.assertTrue(os.path.exists(self.dest))
        content = open(self.dest, encoding="utf-8").read()
        self.assertIn("GallagerPiMonitor", content)          # marker survives
        self.assertNotIn("__GALLAGER_INGRESS_SOCK__", content)  # tokens substituted
        self.assertIn(self.sock, content)
        self.assertIn("http://127.0.0.1:24318", content)     # OTLP endpoint baked in

    def test_install_status_reports_installed_after_install(self):
        self.sc.request("install", {"configRoot": None})
        r = self.sc.request("install_status", {"configRoot": None}).get("result")
        self.assertEqual(r, {"installed": {"version": "0.1.0"}})

    def test_uninstall_removes_extension(self):
        self.sc.request("install", {"configRoot": None})
        self.assertTrue(os.path.exists(self.dest))
        self.sc.request("uninstall", {"configRoot": None})
        self.assertFalse(os.path.exists(self.dest))
        r = self.sc.request("install_status", {"configRoot": None}).get("result")
        self.assertEqual(r, {"notInstalled": {}})

    def test_install_project_local_config_root(self):
        proj = tempfile.mkdtemp()
        try:
            self.sc.request("install", {"configRoot": proj})
            local = os.path.join(proj, ".pi", "extensions", "gallager.ts")
            self.assertTrue(os.path.exists(local))
        finally:
            import shutil
            shutil.rmtree(proj, ignore_errors=True)


class ProjectScanTests(unittest.TestCase):
    """The project scan reads real cwds from pi session JSONL headers."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        # A real project dir the header points at (scan skips non-existent cwds).
        self.projdir = os.path.join(self.tmp, "code", "AcmeApp")
        os.makedirs(self.projdir)
        sessions = os.path.join(self.tmp, "sessions", "--Users-slug--")
        os.makedirs(sessions)
        header = {"type": "session", "version": 3, "id": SID, "cwd": self.projdir}
        with open(os.path.join(sessions, "2026-07-06T06-45-05Z_%s.jsonl" % SID), "w", encoding="utf-8") as f:
            f.write(json.dumps(header) + "\n")
            f.write(json.dumps({"type": "message", "message": {"role": "user"}}) + "\n")
        self.sc = Sidecar(env={"PI_CODING_AGENT_DIR": self.tmp})

    def tearDown(self):
        self.sc.close()
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_initialize_emits_projects_from_session_header_cwd(self):
        # initialize responds {} then pushes a set_projects notification.
        result, notes = self.sc.request_collect(
            "initialize", {"appVersion": "9.9"}, collect_method="set_projects"
        )
        self.assertEqual(result, {})
        self.assertTrue(notes, "expected a set_projects notification")
        projects = notes[-1]["projects"]
        self.assertEqual(len(projects), 1)
        self.assertEqual(projects[0]["path"], self.projdir)
        self.assertEqual(projects[0]["name"], "AcmeApp")
        self.assertEqual(projects[0]["pluginID"], "pi")
        self.assertIn("lastUsed", projects[0])

    def test_refresh_projects_skips_nonexistent_cwd(self):
        self.sc.request("initialize", {"appVersion": "9.9"})
        # Point a second session dir at a cwd that no longer exists.
        gone = os.path.join(self.tmp, "sessions", "--gone--")
        os.makedirs(gone)
        with open(os.path.join(gone, "old_%s.jsonl" % SID, ), "w", encoding="utf-8") as f:
            f.write(json.dumps({"type": "session", "cwd": "/nope/does/not/exist"}) + "\n")
        _, notes = self.sc.request_collect("refresh_projects", None, collect_method="set_projects")
        paths = [p["path"] for p in notes[-1]["projects"]]
        self.assertIn(self.projdir, paths)
        self.assertNotIn("/nope/does/not/exist", paths)


if __name__ == "__main__":
    unittest.main(verbosity=2)
