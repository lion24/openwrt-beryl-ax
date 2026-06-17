#!/usr/bin/env python3
"""
Layer 2b: boot the QEMU-bootable OpenWrt image and assert it works.

Boots the armsr/armv8 disk image (built by build-qemu-image.sh) under
qemu-system-aarch64 -M virt via UEFI, then drives the serial console to
verify:

  * the system boots all the way to a root shell;
  * the uci-defaults overlay applied (hostname + LAN address);
  * LuCI's web server (uhttpd) is running;
  * the key userspace packages we selected are installed.

This validates the Beryl AX *configuration and package selection*. It does
NOT validate the MT7981 kernel, device tree, or Wi-Fi drivers -- those are
hardware-specific and can only be tested on the real device.

Usage: scripts/run-qemu-test.py <disk-image>
"""

import os
import sys
import tempfile

import pexpect

PROMPT = r"root@[A-Za-z0-9_-]+:[^#]*#"
BOOT_TIMEOUT = 360  # software emulation (TCG) is slow

# UEFI firmware candidates, in order of preference, across CI (Ubuntu) and
# local (Homebrew macOS) installs.
FIRMWARE_CANDIDATES = [
    "/usr/share/qemu-efi-aarch64/QEMU_EFI.fd",
    "/usr/share/AAVMF/AAVMF_CODE.fd",
    "/usr/share/edk2/aarch64/QEMU_EFI.fd",
    "/opt/homebrew/share/qemu/edk2-aarch64-code.fd",
    "/usr/local/share/qemu/edk2-aarch64-code.fd",
    "/opt/homebrew/share/qemu/QEMU_EFI.fd",
]


def find_firmware():
    for path in FIRMWARE_CANDIDATES:
        if os.path.isfile(path):
            return path
    sys.exit(
        "ERROR: no aarch64 UEFI firmware found. Install 'qemu-efi-aarch64' "
        "(Debian/Ubuntu) or use the edk2 firmware shipped with QEMU."
    )


def build_qemu_cmd(disk, firmware, vars_path):
    cmd = [
        "qemu-system-aarch64",
        "-M", "virt",
        "-cpu", "cortex-a53",
        "-smp", "2",
        "-m", "512",
        "-nographic",
        "-drive", f"file={disk},if=virtio,format=raw",
        "-netdev", "user,id=n0",
        "-device", "virtio-net-pci,netdev=n0",
    ]
    # A "code" firmware image is a read-only pflash that needs a writable
    # vars pflash alongside it; a combined QEMU_EFI.fd works as a plain -bios.
    if "code" in os.path.basename(firmware).lower():
        cmd += [
            "-drive", f"if=pflash,format=raw,readonly=on,file={firmware}",
            "-drive", f"if=pflash,format=raw,file={vars_path}",
        ]
    else:
        cmd += ["-bios", firmware]
    return cmd


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: run-qemu-test.py <disk-image>")
    disk = sys.argv[1]
    if not os.path.isfile(disk):
        sys.exit(f"ERROR: disk image not found: {disk}")

    firmware = find_firmware()
    print(f"== Booting {disk} under QEMU (firmware: {firmware}) ==")

    # Writable EFI vars pflash, sized for the virt machine's pflash slot.
    vars_fd, vars_path = tempfile.mkstemp(suffix="-efivars.fd")
    os.close(vars_fd)
    with open(vars_path, "wb") as f:
        f.truncate(64 * 1024 * 1024)

    cmd = build_qemu_cmd(disk, firmware, vars_path)
    print("   " + " ".join(cmd))

    child = pexpect.spawn(cmd[0], cmd[1:], timeout=BOOT_TIMEOUT, encoding="utf-8")
    child.logfile_read = sys.stdout

    failures = []

    def check(description, command, expect_substring, refute=False):
        """Run a command at the shell and assert its output.

        refute=False: pass if expect_substring IS in the output.
        refute=True:  pass if expect_substring is NOT in the output.
        """
        child.sendline(command)
        child.expect(PROMPT)
        out = child.before
        hit = expect_substring in out
        passed = (not hit) if refute else hit
        print(f"\n[{'PASS' if passed else 'FAIL'}] {description}")
        if not passed:
            failures.append(description)

    try:
        # Wait for boot to reach a usable console.
        idx = child.expect(
            ["Please press Enter to activate this console", PROMPT],
            timeout=BOOT_TIMEOUT,
        )
        if idx == 0:
            child.sendline("")
            child.expect(PROMPT)
        print("\n[PASS] system booted to a root shell")

        check(
            "uci-defaults applied: hostname is beryl-ax-travel",
            "uci get system.@system[0].hostname",
            "beryl-ax-travel",
        )
        check(
            "uci-defaults applied: LAN address is 192.168.8.1",
            "uci get network.lan.ipaddr",
            "192.168.8.1",
        )
        check(
            "LuCI web server (uhttpd) is running",
            "pgrep -f uhttpd >/dev/null && echo UHTTPD_UP || echo UHTTPD_DOWN",
            "UHTTPD_UP",
        )
        check(
            "travelmate is installed",
            "[ -f /etc/init.d/travelmate ] && echo TM_OK || echo TM_NO",
            "TM_OK",
        )
        check(
            "wireguard tools (wg) installed",
            "command -v wg >/dev/null && echo WG_OK || echo WG_NO",
            "WG_OK",
        )
        check(
            "userspace tools installed (curl htop tcpdump iperf3 nano lsof)",
            "for b in curl htop tcpdump iperf3 nano lsof; do "
            "command -v $b >/dev/null || echo MISSING:$b; done; echo DONE",
            "MISSING:",
            refute=True,
        )

        child.sendline("poweroff")
        child.expect([pexpect.EOF, "reboot: Power down"], timeout=120)
    except pexpect.TIMEOUT:
        print("\n[FAIL] timed out waiting for QEMU console output")
        failures.append("boot/console timeout")
    except pexpect.EOF:
        print("\n[FAIL] QEMU exited unexpectedly")
        failures.append("unexpected QEMU exit")
    finally:
        if child.isalive():
            child.terminate(force=True)
        os.unlink(vars_path)

    print("\n== QEMU validation summary ==")
    if failures:
        for f in failures:
            print(f"  FAILED: {f}")
        sys.exit(1)
    print("  all checks passed")


if __name__ == "__main__":
    main()
