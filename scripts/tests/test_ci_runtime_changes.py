import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "ci_runtime_changes.py"
spec = importlib.util.spec_from_file_location("changes", SCRIPT)
changes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(changes)


class RuntimeChangesTests(unittest.TestCase):
    def test_documentation_only(self):
        self.assertFalse(changes.needs_runtime(["README.md", "VERSION", "CHANGELOG.md", "docs/image.png"]))

    def test_runtime_workflow_mixed_and_unknown(self):
        for path in ["pacs.sh", "env.default", ".dockerignore", "patches/fix.patch",
                     "tests/test-store.sh", "docker-compose.new.yml", "config/peer.cfg",
                     ".github/workflows/test-isolation.yml", "scripts/README.md", "new-runtime-file"]:
            with self.subTest(path=path):
                self.assertTrue(changes.needs_runtime(["README.md", path]))

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.git("init", "-q")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "user.name", "CI test")
        self.base = self.commit("README.md", "initial")

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repo, stderr=subprocess.DEVNULL).decode().strip()

    def commit(self, path, content):
        file = self.repo / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(content)
        self.git("add", "-A")
        self.git("commit", "-qm", "fixture change")
        return self.git("rev-parse", "HEAD")

    def classify(self, base, head, event="pull_request"):
        return subprocess.run(["python3", str(SCRIPT), "--event", event, "--base", base, "--head", head],
                              cwd=self.repo, text=True, capture_output=True)

    def test_real_git_docs_then_runtime_changes(self):
        docs = self.commit("docs/a file\nwith newline.md", "docs")
        self.assertEqual(self.classify(self.base, docs).stdout, "runtime=false\n")
        runtime = self.commit("scripts/new.sh", "true")
        self.assertEqual(self.classify(self.base, runtime).stdout, "runtime=true\n")

    def test_pr_diff_excludes_changes_only_on_base_branch(self):
        docs = self.commit("README.md", "feature docs")
        self.git("checkout", "-q", "--detach", self.base)
        advanced_base = self.commit("Dockerfile", "base changed independently")
        self.assertEqual(self.classify(advanced_base, docs).stdout, "runtime=false\n")

    def test_rename_out_of_runtime_directory_still_runs_tests(self):
        before = self.commit("scripts/old.sh", "old")
        (self.repo / "scripts/old.sh").rename(self.repo / "example.md")
        self.git("add", "-A")
        self.git("commit", "-qm", "rename")
        self.assertEqual(self.classify(before, self.git("rev-parse", "HEAD")).stdout, "runtime=true\n")

    def test_new_push_ref_and_manual_run(self):
        self.assertEqual(self.classify("0" * 40, self.base, "push").stdout, "runtime=true\n")
        self.assertEqual(self.classify("", "", "workflow_dispatch").stdout, "runtime=true\n")

    def test_push_from_missing_base_runs_every_suite(self):
        # develop re-created from main: the old tip is in no fetched ref (#134).
        old_tip = self.commit("Dockerfile", "old tip")
        self.git("reset", "-q", "--hard", self.base)
        self.git("reflog", "expire", "--expire=now", "--all")
        self.git("gc", "-q", "--prune=now")
        self.assertNotEqual(subprocess.run(["git", "cat-file", "-e", old_tip + "^{commit}"],
                                           cwd=self.repo, capture_output=True).returncode, 0)
        recreated = self.commit("README.md", "re-created")  # docs only versus its parent
        tree = self.git("rev-parse", recreated + "^{tree}")
        self.assertEqual(self.classify(self.base, recreated, "push").stdout, "runtime=false\n")
        for base in [old_tip, "f" * 40, "f" * 64, tree]:
            with self.subTest(base=base):
                result = self.classify(base, recreated, "push")
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "runtime=true\n")
        result = self.classify(old_tip, recreated)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_invalid_or_missing_commits_fail_without_skip_output(self):
        cases = [(base, self.base, "pull_request") for base in ["", "not-a-sha", "f" * 40]]
        # A push tolerates only a missing base; malformed SHAs and a missing head still fail.
        cases += [(base, self.base, "push") for base in ["", "not-a-sha", self.base[:12]]]
        cases.append((self.base, "f" * 40, "push"))
        for base, head, event in cases:
            with self.subTest(base=base, head=head, event=event):
                result = self.classify(base, head, event)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
