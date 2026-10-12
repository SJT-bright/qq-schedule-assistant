#!/bin/bash
# Read-only runtime provenance for QQ排程助手.
# Reads the permission claim, the live process image, and the on-disk bundles.
# Does not launch or signal the app, sign anything, write the support directory,
# or touch TCC, the queue, build/, or dist/.
# A CFBundleVersion match is only a label. It does not prove which bytes are running.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export QQ_PROVENANCE_ROOT="$ROOT"
export PYTHONIOENCODING="${PYTHONIOENCODING:-utf-8}"
PYTHON="$(command -v python3 || true)"
if [[ -z "$PYTHON" ]]; then
  echo "check-runtime-provenance: 需要 python3 才能核对进程映像" >&2
  exit 1
fi
exec "$PYTHON" - "$@" <<'QQ_PROVENANCE_PY'
import datetime
import errno
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys

EXPECTED_IDENTIFIER = "local.felix.qqdispatch"
EXPECTED_AUTHORITY = "QQDispatch Local Code Signing"
MAX_STATUS_BYTES = 65536
MAX_PLIST_BYTES = 1_048_576

REASON_TEXT = {
    "status_missing": "缺失：找不到 permission-status.json",
    "status_unreadable": "缺失：permission-status.json 无法读取",
    "status_malformed": "缺失：permission-status.json 不是可用的状态对象",
    "status_too_large": "缺失：permission-status.json 大得不像状态文件",
    "pid_missing": "缺失：状态文件里没有可用的 PID",
    "status_pid_not_alive": "陈旧 PID：状态文件记录的进程已经不存在",
    "status_pid_reused": "陈旧 PID：这个进程号现在是别的程序",
    "pid_permission": "无法核对 PID：读取进程信息被系统拒绝",
    "pid_unreadable": "读不到这个 PID 的可执行路径，不能判断进程是否还在，也不能证明运行映像",
    "image_unreadable": "进程还在，但读不到它的文本段或 CDHash，不能证明它和磁盘版是不是同一份",
    "image_contradiction": "进程映像的 inode 与 CDHash 互相矛盾，不能下结论",
}


def now_text():
    return datetime.datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %z")


def time_text(epoch):
    return datetime.datetime.fromtimestamp(epoch).astimezone().strftime("%Y-%m-%d %H:%M:%S %z")


def emit_lines(pairs):
    for key, value in pairs:
        text = "" if value is None else str(value)
        text = text.replace("\r", " ").replace("\n", " ").strip()
        sys.stdout.write(f"{key}={text}\n")


def run(args, timeout=30):
    try:
        return subprocess.run(
            args,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return exc


def output_text(result):
    if not isinstance(result, subprocess.CompletedProcess):
        return ""
    return (result.stderr or b"").decode("utf-8", "replace") + (result.stdout or b"").decode("utf-8", "replace")


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_stat(path):
    try:
        info = os.stat(path)
    except OSError:
        return None
    return {
        "inode": int(info.st_ino),
        "device": int(info.st_dev),
        "size": int(info.st_size),
        "mtime": time_text(info.st_mtime),
    }


def realpath(path):
    try:
        return os.path.realpath(path)
    except OSError:
        return path


def proc_pidpath(pid):
    import ctypes

    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    libproc.proc_pidpath.restype = ctypes.c_int
    # Larger than PROC_PIDPATHINFO_MAXSIZE (4096) returns EOVERFLOW before the
    # kernel checks whether the pid exists, so a dead pid would look unreadable.
    buf = ctypes.create_string_buffer(4096)
    ctypes.set_errno(0)
    length = libproc.proc_pidpath(int(pid), buf, 4096)
    err = ctypes.get_errno()
    if length <= 0:
        return "", err
    return buf.value.decode("utf-8", "replace"), 0


def csops_cdhash(pid):
    import ctypes

    libsys = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    libsys.csops.argtypes = [ctypes.c_int, ctypes.c_uint, ctypes.c_void_p, ctypes.c_size_t]
    libsys.csops.restype = ctypes.c_int
    raw = ctypes.create_string_buffer(20)
    ctypes.set_errno(0)
    rc = libsys.csops(int(pid), 5, raw, 20)  # CS_OPS_CDHASH
    err = ctypes.get_errno()
    if rc != 0:
        return "", err
    return raw.raw.hex(), 0


def list_visible_pids():
    import ctypes

    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    libproc.proc_listpids.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_int]
    libproc.proc_listpids.restype = ctypes.c_int
    last_error = 0
    for _ in range(3):
        ctypes.set_errno(0)
        need = libproc.proc_listpids(1, 0, None, 0)  # PROC_ALL_PIDS
        last_error = ctypes.get_errno()
        if need <= 0:
            continue
        buf = ctypes.create_string_buffer(need + 8192)
        ctypes.set_errno(0)
        got = libproc.proc_listpids(1, 0, buf, len(buf))
        last_error = ctypes.get_errno()
        if got <= 0:
            continue
        count = got // 4
        ints = ctypes.cast(buf, ctypes.POINTER(ctypes.c_int))
        return [int(ints[i]) for i in range(count) if int(ints[i]) > 0], 0
    return [], last_error or errno.EPERM


def parse_lsof(text):
    records = []
    current = None
    for line in text.splitlines():
        if not line:
            continue
        key, value = line[0], line[1:]
        if key == "f":
            if current:
                records.append(current)
            current = {"fd": value}
        elif current is not None and key in {"D", "i", "n"}:
            current[key] = value
    if current:
        records.append(current)
    return records


def parse_device(value):
    if value is None or value == "":
        return None
    try:
        if value.lower().startswith("0x"):
            return int(value, 16)
        return int(value)
    except ValueError:
        return None


def mapped_text(pid, proc_path):
    result = run(["lsof", "-n", "-P", "-a", "-p", str(pid), "-d", "txt", "-F", "pDinf"])
    if not isinstance(result, subprocess.CompletedProcess) or result.returncode != 0:
        detail = output_text(result).strip() if isinstance(result, subprocess.CompletedProcess) else str(result)
        return {"lsof": "failed", "lsof_detail": detail[:300]}
    records = parse_lsof(output_text(result))
    texts = [item for item in records if item.get("fd") == "txt"]
    chosen = None
    want = realpath(proc_path) if proc_path else ""
    for item in texts:
        name = item.get("n") or ""
        if want and realpath(name) == want:
            chosen = item
            break
    if chosen is None:
        for item in texts:
            name = item.get("n") or ""
            if not name.endswith("/dyld") and not name.endswith("/dyld_sim"):
                chosen = item
                break
    if chosen is None and texts:
        chosen = texts[0]
    if chosen is None:
        return {"lsof": "no_text"}
    inode = None
    try:
        inode = int(chosen.get("i")) if chosen.get("i") else None
    except ValueError:
        inode = None
    return {
        "lsof": "ok",
        "mapped_name": chosen.get("n") or "",
        "mapped_inode": inode,
        "mapped_device": parse_device(chosen.get("D")),
    }


def display_fields(text):
    fields = {
        "identifier": "",
        "cdhash": "",
        "flags": "",
        "authorities": [],
        "executable": "",
        "format": "",
        "requirement": "",
    }
    for line in text.splitlines():
        if line.startswith("Identifier="):
            fields["identifier"] = line.split("=", 1)[1].strip()
        elif line.startswith("CDHash="):
            fields["cdhash"] = line.split("=", 1)[1].strip().lower()
        elif line.startswith("Executable="):
            fields["executable"] = line.split("=", 1)[1].strip()
        elif line.startswith("Format="):
            fields["format"] = line.split("=", 1)[1].strip()
        elif line.startswith("Authority="):
            fields["authorities"].append(line.split("=", 1)[1].strip())
        elif "flags=" in line and not fields["flags"]:
            match = re.search(r"flags=(\S+)", line)
            if match:
                fields["flags"] = match.group(1)
        elif "certificate leaf = H\"" in line and not fields["requirement"]:
            fields["requirement"] = line.strip()
    match = re.search(r'certificate leaf = H"([0-9a-fA-F]+)"', fields["requirement"])
    fields["leaf"] = match.group(1).lower() if match else ""
    return fields


def codesign_display(target):
    result = run(["codesign", "-d", "--verbose=4", "-r-", target])
    if not isinstance(result, subprocess.CompletedProcess):
        return {"ok": False, "detail": str(result)}
    text = output_text(result)
    fields = display_fields(text)
    fields["ok"] = result.returncode == 0 and bool(fields["cdhash"] or fields["identifier"])
    fields["exit"] = result.returncode
    fields["detail"] = "" if fields["ok"] else text.strip()[:400]
    return fields


def same_vnode(left_inode, left_device, right_inode, right_device):
    if left_inode is None or right_inode is None or left_inode != right_inode:
        return False
    if left_device is None or right_device is None:
        return True
    return left_device == right_device


def inspect_process(pid):
    path, err = proc_pidpath(pid)
    info = {
        "pid": pid,
        "alive": "unknown",
        "errno": errno.errorcode.get(err, str(err)) if err else "0",
        "path": path,
        "identifier": "",
        "cdhash": "",
        "cdhash_source": "",
        "cdhash_conflict": False,
        "mapped_inode": None,
        "mapped_device": None,
        "mapped_name": "",
        "lsof": "",
        "path_inode": None,
        "path_device": None,
        "current_path_sha256": "",
        "running_image_sha256": "",
        "path_matches_mapping": "unknown",
    }
    if err == errno.ESRCH or (not path and err == errno.ESRCH):
        info["alive"] = "no"
        info["errno"] = "ESRCH"
        return info
    if not path and err == errno.EPERM:
        info["alive"] = "unknown"
        info["errno"] = "EPERM"
        return info
    if not path:
        info["alive"] = "unknown"
        return info
    info["alive"] = "yes"
    info["errno"] = "0"
    current = file_stat(path)
    if current:
        info["path_inode"] = current["inode"]
        info["path_device"] = current["device"]
        try:
            info["current_path_sha256"] = sha256_file(path)
        except OSError:
            info["current_path_sha256"] = ""
    mapped = mapped_text(pid, path)
    info["lsof"] = mapped.get("lsof", "")
    info["mapped_name"] = mapped.get("mapped_name", "")
    info["mapped_inode"] = mapped.get("mapped_inode")
    info["mapped_device"] = mapped.get("mapped_device")
    if info["mapped_inode"] is not None and same_vnode(
        info["mapped_inode"], info["mapped_device"], info["path_inode"], info["path_device"]
    ):
        info["path_matches_mapping"] = "yes"
        info["running_image_sha256"] = info["current_path_sha256"]
    elif info["mapped_inode"] is not None:
        info["path_matches_mapping"] = "no"
    cs_hash, _cs_err = csops_cdhash(pid)
    shown = codesign_display(f"+{pid}")
    sign_hash = shown.get("cdhash", "") if shown.get("ok") else ""
    info["identifier"] = shown.get("identifier", "") if shown.get("ok") else ""
    if cs_hash and sign_hash and cs_hash != sign_hash:
        info["cdhash_conflict"] = True
        info["cdhash"] = ""
        info["cdhash_source"] = "conflict"
    elif cs_hash and sign_hash:
        info["cdhash"] = cs_hash
        info["cdhash_source"] = "csops+codesign"
    elif cs_hash:
        info["cdhash"] = cs_hash
        info["cdhash_source"] = "csops"
    elif sign_hash:
        info["cdhash"] = sign_hash
        info["cdhash_source"] = "codesign"
    return info


def is_app_process(info, claimed_exe, claimed_stat):
    identifier = info.get("identifier") or ""
    path = realpath(info.get("path") or "")
    if identifier == EXPECTED_IDENTIFIER:
        return True, "identifier"
    if claimed_exe and path and path == realpath(claimed_exe):
        return True, "claimed_path"
    if claimed_stat and same_vnode(
        info.get("mapped_inode"), info.get("mapped_device"), claimed_stat.get("inode"), claimed_stat.get("device")
    ):
        return True, "mapped_inode"
    if path.endswith("/QQ排程助手.app/Contents/MacOS/QQDispatch"):
        return True, "bundle_path"
    # A different copy, or a replaced bundle path, is still this executable name.
    # Unrelated recycled pids such as /bin/sleep do not match and stay stale.
    if os.path.basename(path) == "QQDispatch" and path.endswith("/Contents/MacOS/QQDispatch"):
        return True, "qqdispatch_executable"
    return False, "none"


def read_status(path):
    result = {
        "path": path,
        "readable": "no",
        "reason": "",
        "mtime": "",
        "sha256": "",
        "keys": "",
        "app_path": "",
        "build": "",
        "pid": None,
        "trusted": "",
    }
    try:
        info = os.stat(path)
    except FileNotFoundError:
        result["reason"] = "status_missing"
        return result
    except OSError:
        result["reason"] = "status_unreadable"
        return result
    if info.st_size > MAX_STATUS_BYTES:
        result["reason"] = "status_too_large"
        return result
    result["mtime"] = time_text(info.st_mtime)
    try:
        with open(path, "rb") as handle:
            raw = handle.read()
    except OSError:
        result["reason"] = "status_unreadable"
        return result
    result["sha256"] = hashlib.sha256(raw).hexdigest()
    try:
        data = json.loads(raw.decode("utf-8-sig"))
    except (UnicodeError, json.JSONDecodeError):
        result["reason"] = "status_malformed"
        return result
    if not isinstance(data, dict):
        result["reason"] = "status_malformed"
        return result
    result["readable"] = "yes"
    result["keys"] = ",".join(sorted(str(key) for key in data.keys()))
    app_path = data.get("appPath", "")
    result["app_path"] = app_path if isinstance(app_path, str) else ""
    build = data.get("build", "")
    if isinstance(build, bool):
        build = ""
    result["build"] = str(build) if build is not None else ""
    trusted = data.get("trusted", None)
    if isinstance(trusted, bool):
        result["trusted"] = "true" if trusted else "false"
    else:
        result["trusted"] = ""
    pid_value = data.get("pid", None)
    if isinstance(pid_value, bool):
        pid_value = None
    elif isinstance(pid_value, int):
        pid_value = pid_value if pid_value > 0 else None
    elif isinstance(pid_value, str) and pid_value.isdigit():
        pid_value = int(pid_value) if int(pid_value) > 0 else None
    else:
        pid_value = None
    result["pid"] = pid_value
    if pid_value is None:
        result["reason"] = "pid_missing"
    return result


def read_identity(path):
    try:
        text = open(path, "r", encoding="utf-8").read().strip()
    except OSError:
        return {"path": path, "readable": "no", "sha1": ""}
    if not re.fullmatch(r"[0-9a-fA-F]{40}", text):
        return {"path": path, "readable": "invalid", "sha1": ""}
    return {"path": path, "readable": "yes", "sha1": text.lower()}


def bundle_facts(label, app_path, identity):
    facts = {
        "label": label,
        "path": app_path,
        "present": "no",
        "plist_build": "",
        "plist_sha256": "",
        "executable": "",
        "sha256": "",
        "inode": None,
        "device": None,
        "size": "",
        "mtime": "",
        "cdhash": "",
        "identifier": "",
        "flags": "",
        "authority": "",
        "leaf": "",
        "verify_strict": "no",
        "leaf_matches_identity": "no",
        "signature": "missing",
        "adhoc": "unknown",
    }
    if not app_path or not os.path.isdir(app_path):
        return facts
    facts["present"] = "yes"
    plist_path = os.path.join(app_path, "Contents", "Info.plist")
    exe = os.path.join(app_path, "Contents", "MacOS", "QQDispatch")
    facts["executable"] = exe
    try:
        plist_size = os.stat(plist_path).st_size
    except OSError:
        plist_size = None
    if plist_size is not None and plist_size <= MAX_PLIST_BYTES:
        try:
            facts["plist_sha256"] = sha256_file(plist_path)
            with open(plist_path, "rb") as handle:
                plist = plistlib.load(handle)
            version = plist.get("CFBundleVersion", "")
            facts["plist_build"] = str(version) if not isinstance(version, bool) else ""
        except (OSError, plistlib.InvalidFileException, ValueError):
            facts["plist_build"] = ""
    exe_stat = file_stat(exe)
    if exe_stat:
        facts["inode"] = exe_stat["inode"]
        facts["device"] = exe_stat["device"]
        facts["size"] = str(exe_stat["size"])
        facts["mtime"] = exe_stat["mtime"]
        try:
            facts["sha256"] = sha256_file(exe)
        except OSError:
            facts["sha256"] = ""
    shown = codesign_display(app_path)
    if not shown.get("cdhash"):
        shown_exe = codesign_display(exe)
        if shown_exe.get("cdhash"):
            shown = shown_exe
    if not shown.get("leaf"):
        requirement = run(["codesign", "-d", "-r-", app_path])
        leaf_fields = display_fields(output_text(requirement) if isinstance(requirement, subprocess.CompletedProcess) else "")
        if leaf_fields.get("leaf"):
            shown["leaf"] = leaf_fields["leaf"]
            shown["requirement"] = leaf_fields["requirement"]
    facts["cdhash"] = shown.get("cdhash", "")
    facts["identifier"] = shown.get("identifier", "")
    facts["flags"] = shown.get("flags", "")
    authorities = shown.get("authorities") or []
    facts["authority"] = authorities[0] if authorities else ""
    facts["leaf"] = shown.get("leaf", "")
    flags = facts["flags"].lower()
    facts["adhoc"] = "yes" if ("adhoc" in flags or "linker-signed" in flags) else "no"
    verify = run(["codesign", "--verify", "--strict", "--verbose=2", app_path])
    verify_text = output_text(verify) if isinstance(verify, subprocess.CompletedProcess) else ""
    verify_ok = (
        isinstance(verify, subprocess.CompletedProcess)
        and verify.returncode == 0
        and "valid on disk" in verify_text
        and "satisfies its Designated Requirement" in verify_text
    )
    facts["verify_strict"] = "yes" if verify_ok else "no"
    leaf_ok = False
    if identity.get("readable") == "yes":
        leaf_check = run([
            "codesign", "--verify", "--strict",
            "-R", f'=certificate leaf = H"{identity["sha1"]}"',
            app_path,
        ])
        leaf_ok = isinstance(leaf_check, subprocess.CompletedProcess) and leaf_check.returncode == 0
    facts["leaf_matches_identity"] = "yes" if leaf_ok else "no"
    pinned = (
        verify_ok
        and leaf_ok
        and facts["identifier"] == EXPECTED_IDENTIFIER
        and facts["flags"] == "0x0(none)"
        and facts["adhoc"] == "no"
        and facts["authority"] == EXPECTED_AUTHORITY
        and facts["leaf"] == identity.get("sha1", "")
    )
    if not exe_stat:
        facts["signature"] = "missing_executable"
    elif pinned:
        facts["signature"] = "pinned_certificate"
    elif facts["adhoc"] == "yes":
        facts["signature"] = "adhoc"
    elif verify_ok and not leaf_ok:
        facts["signature"] = "not_pinned_certificate"
    elif verify_ok:
        facts["signature"] = "not_pinned_certificate"
    else:
        facts["signature"] = "invalid"
    return facts


def compare(process, bundle):
    if bundle["present"] != "yes" or not bundle["sha256"]:
        return "absent", "bundle_missing"
    if process.get("cdhash_conflict"):
        return "contradiction", "process_cdhash_sources_disagree"
    inode_same = same_vnode(
        process.get("mapped_inode"), process.get("mapped_device"), bundle.get("inode"), bundle.get("device")
    )
    cd_proc = process.get("cdhash") or ""
    cd_disk = bundle.get("cdhash") or ""
    cd_same = bool(cd_proc and cd_disk and cd_proc == cd_disk)
    cd_diff = bool(cd_proc and cd_disk and cd_proc != cd_disk)
    if inode_same and cd_diff:
        return "contradiction", "inode_matches_but_cdhash_differs"
    if inode_same:
        return "proven_same_file", "mapped_inode+sha256"
    if cd_same:
        return "proven_same_code", "process_cdhash"
    if cd_diff:
        return "proven_different", "process_cdhash"
    running_hash = process.get("running_image_sha256") or ""
    if running_hash and bundle.get("sha256"):
        if running_hash == bundle["sha256"]:
            return "proven_same_file", "running_image_sha256"
        return "proven_different", "running_image_sha256"
    if process.get("mapped_inode") is not None and bundle.get("inode") is not None and not inode_same:
        return "not_provable", "different_inode_without_cdhash"
    return "not_provable", "no_process_image_binding"


def same_kind(state):
    return state in {"proven_same_file", "proven_same_code"}


def rollup(installed_state, dist_state):
    states = [installed_state, dist_state]
    if any(state in {"contradiction", "not_provable"} for state in states):
        return "NOT_PROVABLE"
    if same_kind(installed_state) and same_kind(dist_state):
        return "PROVEN_SAME_AS_BOTH"
    if same_kind(installed_state) and dist_state == "proven_different":
        return "PROVEN_SAME_AS_INSTALLED"
    if same_kind(dist_state) and installed_state == "proven_different":
        return "PROVEN_SAME_AS_DIST"
    if installed_state == "proven_different" and dist_state == "proven_different":
        return "PROVEN_DIFFERENT"
    if installed_state == "absent" and same_kind(dist_state):
        return "PROVEN_SAME_AS_DIST"
    if dist_state == "absent" and same_kind(installed_state):
        return "PROVEN_SAME_AS_INSTALLED"
    if installed_state == "absent" and dist_state == "proven_different":
        return "PROVEN_DIFFERENT"
    if dist_state == "absent" and installed_state == "proven_different":
        return "PROVEN_DIFFERENT"
    return "NOT_PROVABLE"


def scan_others(claimed_pid):
    pids, err = list_visible_pids()
    found = []
    if err and not pids:
        return [], errno.errorcode.get(err, str(err))
    for pid in pids:
        if pid == claimed_pid:
            continue
        path, path_err = proc_pidpath(pid)
        if path_err or not path:
            continue
        if os.path.basename(path) != "QQDispatch" and "QQ排程助手.app/Contents/MacOS/QQDispatch" not in path:
            continue
        found.append((pid, path))
    return found, ""


def add_bundle_lines(lines, facts):
    label = facts["label"]
    lines.extend([
        (f"bundle.{label}.path", facts["path"]),
        (f"bundle.{label}.present", facts["present"]),
        (f"bundle.{label}.plist_build", facts["plist_build"]),
        (f"bundle.{label}.plist_weight", "label_only"),
        (f"bundle.{label}.plist_sha256", facts["plist_sha256"]),
        (f"bundle.{label}.executable", facts["executable"]),
        (f"bundle.{label}.sha256", facts["sha256"]),
        (f"bundle.{label}.inode", facts["inode"] if facts["inode"] is not None else ""),
        (f"bundle.{label}.device", facts["device"] if facts["device"] is not None else ""),
        (f"bundle.{label}.size", facts["size"]),
        (f"bundle.{label}.mtime", facts["mtime"]),
        (f"bundle.{label}.cdhash", facts["cdhash"]),
        (f"bundle.{label}.identifier", facts["identifier"]),
        (f"bundle.{label}.flags", facts["flags"]),
        (f"bundle.{label}.authority", facts["authority"]),
        (f"bundle.{label}.requirement_leaf", facts["leaf"]),
        (f"bundle.{label}.verify_strict", facts["verify_strict"]),
        (f"bundle.{label}.leaf_matches_identity", facts["leaf_matches_identity"]),
        (f"bundle.{label}.adhoc", facts["adhoc"]),
        (f"bundle.{label}.signature", facts["signature"]),
    ])


def usage():
    sys.stdout.write(
        "\n".join([
            "用法: bash Tools/check-runtime-provenance.sh [--status-file PATH] [--installed-app PATH] [--dist-app PATH] [--identity-file PATH]",
            "只读核对运行映像与磁盘包。不启动 App，不签名，不写正式资料。",
            "退出码: 0 已证明相同或不同；2 状态文件缺失或不可用；3 陈旧或被占用的 PID；4 进程在但映像不可证；1 工具失败。",
            "Info.plist 的 CFBundleVersion 只是标签。permission-status.json 的 build 只是进程上次写下的声明。",
            "",
        ])
    )


def parse_args(argv):
    opts = {"help": False}
    names = {
        "--status-file": "status",
        "--installed-app": "installed",
        "--dist-app": "dist",
        "--identity-file": "identity",
    }
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg in {"-h", "--help"}:
            opts["help"] = True
        elif arg in names:
            index += 1
            if index >= len(argv):
                raise SystemExit(f"check-runtime-provenance: {arg} 缺少参数")
            opts[names[arg]] = argv[index]
        else:
            raise SystemExit(f"check-runtime-provenance: 未知参数 {arg}")
        index += 1
    return opts


def choose(opts, name, env_name, default):
    if opts.get(name):
        return opts[name]
    if os.environ.get(env_name):
        return os.environ[env_name]
    return default


def main(argv):
    try:
        opts = parse_args(argv)
    except SystemExit as exc:
        sys.stderr.write(str(exc) + "\n")
        return 1
    if opts["help"]:
        usage()
        return 0
    root = os.environ.get("QQ_PROVENANCE_ROOT") or os.getcwd()
    status_path = choose(
        opts, "status", "QQ_PROVENANCE_STATUS_FILE",
        os.path.join(os.path.expanduser("~"), "Library", "Application Support", "QQ排程助手", "permission-status.json"),
    )
    installed_path = choose(opts, "installed", "QQ_PROVENANCE_INSTALLED_APP", "/Applications/QQ排程助手.app")
    dist_path = choose(opts, "dist", "QQ_PROVENANCE_DIST_APP", os.path.join(root, "dist", "QQ排程助手.app"))
    identity_path = choose(
        opts, "identity", "QQ_PROVENANCE_IDENTITY_FILE",
        os.path.join(os.path.expanduser("~"), "Library", "Application Support", "QQDispatchSigning", "identity.sha1"),
    )
    identity = read_identity(identity_path)
    installed = bundle_facts("installed", installed_path, identity)
    dist = bundle_facts("dist", dist_path, identity)
    status = read_status(status_path)
    process = None
    attribute = False
    attribute_reason = "none"
    exit_code = 0
    reason = ""
    if status["reason"] in {"status_missing", "status_unreadable", "status_malformed", "status_too_large", "pid_missing"}:
        reason = status["reason"]
        exit_code = 2
    else:
        process = inspect_process(status["pid"])
        claimed_exe = os.path.join(status["app_path"], "Contents", "MacOS", "QQDispatch") if status["app_path"] else ""
        claimed_stat = file_stat(claimed_exe) if claimed_exe else None
        if process["alive"] == "no":
            reason = "status_pid_not_alive"
            exit_code = 3
        elif process["alive"] != "yes":
            reason = "pid_permission" if process["errno"] == "EPERM" else "pid_unreadable"
            exit_code = 4
        else:
            attribute, attribute_reason = is_app_process(process, claimed_exe, claimed_stat)
            if not attribute:
                reason = "status_pid_reused"
                exit_code = 3
    installed_state, installed_basis = ("not_provable", "no_live_attributed_process")
    dist_state, dist_basis = ("not_provable", "no_live_attributed_process")
    verdict = "NOT_PROVABLE"
    if process and process["alive"] == "yes" and attribute:
        installed_state, installed_basis = compare(process, installed)
        dist_state, dist_basis = compare(process, dist)
        verdict = rollup(installed_state, dist_state)
        if verdict == "NOT_PROVABLE":
            if "contradiction" in {installed_state, dist_state}:
                reason = "image_contradiction"
            else:
                reason = "image_unreadable"
            exit_code = 4
        else:
            reason = "compared"
            exit_code = 0
    others, scan_error = scan_others(status["pid"] or -1)
    other_facts = []
    for other_pid, other_path in others[:3]:
        other = inspect_process(other_pid)
        other_installed, other_installed_basis = compare(other, installed)
        other_dist, other_dist_basis = compare(other, dist)
        other_facts.append((other_pid, other_path, other, other_installed, other_installed_basis, other_dist, other_dist_basis))
    claim_path_matches = "unknown"
    if process and process.get("path") and status["app_path"]:
        claimed_exe_now = os.path.join(status["app_path"], "Contents", "MacOS", "QQDispatch")
        claim_path_matches = "yes" if realpath(process["path"]) == realpath(claimed_exe_now) else "no"
    lines = [
        ("tool", "check-runtime-provenance"),
        ("read_only", "yes"),
        ("checked_at", now_text()),
        ("proof_rule", "运行映像只认文本段 inode 与进程 CDHash；CFBundleVersion 和 status.build 都不能证明当前进程"),
        ("verdict", verdict),
        ("reason", reason),
        ("exit", exit_code),
        ("status.file", status["path"]),
        ("status.readable", status["readable"]),
        ("status.mtime", status["mtime"]),
        ("status.sha256", status["sha256"]),
        ("status.keys", status["keys"]),
        ("status.claim.app_path", status["app_path"]),
        ("status.claim.build", status["build"]),
        ("status.claim.build_weight", "claim_only"),
        ("status.claim.pid", status["pid"] if status["pid"] is not None else ""),
        ("status.claim.trusted", status["trusted"]),
        ("status.claim.trusted_weight", "claim_only"),
    ]
    if process:
        lines.extend([
            ("pid.alive", process["alive"]),
            ("pid.errno", process["errno"]),
            ("pid.executable_path", process["path"]),
            ("pid.claim_path_matches", claim_path_matches),
            ("pid.identifier", process["identifier"]),
            ("pid.attributed", "yes" if attribute else "no"),
            ("pid.attribute_reason", attribute_reason),
            ("pid.cdhash", process["cdhash"]),
            ("pid.cdhash_source", process["cdhash_source"]),
            ("pid.mapped_inode", process["mapped_inode"] if process["mapped_inode"] is not None else ""),
            ("pid.mapped_device", process["mapped_device"] if process["mapped_device"] is not None else ""),
            ("pid.mapped_name", process["mapped_name"]),
            ("pid.lsof", process["lsof"]),
            ("pid.current_path_inode", process["path_inode"] if process["path_inode"] is not None else ""),
            ("pid.current_path_sha256", process["current_path_sha256"]),
            ("pid.path_matches_mapping", process["path_matches_mapping"]),
            ("pid.running_image_sha256", process["running_image_sha256"]),
        ])
    else:
        lines.extend([
            ("pid.alive", ""),
            ("pid.executable_path", ""),
            ("pid.claim_path_matches", claim_path_matches),
            ("pid.attributed", "no"),
            ("pid.running_image_sha256", ""),
        ])
    lines.extend([
        ("identity.file", identity["path"]),
        ("identity.readable", identity["readable"]),
        ("identity.sha1", identity["sha1"]),
    ])
    add_bundle_lines(lines, installed)
    add_bundle_lines(lines, dist)
    plist_same = "yes" if installed["plist_build"] and installed["plist_build"] == dist["plist_build"] else "no"
    hash_same = "yes" if installed["sha256"] and installed["sha256"] == dist["sha256"] else "no"
    plist_bytes_same = "yes" if installed["plist_sha256"] and installed["plist_sha256"] == dist["plist_sha256"] else "no"
    cd_same = "yes" if installed["cdhash"] and installed["cdhash"] == dist["cdhash"] else "no"
    lines.extend([
        ("disk.plist_build_same_label", plist_same),
        ("disk.plist_bytes_same", plist_bytes_same),
        ("disk.sha256_same", hash_same),
        ("disk.cdhash_same", cd_same),
        ("disk.note", "相同的 CFBundleVersion 只说明版本标签相同，不说明二进制相同，也不说明有进程正在运行"),
        ("running_vs_installed", installed_state),
        ("running_vs_installed.basis", installed_basis),
        ("running_vs_dist", dist_state),
        ("running_vs_dist.basis", dist_basis),
        ("scan.other_count", len(others)),
        ("scan.error", errno.errorcode.get(scan_error, scan_error) if isinstance(scan_error, int) else scan_error),
    ])
    for other_pid, other_path, other, other_installed, other_installed_basis, other_dist, other_dist_basis in other_facts:
        lines.extend([
            (f"scan.other.{other_pid}.path", other_path),
            (f"scan.other.{other_pid}.identifier", other.get("identifier", "")),
            (f"scan.other.{other_pid}.cdhash", other.get("cdhash", "")),
            (f"scan.other.{other_pid}.vs_installed", other_installed),
            (f"scan.other.{other_pid}.vs_installed.basis", other_installed_basis),
            (f"scan.other.{other_pid}.vs_dist", other_dist),
            (f"scan.other.{other_pid}.vs_dist.basis", other_dist_basis),
        ])
    claim_note = ""
    mapping_note = ""
    if claim_path_matches == "no":
        claim_note = "状态文件里的 appPath 与进程实际可执行路径不一致。"
    if process and process.get("path_matches_mapping") == "no":
        mapping_note = "进程路径上现在的文件不是已映射的映像，不能拿它的 SHA-256 当作运行版本。"
    if reason == "compared":
        relation = {
            "PROVEN_SAME_AS_INSTALLED": "运行映像可证与安装版是同一份，且可证与 dist 不是同一份",
            "PROVEN_SAME_AS_DIST": "运行映像可证与 dist 是同一份，且可证与安装版不是同一份",
            "PROVEN_SAME_AS_BOTH": "运行映像可证与安装版和 dist 都是同一份",
            "PROVEN_DIFFERENT": "运行映像可证与安装版、dist 都不是同一份",
        }[verdict]
        message = relation + "。依据是进程文本段或 CDHash，不是 Info.plist。" + claim_note + mapping_note
    else:
        message = REASON_TEXT.get(reason, reason)
        if status["mtime"] and reason in {"status_pid_not_alive", "status_pid_reused"}:
            message += f"。状态文件时间是 {status['mtime']}"
        message += "。磁盘上的 CFBundleVersion 不能代替这个结论。"
    lines.append(("message", message))
    emit_lines(lines)
    if exit_code != 0:
        sys.stderr.write(f"check-runtime-provenance: {message}\n")
    return exit_code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
QQ_PROVENANCE_PY
