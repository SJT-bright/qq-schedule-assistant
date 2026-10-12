import importlib.util
import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("cleanup_old_versions", Path(__file__).resolve().parents[1] / "Tools/cleanup-old-versions.py")
cleanup = importlib.util.module_from_spec(spec)
sys.dont_write_bytecode = True
spec.loader.exec_module(cleanup)


class OldVersionCleanupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="qq-old-version-cleanup-test-")
        self.root = (Path(self.temp.name) / "project").resolve()
        self.root.mkdir()
        self.trash = Path(self.temp.name) / "Trash"

    def tearDown(self):
        self.temp.cleanup()

    def app(self, name, build="109", identifier=cleanup.IDENTIFIER):
        path = self.root / name
        (path / "Contents/MacOS").mkdir(parents=True)
        (path / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": identifier,
            "CFBundleVersion": build, "CFBundleShortVersionString": "3.9.1", "CFBundleExecutable": "QQDispatch"}))
        (path / "Contents/MacOS/QQDispatch").write_bytes(b"isolated test executable")
        return path

    def test_old_and_same_build_backup_removed_fixed_slots_kept(self):
        dist = self.app("dist/QQ排程助手.app")
        running = self.app("build/running/QQ排程助手.app", "108")
        old = self.app("build/previous/QQ排程助手.app", "108")
        duplicate = self.app("build/same-build/QQ排程助手.app")
        candidates = cleanup.find_obsolete(self.root, 109, {dist, running})
        self.assertEqual({item["source"] for item in candidates}, {str(old), str(duplicate)})
        result = cleanup.move_to_trash(self.root, candidates, 109, {dist, running}, self.trash)
        self.assertEqual(result["count"], 2)
        self.assertTrue(dist.exists() and running.exists())
        self.assertFalse(old.exists() or duplicate.exists())
        self.assertEqual(json.loads((Path(result["trash"]) / "manifest.json").read_text())["count"], 2)
        self.assertTrue(all(Path(item["destination"]).exists() for item in result["moved"]))

    def test_foreign_future_and_unknown_versions_untouched(self):
        paths = [self.app("build/foreign.app", "108", "other.app"), self.app("build/future.app", "110"),
                 self.app("build/unknown.app", "broken")]
        malformed = self.app("build/malformed.app", "108")
        (malformed / "Contents/Info.plist").write_bytes(plistlib.dumps(["invalid bundle metadata"]))
        paths.append(malformed)
        self.assertEqual(cleanup.find_obsolete(self.root, 109, set()), [])
        self.assertTrue(all(path.exists() for path in paths))

    def test_data_backup_and_sources_preserved(self):
        old = self.app("build/data-backup/QQ排程助手.app", "108")
        library = old.parent / "library.sqlite3"; library.write_bytes(b"original data backup")
        asset = old.parent / "assets/original.png"; asset.parent.mkdir(); asset.write_bytes(b"original image")
        source = self.root / "Sources/App.swift"; source.parent.mkdir(); source.write_bytes(b"original source")
        result = cleanup.move_to_trash(self.root, cleanup.find_obsolete(self.root, 109, set()), 109, set(), self.trash)
        self.assertEqual(result["count"], 1)
        self.assertEqual([library.read_bytes(), asset.read_bytes(), source.read_bytes()],
                         [b"original data backup", b"original image", b"original source"])

    def test_symlinks_not_followed(self):
        external = Path(self.temp.name) / "external"; external.mkdir()
        (self.root / "alias").symlink_to(external, target_is_directory=True)
        old = self.app("real.app", "108")
        (self.root / "copy.app").symlink_to(old, target_is_directory=True)
        paths = cleanup.find_obsolete(self.root, 109, {old})
        self.assertEqual(paths, [])
        self.assertTrue((self.root / "copy.app").is_symlink())

    def test_changed_bundle_refuses_entire_batch(self):
        first = self.app("build/first.app", "108"); second = self.app("build/second.app", "108")
        candidates = cleanup.find_obsolete(self.root, 109, set())
        (second / "Contents/MacOS/QQDispatch").write_bytes(b"changed since checked")
        with self.assertRaises(RuntimeError):
            cleanup.move_to_trash(self.root, candidates, 109, set(), self.trash)
        self.assertTrue(first.exists() and second.exists())
        self.assertFalse(self.trash.exists())

    def test_outside_project_refused(self):
        other = Path(self.temp.name) / "outside.app"
        candidate = {"source": str(other), "build": 108, "version": "", "plist_sha256": "", "executable_sha256": ""}
        with self.assertRaises(RuntimeError):
            cleanup.move_to_trash(self.root, [candidate], 109, set(), self.trash)

    def test_idempotent_no_new_trash_or_receipt(self):
        old = self.app("build/old.app", "108")
        cleanup.move_to_trash(self.root, cleanup.find_obsolete(self.root, 109, set()), 109, set(), self.trash)
        before = sorted(self.trash.iterdir())
        result = cleanup.move_to_trash(self.root, [], 109, set(), self.trash)
        self.assertEqual(result, {"count": 0, "moved": [], "trash": None})
        self.assertEqual(before, sorted(self.trash.iterdir()))
        self.assertFalse(old.exists())

    def test_runtime_guard_refuses_missing_or_mismatched_process(self):
        class Probe:
            returncode = 0
            stdout = "verdict=PROVEN_DIFFERENT\npid.alive=yes\nstatus.claim.trusted=true\n"
        with patch.object(cleanup.subprocess, "run", return_value=Probe()):
            with self.assertRaises(RuntimeError):
                cleanup.verify_current(after_update=True)

    def test_runtime_guard_refuses_other_running_instances(self):
        class Probe:
            returncode = 0
            stdout = ("verdict=PROVEN_SAME_AS_BOTH\npid.alive=yes\nstatus.claim.trusted=true\n"
                      "bundle.installed.signature=pinned_certificate\n"
                      "bundle.installed.path=/Applications/QQ排程助手.app\n"
                      "scan.other_count=1\nscan.error=\n")
        with patch.object(cleanup.subprocess, "run", return_value=Probe()):
            with self.assertRaisesRegex(RuntimeError, "其他运行实例"):
                cleanup.verify_current(after_update=True)


if __name__ == "__main__":
    unittest.main()
