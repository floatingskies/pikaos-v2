#! /bin/bash
# Boot a PikaOS-v2 ISO in QEMU under UEFI (OVMF) and dump the serial console.
#
#   ./iso-v2/qemu-test.sh [iso] [timeout_seconds]
#
# The live cmdline includes console=ttyS0 (see data/refind/EFI/boot/refind.conf),
# so the kernel, booster and the PikaOS live hook all log over serial.
set -euo pipefail

ISO="${1:-$(ls -1 "$(dirname "${BASH_SOURCE[0]}")"/build/output/*.iso 2>/dev/null | head -1)}"
TIMEOUT="${2:-240}"
OVMF_CODE="/usr/share/OVMF/x64/OVMF_CODE.4m.fd"
OVMF_VARS_SRC="/usr/share/OVMF/x64/OVMF_VARS.4m.fd"
WORK="/tmp/opencode/qemu-v2"

[ -f "$ISO" ] || { echo "no ISO given/found" >&2; exit 1; }
[ -f "$OVMF_CODE" ] || { echo "missing $OVMF_CODE" >&2; exit 1; }

mkdir -p "$WORK"
cp -f "$OVMF_VARS_SRC" "$WORK/OVMF_VARS.fd"
LOG="$WORK/serial.log"
: > "$LOG"

echo "==> booting $ISO (timeout ${TIMEOUT}s)"
echo "==> serial log: $LOG"
timeout "$TIMEOUT" qemu-system-x86_64 \
    -machine q35,accel=kvm:tcg \
    -m 3072 -cpu max -smp 2 \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$WORK/OVMF_VARS.fd" \
    -cdrom "$ISO" -boot d \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -serial "file:$LOG" \
    -display none -no-reboot || true

echo "==> serial tail"
tail -80 "$LOG"
