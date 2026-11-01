"""Exercise the CLI boundary without requiring a Docker daemon."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
LOAD_KEYS = (
    "LOAD_SMOKE_PARALLEL", "LOAD_SMOKE_REPEAT",
    "LOAD_SMOKE_TIMEOUT", "LOAD_SMOKE_FIND_REPS",
)


class PacsCliTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        shutil.copy(ROOT / "pacs.sh", self.path)
        (self.path / "docker").write_text("""#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]
with open(os.environ['DOCKER_CALLS'], 'a') as f:
    f.write(json.dumps(a) + '\\n')
if a[:3] == ['compose', 'ps', '-q']:
    print('container-' + a[3])
elif a and a[0] == 'inspect':
    print('healthy' if 'Health' in a[1] else 'running')
""")
        (self.path / "docker").chmod(0o755)
        self.env = {k: v for k, v in os.environ.items() if k not in LOAD_KEYS}
        self.env.update(PATH=str(self.path) + os.pathsep + os.environ['PATH'],
                        DOCKER_CALLS=str(self.path / "calls.jsonl"))

    def run_cli(self, suite="load-smoke", settings=None, args=()):
        self.env.update(settings or {})
        proc = subprocess.run(["bash", str(self.path / "pacs.sh"), "test", suite, *args],
                              env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        calls = [json.loads(line) for line in (self.path / "calls.jsonl").read_text().splitlines()]
        return next(c for c in reversed(calls) if c[:2] == ["compose", "exec"])

    def test_unset_variables_do_not_override_container_defaults(self):
        self.assertEqual(self.run_cli(), ["compose", "exec", "-T", "test-client",
                                         "bash", "/tests/test-load-smoke.sh"])

    def test_all_four_settings_and_script_arguments_are_forwarded(self):
        values = dict(zip(LOAD_KEYS, ("4", "3", "17", "7")))
        call = self.run_cli(settings=values, args=("--verbose",))
        expected = ["compose", "exec", "-T"]
        for key in LOAD_KEYS:
            expected += ["-e", key + "=" + values[key]]
        self.assertEqual(call, expected + ["test-client", "bash", "/tests/test-load-smoke.sh", "--verbose"])

    def test_aggregate_suite_receives_settings_too(self):
        call = self.run_cli("all", {"LOAD_SMOKE_PARALLEL": "3"})
        self.assertEqual(call, ["compose", "exec", "-T", "-e", "LOAD_SMOKE_PARALLEL=3",
                                "test-client", "bash", "/tests/test-all.sh"])

    def test_values_are_literal_and_unrelated_variables_are_not_forwarded(self):
        value = '4 $(touch INJECTED); spaces *'
        call = self.run_cli(settings={"LOAD_SMOKE_PARALLEL": value,
                                      "LOAD_SMOKE_TIMEOUT": "",
                                      "LOAD_SMOKE_UNKNOWN": "ignore"})
        self.assertEqual(call, ["compose", "exec", "-T", "-e", "LOAD_SMOKE_PARALLEL=" + value,
                                "-e", "LOAD_SMOKE_TIMEOUT=", "test-client", "bash",
                                "/tests/test-load-smoke.sh"])
        self.assertFalse((self.path / "INJECTED").exists())


if __name__ == "__main__":
    unittest.main()
