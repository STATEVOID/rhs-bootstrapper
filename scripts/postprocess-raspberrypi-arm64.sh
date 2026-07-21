#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: $0 /path/to/disk.raw [bootc-container-image]" >&2
  exit 64
fi

image_path="$1"
container_image="${2:-localhost/rhs-bootstrapper:raspberrypi-arm64}"

if [ ! -f "$image_path" ]; then
  echo "image not found: $image_path" >&2
  exit 66
fi

for cmd in blkid losetup lsblk mount mountpoint podman python3 sfdisk umount; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "required command not found: $cmd" >&2
    exit 69
  fi
done

loop_dev=""
work_dir="$(mktemp -d)"
fat_mount="$work_dir/fat"

cleanup() {
  set +e
  if mountpoint -q "$fat_mount"; then
    sudo umount "$fat_mount"
  fi
  if [ -n "$loop_dev" ]; then
    sudo losetup -d "$loop_dev"
  fi
  rm -rf "$work_dir"
}
trap cleanup EXIT

mkdir -p "$fat_mount"
loop_dev="$(sudo losetup --find --show --partscan "$image_path")"
sleep 2

mapfile -t partitions < <(lsblk -nrpo PATH,TYPE "$loop_dev" | awk '$2 == "part" { print $1 }')
if [ "${#partitions[@]}" -ne 3 ]; then
  echo "expected exactly three GPT partitions, found ${#partitions[@]}" >&2
  exit 1
fi

fat_part="${partitions[0]}"
linux_boot_part="${partitions[1]}"
root_part="${partitions[2]}"

require_fs_type() {
  local device="$1"
  local expected="$2"
  local actual
  actual="$(sudo blkid -o value -s TYPE "$device" 2>/dev/null || true)"
  if [[ ! "$actual" =~ $expected ]]; then
    echo "unexpected filesystem on $device: ${actual:-unknown}" >&2
    exit 1
  fi
}

require_fs_type "$fat_part" '^(vfat|fat|fat16|fat32|msdos)$'
require_fs_type "$linux_boot_part" '^xfs$'
require_fs_type "$root_part" '^xfs$'

if [ "$(sudo sfdisk --json "$loop_dev" | python3 -c 'import json,sys; print(json.load(sys.stdin)["partitiontable"]["label"])')" != "gpt" ]; then
  echo "image must retain a GPT partition table" >&2
  exit 1
fi

echo "Synchronizing the active bootc deployment onto GPT partition 1"
sudo mount "$fat_part" "$fat_mount"
sudo podman run \
  --rm \
  --privileged \
  --platform linux/arm64 \
  --security-opt label=type:unconfined_t \
  -v /dev:/dev \
  -v "$fat_mount:/tmp" \
  --entrypoint /bin/bash \
  "$container_image" \
  -ceu "
    mount '$root_part' /sysroot
    mount '$linux_boot_part' /boot
    test -d /usr/lib/ostree-boot
    test -x /usr/bin/rpi-bootc-bootloader
    cp -a --no-preserve=links /usr/lib/ostree-boot/. /tmp/
    rpi-bootc-bootloader sync
  "

sudo tee "$fat_mount/config-bootc-common.txt" >/dev/null <<'EOF'
# Statevoid Raspberry Pi 4 boot options.
enable_uart=1
uart_2ndstage=1
EOF

# Direct boot entries replace the previous U-Boot and EFI chainloader path.
sudo rm -f "$fat_mount/kernel8.img" "$fat_mount/u-boot.bin"

require_nonempty_file() {
  local relative="$1"
  if [ ! -s "$fat_mount/$relative" ]; then
    echo "missing or empty Raspberry Pi boot file: $relative" >&2
    exit 1
  fi
}

for relative in \
  config.txt \
  config-bootc-common.txt \
  config-bootc-default.txt \
  config-bootc-fallback.txt \
  start4.elf \
  fixup4.dat; do
  require_nonempty_file "$relative"
done

if ! grep -Eq '^[[:space:]]*include[[:space:]]+config-bootc-default\.txt[[:space:]]*$' "$fat_mount/config.txt" \
  || ! grep -Eq '^[[:space:]]*include[[:space:]]+config-bootc-fallback\.txt[[:space:]]*$' "$fat_mount/config.txt" \
  || ! grep -Eq '^[[:space:]]*kernel=vmlinuz[[:space:]]*$' "$fat_mount/config.txt" \
  || ! grep -Eq '^[[:space:]]*initramfs[[:space:]]+initrd[[:space:]]+followkernel[[:space:]]*$' "$fat_mount/config.txt"; then
  echo "config.txt does not select the bootc deployment kernel and initramfs" >&2
  exit 1
fi

grep -Eq '^[[:space:]]*enable_uart=1[[:space:]]*$' "$fat_mount/config-bootc-common.txt"
grep -Eq '^[[:space:]]*uart_2ndstage=1[[:space:]]*$' "$fat_mount/config-bootc-common.txt"

entry_count=0
while IFS= read -r -d '' entry_dir; do
  entry_count=$((entry_count + 1))
  relative="${entry_dir#"$fat_mount/"}"
  for entry_file in vmlinuz initrd cmdline.txt bcm2711-rpi-4-b.dtb; do
    require_nonempty_file "$relative/$entry_file"
  done
  if ! sudo find "$entry_dir/overlays" -type f -name '*.dtbo' -print -quit 2>/dev/null | grep -q .; then
    echo "missing Raspberry Pi overlays in $relative/overlays" >&2
    exit 1
  fi
done < <(sudo find "$fat_mount/bootc/entries" -mindepth 1 -maxdepth 1 -type d -name 'ostree-*' -print0 2>/dev/null)

if [ "$entry_count" -eq 0 ]; then
  echo "no synchronized bootc deployment entries found" >&2
  exit 1
fi

prefix_count=0
while IFS= read -r prefix; do
  prefix="${prefix%$'\r'}"
  prefix="${prefix#/}"
  prefix="${prefix%/}"
  [ -n "$prefix" ] || continue
  prefix_count=$((prefix_count + 1))
  if [[ "$prefix" == *..* ]] || [[ "$prefix" != bootc/entries/ostree-* ]] || [ ! -d "$fat_mount/$prefix" ]; then
    echo "os_prefix resolves outside a synchronized deployment: $prefix" >&2
    exit 1
  fi
done < <(grep -hE '^[[:space:]]*os_prefix=' \
  "$fat_mount/config-bootc-default.txt" \
  "$fat_mount/config-bootc-fallback.txt" \
  "$fat_mount/tryboot.txt" 2>/dev/null | sed -E 's/^[[:space:]]*os_prefix=//')

if [ "$prefix_count" -eq 0 ]; then
  echo "no os_prefix selects a synchronized bootc deployment" >&2
  exit 1
fi

sudo sync
echo "Raspberry Pi 4 direct-boot assets synchronized and validated."
