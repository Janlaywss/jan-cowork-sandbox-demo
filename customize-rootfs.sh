#!/bin/bash
# customize-rootfs.sh — Customize a stock Ubuntu cloud image into a JanworkVM rootfs.
#
# Takes a standard Ubuntu 22.04 cloud image (.img, qcow2 or raw) and injects:
#   1. janworkd.service     — systemd service for the daemon
#   2. sdk-daemon          — the Rust janworkd binary (from daemon/build-image.sh)
#   3. sandbox-helper      — seccomp sandbox stub
#   4. hostname            — set to "claude"
#   5. srt-settings.json   — network/filesystem security policy
#
# Prerequisites:
#   brew install e2fsprogs qemu       (debugfs for ext4, qemu-img for qcow2→raw)
#   cd vm/daemon && ./build-image.sh --build-only   (cross-compile Rust daemon)
#
# The Ubuntu 22.04 arm64 cloud image has a GPT partition table with an EFI
# System Partition (partition 15), so it boots via UEFI out of the box.
#
# Usage:
#   # Download base image:
#   ./get-base-image.sh
#
#   # Customize → injects our daemon into rootfs.img:
#   ./customize-rootfs.sh rootfs.img
#
#   # Then use it:
#   cp rootfs.img bundle/rootfs.img
#   node demo.mjs
#
# Options:
#   --daemon /path/to/bin   Use a custom sdk-daemon binary
#   --skip-daemon           Skip daemon installation
#   --output /path/to/out   Output path (default: rootfs.img in current dir)
#   --size 10G              Disk size (default: 10G)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Parse arguments ──

IMAGE="${1:-}"
DAEMON_BIN=""
SKIP_DAEMON=false
OUTPUT="rootfs.img"
DISK_SIZE="10G"

shift || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --daemon) DAEMON_BIN="$2"; shift 2 ;;
        --skip-daemon) SKIP_DAEMON=true; shift ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --size) DISK_SIZE="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -z "$IMAGE" ]]; then
    cat <<'USAGE'
Usage: ./customize-rootfs.sh <ubuntu-cloud-image> [options]

Options:
  --daemon <path>    Custom sdk-daemon binary
  --skip-daemon      Skip daemon installation
  --output <path>    Output file (default: rootfs.img)
  --size <size>      Disk size (default: 10G)

Example:
  curl -LO https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-arm64.img
  ./customize-rootfs.sh ubuntu-22.04-server-cloudimg-arm64.img
USAGE
    exit 1
fi

[[ ! -f "$IMAGE" ]] && { echo "Error: Image not found: $IMAGE"; exit 1; }

# ── Find tools ──

export PATH="/opt/homebrew/opt/e2fsprogs/sbin:/opt/homebrew/opt/e2fsprogs/bin:$PATH"

for cmd in debugfs e2fsck qemu-img; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: $cmd not found. Install with: brew install e2fsprogs qemu"
        exit 1
    fi
done

# ── Find sdk-daemon binary ──

if [[ -z "$DAEMON_BIN" ]] && [[ "$SKIP_DAEMON" != "true" ]]; then
    DAEMON_BIN="$SCRIPT_DIR/daemon/target/aarch64-unknown-linux-musl/release/janworkd"
    if [[ ! -f "$DAEMON_BIN" ]]; then
        echo "Error: Rust daemon not built. Run first:"
        echo "  cd daemon && ./build-image.sh --build-only"
        exit 1
    fi
fi

echo "=== JanworkVM rootfs customization ==="
echo "Input:  $IMAGE"
echo "Output: $OUTPUT"
echo "Size:   $DISK_SIZE"
[[ "$SKIP_DAEMON" != "true" ]] && echo "Daemon: $DAEMON_BIN ($(wc -c < "$DAEMON_BIN" | tr -d ' ') bytes)"
echo ""

# ── Step 1: Convert to raw if needed ──

echo "[1/10] Preparing raw disk image..."

FILE_TYPE=$(file "$IMAGE")
if echo "$FILE_TYPE" | grep -q "QCOW2"; then
    echo "  Converting QCOW2 → raw..."
    qemu-img convert -f qcow2 -O raw "$IMAGE" "$OUTPUT"
elif [[ "$IMAGE" != "$OUTPUT" ]]; then
    echo "  Copying image..."
    cp "$IMAGE" "$OUTPUT"
else
    echo "  Image is already raw, modifying in-place"
fi

# Resize to target size
CURRENT_SIZE=$(stat -f%z "$OUTPUT" 2>/dev/null || stat -c%s "$OUTPUT" 2>/dev/null)
TARGET_BYTES=$(echo "$DISK_SIZE" | awk '/G$/{print $0*1024*1024*1024} /M$/{print $0*1024*1024}' | head -1)
if [[ -n "$TARGET_BYTES" ]] && (( CURRENT_SIZE < TARGET_BYTES )); then
    echo "  Resizing to $DISK_SIZE..."
    qemu-img resize -f raw "$OUTPUT" "$DISK_SIZE" 2>/dev/null
    # Resize the ext4 partition to fill the disk
    # (e2fsck + resize2fs will be done after attaching)
fi

echo "  $(ls -lh "$OUTPUT" | awk '{print $5}') (sparse)"

# ── Step 2: Attach and find ext4 partition ──

echo "[2/10] Attaching disk image..."

ATTACH_OUT=$(hdiutil attach "$OUTPUT" -nomount 2>&1)
DEVICE=$(echo "$ATTACH_OUT" | head -1 | awk '{print $1}')

# Find ext4 partition
EXT4_DEV=""
while IFS= read -r line; do
    dev=$(echo "$line" | awk '{print $1}')
    if [[ "$dev" == *"s1" ]] && [[ "$dev" != *"s15" ]]; then
        EXT4_DEV="$dev"
        break
    fi
done <<< "$ATTACH_OUT"
[[ -z "$EXT4_DEV" ]] && EXT4_DEV="${DEVICE}s1"

echo "  Device: $DEVICE"
echo "  Ext4:   $EXT4_DEV"

cleanup() {
    hdiutil detach "$DEVICE" 2>/dev/null || true
}
trap cleanup EXIT

# ── Step 3: Verify & resize filesystem ──

echo "[3/10] Checking ext4 filesystem..."
# e2fsck returns 1 when it fixes errors (expected for modified images), so allow non-zero exit
e2fsck -fy "$EXT4_DEV" 2>&1 | tail -3 || true
echo "  Filesystem ready"

# ── Step 4: Install janworkd.service ──

echo "[4/10] Installing janworkd.service..."

UNIT_FILE=$(mktemp /tmp/janworkd.XXXXXX.service)
cat > "$UNIT_FILE" << 'UNIT'
[Unit]
Description=janworkd - vsock RPC bridge for process management
After=network.target local-fs.target systemd-udev-settle.service
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sdk-daemon
Restart=always
RestartSec=3
User=root
Group=root
Environment=HOME=/root
StandardOutput=journal
StandardError=journal
SyslogIdentifier=janworkd
NoNewPrivileges=no
ProtectSystem=false
ProtectHome=false
PrivateTmp=false

[Install]
WantedBy=multi-user.target
UNIT

debugfs -w "$EXT4_DEV" <<EOF 2>/dev/null
rm /etc/systemd/system/janworkd.service
write $UNIT_FILE /etc/systemd/system/janworkd.service
set_inode_field /etc/systemd/system/janworkd.service mode 0100644
mkdir /etc/systemd/system/multi-user.target.wants
rm /etc/systemd/system/multi-user.target.wants/janworkd.service
symlink /etc/systemd/system/multi-user.target.wants/janworkd.service /etc/systemd/system/janworkd.service
quit
EOF
rm -f "$UNIT_FILE"
echo "  /etc/systemd/system/janworkd.service ✓"

# ── Step 5: Install sdk-daemon + sandbox-helper ──

echo "[5/10] Installing binaries..."

if [[ "$SKIP_DAEMON" == "true" ]]; then
    echo "  Skipped (--skip-daemon)"
else
    # Ensure /usr/local/bin exists (should exist in Ubuntu)
    debugfs -w "$EXT4_DEV" <<EOF 2>/dev/null
rm /usr/local/bin/sdk-daemon
write $DAEMON_BIN /usr/local/bin/sdk-daemon
set_inode_field /usr/local/bin/sdk-daemon mode 0100755
quit
EOF
    echo "  /usr/local/bin/sdk-daemon ✓ ($(wc -c < "$DAEMON_BIN" | tr -d ' ') bytes)"

    # sandbox-helper stub
    STUB=$(mktemp /tmp/sandbox-helper.XXXXXX)
    printf '#!/bin/sh\nexec "$@"\n' > "$STUB"
    debugfs -w "$EXT4_DEV" <<EOF 2>/dev/null
rm /usr/local/bin/sandbox-helper
write $STUB /usr/local/bin/sandbox-helper
set_inode_field /usr/local/bin/sandbox-helper mode 0100755
quit
EOF
    rm -f "$STUB"
    echo "  /usr/local/bin/sandbox-helper ✓ (stub)"
fi

# ── Step 6: Set hostname ──

echo "[6/10] Setting hostname..."

HFILE=$(mktemp /tmp/hostname.XXXXXX)
echo "claude" > "$HFILE"
debugfs -w "$EXT4_DEV" <<EOF 2>/dev/null
rm /etc/hostname
write $HFILE /etc/hostname
set_inode_field /etc/hostname mode 0100644
quit
EOF
rm -f "$HFILE"
echo "  /etc/hostname = claude ✓"

# ── Step 7: Install srt-settings.json + create /smol/bin ──

echo "[7/10] Enabling vsock kernel modules..."

VSOCK_CONF=$(mktemp /tmp/vsock-modules.XXXXXX)
printf 'vsock\nvirtio_vsock\nvhost_vsock\n' > "$VSOCK_CONF"
debugfs -w "$EXT4_DEV" <<EOF 2>/dev/null
mkdir /etc/modules-load.d
write $VSOCK_CONF /etc/modules-load.d/vsock.conf
set_inode_field /etc/modules-load.d/vsock.conf mode 0100644
quit
EOF
rm -f "$VSOCK_CONF"
echo "  /etc/modules-load.d/vsock.conf ✓"

echo "[8/10] Patching GRUB for virtio console (console=hvc0)..."

# Ubuntu cloud images use console=ttyAMA0 (PL011 UART) which doesn't exist under
# Apple's Virtualization.framework. We need console=hvc0 (virtio console) so that:
#   1. Kernel boot messages appear on the host serial pipe
#   2. The kernel doesn't hang waiting for a nonexistent UART device
GRUB_CFG=$(mktemp /tmp/grub.cfg.XXXXXX)
debugfs -R 'cat /boot/grub/grub.cfg' "$EXT4_DEV" 2>/dev/null > "$GRUB_CFG"
if [[ -s "$GRUB_CFG" ]]; then
    # Replace ttyAMA0/ttyS0 with hvc0, remove "quiet splash" so boot messages are visible
    sed -i.bak \
        -e 's/console=ttyAMA0/console=hvc0/g' \
        -e 's/console=ttyS0/console=hvc0/g' \
        -e 's/quiet splash//g' \
        "$GRUB_CFG"
    debugfs -w "$EXT4_DEV" <<EOF 2>/dev/null
rm /boot/grub/grub.cfg
write $GRUB_CFG /boot/grub/grub.cfg
set_inode_field /boot/grub/grub.cfg mode 0100644
quit
EOF
    echo "  /boot/grub/grub.cfg patched (console=hvc0) ✓"
else
    echo "  Warning: could not read /boot/grub/grub.cfg"
fi
rm -f "$GRUB_CFG" "${GRUB_CFG}.bak"

echo "[9/10] Disabling cloud-init (speeds up first boot by ~2 min)..."

# cloud-init on Ubuntu cloud images tries to find a metadata service on first boot,
# which times out and delays startup significantly inside a bare VM.
CLOUD_DISABLE=$(mktemp /tmp/cloud-init-disabled.XXXXXX)
touch "$CLOUD_DISABLE"
debugfs -w "$EXT4_DEV" <<EOF 2>/dev/null
mkdir /etc/cloud
write $CLOUD_DISABLE /etc/cloud/cloud-init.disabled
set_inode_field /etc/cloud/cloud-init.disabled mode 0100644
quit
EOF
rm -f "$CLOUD_DISABLE"
echo "  /etc/cloud/cloud-init.disabled ✓"

echo "[10/10] Installing srt-settings.json..."

SRT="$SCRIPT_DIR/daemon/srt-settings.json"
if [[ -f "$SRT" ]]; then
    debugfs -w "$EXT4_DEV" <<EOF 2>/dev/null
mkdir /smol
mkdir /smol/bin
write $SRT /smol/bin/srt-settings.json
set_inode_field /smol/bin/srt-settings.json mode 0100644
quit
EOF
    echo "  /smol/bin/srt-settings.json ✓"
else
    echo "  Skipped (daemon/srt-settings.json not found)"
fi

# ── Done ──

trap - EXIT
hdiutil detach "$DEVICE" 2>/dev/null || true

echo ""
echo "=== Done ==="
echo ""
echo "Output: $OUTPUT ($(ls -lh "$OUTPUT" | awk '{print $5}') sparse)"
echo ""
echo "Usage:"
echo "  cp $OUTPUT bundle/rootfs.img"
echo "  node demo.mjs"
