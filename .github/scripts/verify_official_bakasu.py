#!/usr/bin/env python3
"""Capture official inputs and verify the selected SUSFS implementation was compiled."""
import argparse
import hashlib
import json
import shutil
import subprocess
from pathlib import Path

BAKASU = "2734e0bc155759955880f5fb99be640fc5b92156"
FILES = (
    "kernel/feature/selinux_hide/selinux_hide.c",
    "kernel/feature/selinux_hide/selinux_hide_susfs.c",
    "kernel/feature/selinux_hide/selinux_hide_auto.c",
    "kernel/selinux/rules.c", "kernel/selinux/sepolicy.c", "uapi/ksu.h",
)
KERNEL_FILES = (
    "security/selinux/selinuxfs.c", "security/selinux/ss/services.c",
    "security/selinux/hooks.c", "security/selinux/status.c", "fs/susfs.c",
)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(*args, cwd=None):
    return subprocess.check_output(args, cwd=cwd, text=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("mode", choices=("capture", "verify"))
    ap.add_argument("--workspace", type=Path, required=True)
    ap.add_argument("--report", type=Path, required=True)
    ap.add_argument("--objdump")
    a = ap.parse_args()
    workspace, report = a.workspace.resolve(), a.report.resolve()
    report.mkdir(parents=True, exist_ok=True)
    baka, kernel = workspace / "KernelSU", workspace / "common"
    assert run("git", "rev-parse", "HEAD", cwd=baka).strip() == BAKASU
    run("git", "diff", "--exit-code", "HEAD", "--", *FILES, cwd=baka)
    hashes = {rel: sha(baka / rel) for rel in FILES}
    hashes.update({"common/" + rel: sha(kernel / rel) for rel in KERNEL_FILES})
    manifest = report / "official-source.json"
    if a.mode == "capture":
        for rel in FILES:
            target = report / "official-source" / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(baka / rel, target)
        for rel in KERNEL_FILES:
            target = report / "kernel-source" / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(kernel / rel, target)
        (report / "bakasu-commit.txt").write_text(BAKASU + "\n")
        (report / "susfs-commit.txt").write_text(run("git", "rev-parse", "HEAD", cwd=workspace / "susfs4ksu"))
        manifest.write_text(json.dumps({"bakasu_commit": BAKASU, "source_hashes": hashes,
                                       "custom_selinux_patch_applied": False}, indent=2) + "\n")
        print("Captured unchanged official sources:", BAKASU)
        return

    assert json.loads(manifest.read_text())["source_hashes"] == hashes
    rules = (baka / "kernel/selinux/rules.c").read_text()
    susfs = (baka / FILES[1]).read_text()
    out = kernel / "out"
    compiled = (out / "drivers/kernelsu/feature/selinux_hide/selinux_hide.i").read_text()
    services = (out / "security/selinux/ss/services.i").read_text()
    checks = {
        "real_generation_preserved": "pol->latest_granting = old_pol->latest_granting + 1" in rules,
        "real_notifications_use_generation": all(x in rules for x in (
            "avc_ss_reset(seqno);", "selnl_notify_policyload(seqno);",
            "selinux_status_update_policyload(seqno);")),
        "official_susfs_response_fix": "orig_access_write(file, buf, size)" in compiled,
        "official_running_guard": "ksu_selinux_hide_running" in compiled and "10000" in susfs,
        "auto_implementation_excluded": "security_context_to_sid_with_policy(" not in compiled,
        "manual_susfs_access_compiled": "susfs_security_compute_av_user(" in services,
        "custom_projection_excluded": "security_context_to_sid_user(" not in services,
        "susfs_config_enabled": "CONFIG_KSU_SUSFS=y" in (out / ".config").read_text(),
    }
    obj = out / "drivers/kernelsu/feature/selinux_hide/selinux_hide.o"
    disassembly = run(a.objdump, "-dr", str(obj))
    (report / "official-selinux-hide-objdump.txt").write_text(disassembly)
    checks["response_hook_in_object"] = "my_write_access" in disassembly
    checks["hook_install_in_object"] = "ksu_patch_text" in disassembly
    (report / "official-compile-checks.json").write_text(json.dumps(checks, indent=2) + "\n")
    assert all(checks.values()), checks
    print("Official source and object checks passed:", len(checks))


if __name__ == "__main__":
    main()
