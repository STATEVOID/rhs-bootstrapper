#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 /path/to/disk.raw" >&2
  exit 64
fi

image_path="$1"
if [ ! -f "$image_path" ]; then
  echo "image not found: $image_path" >&2
  exit 66
fi

loop_dev=""
work_dir="$(mktemp -d)"
boot_mount="$work_dir/boot"
root_mount="$work_dir/root"

cleanup() {
  set +e
  if mountpoint -q "$boot_mount"; then
    sudo umount "$boot_mount"
  fi
  if mountpoint -q "$root_mount"; then
    sudo umount "$root_mount"
  fi
  if [ -n "$loop_dev" ]; then
    sudo losetup -d "$loop_dev"
  fi
  rm -rf "$work_dir"
}
trap cleanup EXIT

mkdir -p "$boot_mount" "$root_mount"

loop_dev="$(sudo losetup --find --show --partscan "$image_path")"
sleep 2
sudo partprobe "$loop_dev" || true

echo "Partition table for $image_path:"
sudo sfdisk --dump "$loop_dev"

find_esp_partition() {
  local part
  part="$(lsblk -bnrpo PATH,PARTTYPE,FSTYPE "$loop_dev" | awk '
    tolower($2) == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" { print $1; exit }
    $3 ~ /^(vfat|fat16|fat32)$/ { print $1; exit }
  ')"

  if [ -z "$part" ]; then
    for candidate in "${loop_dev}"p*; do
      [ -b "$candidate" ] || continue
      fs_type="$(sudo blkid -o value -s TYPE "$candidate" 2>/dev/null || true)"
      case "$fs_type" in
        vfat|fat|fat16|fat32|msdos)
          part="$candidate"
          break
          ;;
      esac
    done
  fi

  printf '%s\n' "$part"
}

find_root_partition() {
  local part
  part="$(lsblk -bnrpo PATH,PARTTYPE,FSTYPE,SIZE "$loop_dev" | awk '
    $3 ~ /^(xfs|ext4|btrfs)$/ && $4 > largest { largest = $4; path = $1 }
    END { if (path != "") print path }
  ')"

  if [ -z "$part" ]; then
    part="$(lsblk -bnrpo PATH,PARTTYPE,SIZE "$loop_dev" | awk '
      tolower($2) == "0fc63daf-8483-4772-8e79-3d69d8477de4" && $3 > largest { largest = $3; path = $1 }
      END { if (path != "") print path }
    ')"
  fi

  printf '%s\n' "$part"
}

boot_part="$(find_esp_partition)"
root_part="$(find_root_partition)"

if [ -z "$boot_part" ]; then
  echo "could not find a FAT boot/ESP partition in $image_path" >&2
  exit 1
fi

if [ -z "$root_part" ]; then
  echo "could not find a mountable Linux root partition in $image_path" >&2
  exit 1
fi

sudo mount "$boot_part" "$boot_mount"
sudo mount -o ro "$root_part" "$root_mount"

find_first_file() {
  local name="$1"
  sudo find "$root_mount" -type f -name "$name" -print -quit
}

firmware_start="$(find_first_file start4.elf)"
if [ -z "$firmware_start" ]; then
  echo "could not locate Fedora Raspberry Pi firmware files in the root filesystem" >&2
  exit 1
fi
firmware_dir="$(dirname "$firmware_start")"

echo "Copying Raspberry Pi firmware from $firmware_dir"
sudo cp -a "$firmware_dir"/bootcode.bin "$boot_mount"/ 2>/dev/null || true
sudo cp -a "$firmware_dir"/start*.elf "$boot_mount"/
sudo cp -a "$firmware_dir"/fixup*.dat "$boot_mount"/

overlay_dir=""
if [ -d "$firmware_dir/overlays" ]; then
  overlay_dir="$firmware_dir/overlays"
else
  overlay_dir="$(sudo find "$root_mount" -type d -path '*/overlays' -print -quit)"
fi

if [ -z "$overlay_dir" ] || [ ! -d "$overlay_dir" ]; then
  echo "could not locate Raspberry Pi device-tree overlays" >&2
  exit 1
fi

sudo mkdir -p "$boot_mount/overlays"
sudo cp -a "$overlay_dir"/. "$boot_mount/overlays"/

uboot_bin=""
for pattern in \
  '*/usr/share/uboot/rpi_arm64/u-boot.bin' \
  '*/usr/share/uboot/rpi_4/u-boot.bin' \
  '*/usr/share/uboot/rpi_3/u-boot.bin' \
  '*/usr/share/uboot/*/u-boot.bin'
do
  uboot_bin="$(sudo find "$root_mount" -type f -path "$pattern" -print -quit)"
  if [ -n "$uboot_bin" ]; then
    break
  fi
done

if [ -z "$uboot_bin" ]; then
  echo "could not locate Fedora U-Boot binary for Raspberry Pi arm64" >&2
  exit 1
fi

echo "Copying U-Boot from $uboot_bin"
sudo cp -a "$uboot_bin" "$boot_mount/u-boot.bin"

sudo tee "$boot_mount/config.txt" >/dev/null <<'EOF'
arm_64bit=1
enable_uart=1
kernel=u-boot.bin
disable_commandline_tags=2
device_tree_address=0x03000000
dtoverlay=vc4-kms-v3d
EOF

if [ ! -f "$boot_mount/EFI/BOOT/BOOTAA64.EFI" ]; then
  bootaa64="$(sudo find "$root_mount" -type f \( -iname BOOTAA64.EFI -o -iname shimaa64.efi -o -iname grubaa64.efi \) -print -quit)"
  if [ -n "$bootaa64" ]; then
    sudo mkdir -p "$boot_mount/EFI/BOOT"
    sudo cp -a "$bootaa64" "$boot_mount/EFI/BOOT/BOOTAA64.EFI"
  fi
fi

require_file() {
  local rel_path="$1"
  if [ ! -f "$boot_mount/$rel_path" ]; then
    echo "missing required Pi boot file: $rel_path" >&2
    exit 1
  fi
}

require_dir() {
  local rel_path="$1"
  if [ ! -d "$boot_mount/$rel_path" ]; then
    echo "missing required Pi boot directory: $rel_path" >&2
    exit 1
  fi
}

require_file "config.txt"
require_file "u-boot.bin"
require_file "EFI/BOOT/BOOTAA64.EFI"
require_dir "overlays"

if ! compgen -G "$boot_mount/start*.elf" >/dev/null; then
  echo "missing required Raspberry Pi start*.elf firmware" >&2
  exit 1
fi

if ! compgen -G "$boot_mount/fixup*.dat" >/dev/null; then
  echo "missing required Raspberry Pi fixup*.dat firmware" >&2
  exit 1
fi

if ! sudo find "$boot_mount/overlays" -type f -name '*.dtbo' -print -quit | grep -q .; then
  echo "missing Raspberry Pi overlay .dtbo files" >&2
  exit 1
fi

sudo sync
echo "Raspberry Pi arm64 boot assets validated."
