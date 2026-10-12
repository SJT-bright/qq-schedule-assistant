#!/usr/bin/env python3
"""Keep the installed app and fixed dist slot; move obsolete app bundles to Trash."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import uuid

IDENTIFIER = "local.felix.qqdispatch"
PROJECT = Path(__file__).resolve().parent.parent
INSTALLED = Path("/Applications/QQ排程助手.app")
IGNORED_DIRS = {".git", ".mimosa", "node_modules", "module-cache", "binding-probe-module-cache", "assets"}


def bundle_info(path):
    plist = path / "Contents/Info.plist"
    if path.is_symlink() or plist.is_symlink():
        return None
    try:
        raw = plist.read_bytes()
        info = plistlib.loads(raw)
        if not isinstance(info, dict):
            return None
        build = str(info.get("CFBundleVersion", ""))
        executable_name = info.get("CFBundleExecutable", "")
        if (info.get("CFBundleIdentifier") != IDENTIFIER or not build.isascii() or not build.isdecimal()
                or not executable_name or Path(executable_name).name != executable_name):
            return None
        executable = path / "Contents/MacOS" / executable_name
        if not executable.is_file() or executable.is_symlink():
            return None
        digest = hashlib.sha256(executable.read_bytes()).hexdigest()
        return {"build": int(build), "version": info.get("CFBundleShortVersionString", ""),
                "plist_sha256": hashlib.sha256(raw).hexdigest(), "executable_sha256": digest}
    except (OSError, ValueError, TypeError, plistlib.InvalidFileException):
        return None


def find_obsolete(project, current_build, protected):
    project = project.resolve()
    protected = {path.resolve() for path in protected}
    found = []
    for parent, dirs, _ in os.walk(project, followlinks=False):
        dirs[:] = [name for name in dirs if name not in IGNORED_DIRS and not (Path(parent) / name).is_symlink()]
        for name in dirs[:]:
            if not name.endswith(".app"):
                continue
            dirs.remove(name)  # Never descend into an app, including unrelated helper bundles.
            path = Path(parent) / name
            if path.resolve() in protected:
                continue
            info = bundle_info(path)
            if info is not None and info["build"] <= current_build:
                found.append({"source": str(path), **info})
    return sorted(found, key=lambda item: item["source"])


def verify_current(after_update=False):
    probe = subprocess.run(["bash", str(PROJECT / "Tools/check-runtime-provenance.sh")],
                           capture_output=True, text=True, timeout=30)
    facts = dict(line.split("=", 1) for line in probe.stdout.splitlines() if "=" in line)
    allowed = {"PROVEN_SAME_AS_BOTH"} if after_update else {"PROVEN_SAME_AS_BOTH", "PROVEN_SAME_AS_INSTALLED"}
    if (probe.returncode != 0 or facts.get("verdict") not in allowed
            or facts.get("bundle.installed.signature") != "pinned_certificate"
            or facts.get("pid.alive") != "yes" or facts.get("status.claim.trusted") != "true"
            or facts.get("bundle.installed.path") != str(INSTALLED)):
        raise RuntimeError("当前安装版运行身份或固定签名未确认，旧版本暂不清理；重开新版后运行 Tools/finish-update.sh")
    if facts.get("scan.other_count") != "0" or facts.get("scan.error") != "":
        raise RuntimeError("其他运行实例或进程扫描结果未确认，旧版本暂不清理")
    info = bundle_info(INSTALLED)
    if info is None or str(info["build"]) != facts.get("status.claim.build"):
        raise RuntimeError("实际运行版本与安装标签不一致，未清理")
    running_app = Path(facts["pid.executable_path"]).parent.parent.parent
    return info, running_app, facts


def move_to_trash(project, candidates, current_build, protected, trash_root):
    project = project.resolve()
    protected = {path.resolve() for path in protected}
    # Re-read every candidate before any move. Only .app leaves are moved, never their data-backup parents.
    for candidate in candidates:
        path = Path(candidate["source"])
        try:
            path.resolve().relative_to(project)
        except ValueError:
            raise RuntimeError("清理目标不在本项目内")
        if (path.is_symlink() or path.resolve() in protected or path.suffix != ".app"
                or bundle_info(path) != {key: candidate[key] for key in ("build", "version", "plist_sha256", "executable_sha256")}
                or candidate["build"] > current_build):
            raise RuntimeError("旧版本候选在检查后变化，未清理")
    if not candidates:
        return {"count": 0, "moved": [], "trash": None}
    timestamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    destination = trash_root / ("QQ排程助手-旧版本-" + timestamp + "-" + uuid.uuid4().hex[:8])
    destination.mkdir(parents=True, mode=0o700)
    manifest = {"created": datetime.datetime.now().isoformat(), "project": str(project),
                "current_build": current_build, "count": 0, "moved": [], "trash": str(destination),
                "planned": candidates}
    receipt = destination / "manifest.json"
    receipt.write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
    for candidate in candidates:
        source = Path(candidate["source"])
        # Refuse a concurrent build/replacement instead of moving a different bundle.
        if bundle_info(source) != {key: candidate[key] for key in ("build", "version", "plist_sha256", "executable_sha256")}:
            raise RuntimeError("旧应用在清理过程中变化，剩余文件保留")
        target = destination / source.relative_to(project)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(source), str(target))
        manifest["moved"].append({**candidate, "destination": str(target)})
        manifest["count"] += 1
        receipt.write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Only list obsolete app bundles")
    parser.add_argument("--automatic", action="store_true", help="Defer quietly when the current runtime cannot be verified")
    parser.add_argument("--after-update", action="store_true", help="Require running, installed and dist to match")
    args = parser.parse_args()
    try:
        current, running_app, facts = verify_current(after_update=args.after_update)
        protected = {INSTALLED, PROJECT / "dist/QQ排程助手.app", running_app}
        candidates = find_obsolete(PROJECT, current["build"], protected)
        if args.check:
            print(json.dumps({"current_build": current["build"], "count": len(candidates), "candidates": candidates}, ensure_ascii=False, indent=2))
            return 0
        result = move_to_trash(PROJECT, candidates, current["build"], protected, Path.home() / ".Trash")
        result["runtime_pid"] = facts["status.claim.pid"]
        log = PROJECT / "build/old-version-cleanup/latest.json"
        log.parent.mkdir(parents=True, exist_ok=True)
        log.write_text(json.dumps(result, ensure_ascii=False, indent=2))
        print("旧版本清理：" + str(result["count"]) + " 份旧应用已移到废纸篓；当前安装版和构建包保留。")
        return 0
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        return 0 if args.automatic else 1


if __name__ == "__main__":
    sys.exit(main())
