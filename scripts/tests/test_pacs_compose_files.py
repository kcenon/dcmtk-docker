"""Commands that recreate services keep the compose files of the stack (#136).

pacs.sh passes no -f to docker compose. A fake docker records each call with
the COMPOSE_FILE and COMPOSE_PATH_SEPARATOR it received, so no daemon is needed.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
ADD_PEER = ("add-peer", "extra", "EXTRA_AE", "10.0.0.9", "104")

# FAKE_STACK maps container IDs to {"files": label, "running": bool}.
# "compose down" empties the stack, as a real down does before reset's up.
FAKE_DOCKER = r"""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
a = sys.argv[1:]
state = Path(os.environ["FAKE_STATE"])
with open(os.environ["DOCKER_CALLS"], "a") as f:
    f.write(json.dumps({"args": a,
                        "COMPOSE_FILE": os.environ.get("COMPOSE_FILE"),
                        "COMPOSE_PATH_SEPARATOR": os.environ.get("COMPOSE_PATH_SEPARATOR")}) + "\n")
stack = {} if (state / "down").exists() else json.loads(os.environ.get("FAKE_STACK", "{}"))
if a[:2] == ["compose", "down"]:
    (state / "down").touch()
elif a[:2] == ["compose", "ps"]:
    rest = a[2:]
    if rest == ["-a", "-q"]:
        print("\n".join(stack))
    elif rest == ["-q"]:
        print("\n".join(c for c, v in stack.items() if v["running"]))
    elif rest[:1] == ["-q"]:
        print("container-" + rest[1])
elif a and a[0] == "inspect":
    fmt = " ".join(a[1:-1])
    if "config_files" in fmt:
        print(stack[a[-1]]["files"])
    else:
        print("healthy" if "Health" in fmt else "running")
"""


class StackComposeFilesTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        shutil.copy(ROOT / "pacs.sh", self.path)
        fake = self.path / "docker"
        fake.write_text(FAKE_DOCKER)
        fake.chmod(0o755)
        state = self.path / "state"
        state.mkdir()
        # A space in the directory catches word splitting of the file list.
        stack_dir = self.path / "stack dir"
        stack_dir.mkdir()
        self.base = stack_dir / "docker-compose.yml"
        tls = stack_dir / "docker-compose.tls.yml"
        for path in (self.base, tls):
            path.write_text("services: {}\n")
        self.overlay = "{},{}".format(self.base, tls)
        self.env_file = self.path / ".env"
        self.env_file.write_text("EXTRA_PEERS=\n")
        self.env = {k: v for k, v in os.environ.items()
                    if k not in ("COMPOSE_FILE", "COMPOSE_PATH_SEPARATOR", "EXTRA_PEERS")}
        self.env.update(PATH=str(self.path) + os.pathsep + os.environ["PATH"],
                        DOCKER_CALLS=str(self.path / "calls.jsonl"),
                        FAKE_STATE=str(state))

    def stack(self, *containers):
        self.env["FAKE_STACK"] = json.dumps(
            {"c%d" % i: {"files": files, "running": running}
             for i, (files, running) in enumerate(containers)})

    def run_cli(self, *args):
        proc = subprocess.run(["bash", str(self.path / "pacs.sh"), *args], env=self.env,
                              capture_output=True, text=True, timeout=20)
        log = self.path / "calls.jsonl"
        calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        return proc, calls

    @staticmethod
    def compose(calls, command):
        return [c for c in calls if c["args"][:2] == ["compose", command]]

    def assert_stack_files(self, call):
        self.assertEqual((call["COMPOSE_FILE"], call["COMPOSE_PATH_SEPARATOR"]),
                         (self.overlay, ","), call["args"])

    def test_add_peer_recreates_the_pacs_from_the_stack_files(self):
        self.stack((self.overlay, True), (self.overlay, True))
        proc, calls = self.run_cli(*ADD_PEER)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        (up,) = self.compose(calls, "up")
        self.assertEqual(up["args"], ["compose", "up", "-d", "pacs-server", "pacs-server-2"])
        self.assert_stack_files(up)
        self.assertIn("EXTRA_PEERS=extra=EXTRA_AE:10.0.0.9:104\n", self.env_file.read_text())

    def test_up_uses_the_stack_files(self):
        self.stack((self.overlay, True))
        proc, calls = self.run_cli("up")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        (up,) = self.compose(calls, "up")
        self.assertEqual(up["args"], ["compose", "up", "-d", "--build"])
        self.assert_stack_files(up)

    def test_reset_removes_and_restarts_with_the_stack_files(self):
        self.stack((self.overlay, True))
        proc, calls = self.run_cli("reset")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        (down,) = self.compose(calls, "down")
        (up,) = self.compose(calls, "up")
        self.assertEqual(down["args"], ["compose", "down", "-v"])
        self.assertLess(calls.index(down), calls.index(up))
        self.assert_stack_files(down)
        self.assert_stack_files(up)

    def test_stopped_stack_counts_too(self):
        self.stack((self.overlay, False))
        proc, calls = self.run_cli("up")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assert_stack_files(self.compose(calls, "up")[0])

    def test_without_containers_compose_resolves_files_itself(self):
        for user_value in ("docker-compose.yml:docker-compose.tls.yml", None):
            with self.subTest(COMPOSE_FILE=user_value):
                (self.path / "calls.jsonl").unlink(missing_ok=True)
                self.env.pop("COMPOSE_FILE", None)
                if user_value is not None:
                    self.env["COMPOSE_FILE"] = user_value
                self.stack()
                proc, calls = self.run_cli("up")
                self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
                (up,) = self.compose(calls, "up")
                self.assertEqual((up["COMPOSE_FILE"], up["COMPOSE_PATH_SEPARATOR"]),
                                 (user_value, None))

    def test_stack_files_take_precedence_over_compose_file(self):
        self.env["COMPOSE_FILE"] = str(self.base)
        self.stack((self.overlay, True))
        proc, calls = self.run_cli("up")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assert_stack_files(self.compose(calls, "up")[0])

    def assert_add_peer_refused(self):
        before = self.env_file.read_bytes()
        proc, calls = self.run_cli(*ADD_PEER)
        self.assertNotEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(self.compose(calls, "up"), [])
        self.assertEqual(self.env_file.read_bytes(), before)
        self.assertIn("./pacs.sh down", proc.stderr)

    def test_refuses_containers_started_with_different_files(self):
        self.stack((self.overlay, True), (str(self.base), True))
        self.assert_add_peer_refused()

    def test_refuses_a_missing_compose_file(self):
        self.stack(("{},{}".format(self.base, self.path / "gone.yml"), True))
        self.assert_add_peer_refused()

    def test_refuses_a_container_without_the_label(self):
        self.stack(("", True))
        self.assert_add_peer_refused()


if __name__ == "__main__":
    unittest.main()
