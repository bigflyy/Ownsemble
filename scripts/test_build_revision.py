"""Verify automatic public build labels without reading application runtime data."""
from pathlib import Path
import shutil
import os
import subprocess
import tempfile
import unittest

# Run the helper through Git Bash on Windows and the ordinary shell on Linux.
BASH = shutil.which("bash")
# Locate only the public source helper next to this generated test.
HELPER = Path(__file__).resolve().parent / "build-revision.sh"


class BuildRevisionTest(unittest.TestCase):
    """Exercise labels in isolated generated repositories with no remotes or secrets."""

    def setUp(self):
        """Create a generated repository whose tracked source is entirely synthetic."""
        # Reject the Windows legacy alias before any child process can start WSL.
        if not BASH or (os.name == 'nt' and
                        Path(BASH).resolve().parent == Path(os.environ['SystemRoot'], 'System32').resolve()):
            self.skipTest('An explicit Git Bash executable is required on Windows.')
        # Keep all test writes and commits outside the real checkout.
        self.temporary = tempfile.TemporaryDirectory(prefix="ownsemble-build-label-")
        # Resolve the generated target before creating or removing any fixture files.
        self.root = Path(self.temporary.name).resolve()
        (self.root / "app/lib").mkdir(parents=True)
        (self.root / "app/lib/generated.dart").write_text("// Generated fixture\n")
        self.git("init", "-q")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("add", "app/lib/generated.dart")
        self.git("commit", "-qm", "Create generated fixture")

    def tearDown(self):
        """Remove only the exact temporary directory allocated by this fixture."""
        self.temporary.cleanup()

    def git(self, *arguments):
        """Run Git only inside the generated repository without any remote operations."""
        return subprocess.check_output(["git", "-C", str(self.root), *arguments], text=True).strip()

    def label(self):
        """Read the helper's single safe revision label."""
        return subprocess.check_output([BASH, str(HELPER), str(self.root)], text=True).strip()

    def test_clean_and_modified_source_labels(self):
        """Distinguish a known commit from a source tree with unpublished edits."""
        # Resolve the expected label from this generated repository only.
        revision = self.git("rev-parse", "--short=12", "HEAD")
        self.assertEqual(self.label(), revision)
        (self.root / "app/lib/generated.dart").write_text("// Changed generated fixture\n")
        self.assertEqual(self.label(), revision + "-dirty")

    def test_untracked_source_is_dirty_but_runtime_files_are_ignored(self):
        """Include new public source while avoiding any runtime/profile inspection."""
        # Keep local runtime contents outside the helper's explicit Git path scope.
        revision = self.git("rev-parse", "--short=12", "HEAD")
        (self.root / ".local").mkdir()
        (self.root / ".local/generated-runtime.txt").write_text("Synthetic ignored runtime value")
        self.assertEqual(self.label(), revision)
        (self.root / "app/lib/new.dart").write_text("// New generated source\n")
        self.assertEqual(self.label(), revision + "-dirty")


if __name__ == "__main__":
    unittest.main()
