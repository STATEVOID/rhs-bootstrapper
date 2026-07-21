#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 /path/to/image.raw.zst /path/to/image.raw.zst.sha256" >&2
  exit 64
fi

image_path="$1"
checksum_path="$2"

if [ ! -f "$image_path" ] || [ ! -f "$checksum_path" ]; then
  echo "image and checksum files are required" >&2
  exit 66
fi

for cmd in awk blkid cmp find fsck.fat grep head losetup lsblk mount mountpoint python3 sed sha256sum tr umount zstd; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "required command not found: $cmd" >&2
    exit 69
  fi
done

work_dir="$(mktemp -d)"
raw_image="$work_dir/image.raw"
fat_mount="$work_dir/fat"
linux_boot_mount="$work_dir/linux-boot"
root_mount="$work_dir/root"
loop_dev=""

cleanup() {
  set +e
  for mount_dir in "$root_mount" "$linux_boot_mount" "$fat_mount"; do
    if mountpoint -q "$mount_dir"; then
      sudo umount "$mount_dir"
    fi
  done
  if [ -n "$loop_dev" ]; then
    sudo losetup -d "$loop_dev"
  fi
  rm -rf "$work_dir"
}
trap cleanup EXIT

mkdir -p "$fat_mount" "$linux_boot_mount" "$root_mount"
checksum_dir="$(cd "$(dirname "$checksum_path")" && pwd)"
checksum_name="$(basename "$checksum_path")"
(cd "$checksum_dir" && sha256sum -c "$checksum_name")
zstd -t "$image_path"
zstd -dc "$image_path" > "$raw_image"

python3 - "$raw_image" <<'PY'
import struct
import sys

path = sys.argv[1]
with open(path, "rb") as image:
    header = image.read(1024 * 1024)

if header[510:512] != b"\x55\xaa":
    raise SystemExit("missing protective MBR signature")

mbr_entries = []
for index in range(4):
    entry = header[446 + index * 16:446 + (index + 1) * 16]
    part_type = entry[4]
    first_lba, sectors = struct.unpack_from("<II", entry, 8)
    if part_type or first_lba or sectors:
        mbr_entries.append((index + 1, part_type, first_lba, sectors))

if len(mbr_entries) != 1 or mbr_entries[0][0:3] != (1, 0xEE, 1):
    raise SystemExit(f"hybrid or invalid MBR detected: {mbr_entries}")

if header[512:520] != b"EFI PART":
    raise SystemExit("missing primary GPT header")

entry_lba = struct.unpack_from("<Q", header, 512 + 72)[0]
entry_count = struct.unpack_from("<I", header, 512 + 80)[0]
entry_size = struct.unpack_from("<I", header, 512 + 84)[0]
entries_offset = entry_lba * 512
partitions = []
for index in range(entry_count):
    start = entries_offset + index * entry_size
    entry = header[start:start + entry_size]
    if len(entry) < entry_size:
        raise SystemExit("GPT entries do not fit in the image header")
    if entry[:16] != b"\x00" * 16:
        first_lba = struct.unpack_from("<Q", entry, 32)[0]
        last_lba = struct.unpack_from("<Q", entry, 40)[0]
        partitions.append((index + 1, first_lba, last_lba))

if len(partitions) != 3 or [part[0] for part in partitions] != [1, 2, 3]:
    raise SystemExit(f"expected GPT partitions 1, 2, and 3: {partitions}")
PY

loop_dev="$(sudo losetup --find --show --partscan "$raw_image")"
sleep 2
mapfile -t partitions < <(lsblk -nrpo PATH,TYPE "$loop_dev" | awk '$2 == "part" { print $1 }')
if [ "${#partitions[@]}" -ne 3 ]; then
  echo "expected exactly three attached partitions" >&2
  exit 1
fi

fat_part="${partitions[0]}"
linux_boot_part="${partitions[1]}"
root_part="${partitions[2]}"

fat_type="$(sudo blkid -o value -s TYPE "$fat_part" 2>/dev/null || true)"
linux_boot_type="$(sudo blkid -o value -s TYPE "$linux_boot_part" 2>/dev/null || true)"
root_type="$(sudo blkid -o value -s TYPE "$root_part" 2>/dev/null || true)"
[[ "$fat_type" =~ ^(vfat|fat|fat16|fat32|msdos)$ ]] || { echo "GPT partition 1 is not FAT" >&2; exit 1; }
[ "$linux_boot_type" = xfs ] || { echo "GPT partition 2 is not XFS /boot" >&2; exit 1; }
[ "$root_type" = xfs ] || { echo "GPT partition 3 is not XFS root" >&2; exit 1; }

sudo fsck.fat -n "$fat_part"
sudo mount -o ro "$fat_part" "$fat_mount"
sudo mount -o ro,nouuid "$linux_boot_part" "$linux_boot_mount"
sudo mount -o ro,nouuid "$root_part" "$root_mount"

require_nonempty_file() {
  local root="$1"
  local relative="$2"
  if ! sudo test -s "$root/$relative"; then
    echo "missing or empty required file: $relative" >&2
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
  require_nonempty_file "$fat_mount" "$relative"
done

grep -Eq '^[[:space:]]*include[[:space:]]+config-bootc-default\.txt[[:space:]]*$' "$fat_mount/config.txt"
grep -Eq '^[[:space:]]*include[[:space:]]+config-bootc-fallback\.txt[[:space:]]*$' "$fat_mount/config.txt"
grep -Eq '^[[:space:]]*kernel=vmlinuz[[:space:]]*$' "$fat_mount/config.txt"
grep -Eq '^[[:space:]]*initramfs[[:space:]]+initrd[[:space:]]+followkernel[[:space:]]*$' "$fat_mount/config.txt"
grep -Eq '^[[:space:]]*enable_uart=1[[:space:]]*$' "$fat_mount/config-bootc-common.txt"
grep -Eq '^[[:space:]]*uart_2ndstage=1[[:space:]]*$' "$fat_mount/config-bootc-common.txt"

entry_count=0
while IFS= read -r -d '' entry_dir; do
  entry_count=$((entry_count + 1))
  relative="${entry_dir#"$fat_mount/"}"
  for entry_file in vmlinuz initrd cmdline.txt bcm2711-rpi-4-b.dtb; do
    require_nonempty_file "$fat_mount" "$relative/$entry_file"
  done
  if ! sudo find "$entry_dir/overlays" -type f -name '*.dtbo' -print -quit 2>/dev/null | grep -q .; then
    echo "missing overlays in $relative" >&2
    exit 1
  fi
done < <(sudo find "$fat_mount/bootc/entries" -mindepth 1 -maxdepth 1 -type d -name 'ostree-*' -print0 2>/dev/null)
[ "$entry_count" -gt 0 ] || { echo "no synchronized bootc entries found" >&2; exit 1; }

prefix_count=0
while IFS= read -r prefix; do
  prefix="${prefix%$'\r'}"
  prefix="${prefix#/}"
  prefix="${prefix%/}"
  [ -n "$prefix" ] || continue
  prefix_count=$((prefix_count + 1))
  if [[ "$prefix" == *..* ]] || [[ "$prefix" != bootc/entries/ostree-* ]] || ! sudo test -d "$fat_mount/$prefix"; then
    echo "invalid os_prefix: $prefix" >&2
    exit 1
  fi
done < <(grep -hE '^[[:space:]]*os_prefix=' \
  "$fat_mount/config-bootc-default.txt" \
  "$fat_mount/config-bootc-fallback.txt" \
  "$fat_mount/tryboot.txt" 2>/dev/null | sed -E 's/^[[:space:]]*os_prefix=//')
[ "$prefix_count" -gt 0 ] || { echo "no os_prefix selects a bootc entry" >&2; exit 1; }

bls_count=0
while IFS= read -r -d '' bls_entry; do
  bls_count=$((bls_count + 1))
  bls_name="$(basename "$bls_entry")"
  slot="$(printf '%s' "$bls_name" | sed -nE 's/^ostree-([0-9]+).*/\1/p')"
  [ -n "$slot" ] || { echo "cannot map BLS entry $bls_name" >&2; exit 1; }
  fat_entry="$fat_mount/bootc/entries/ostree-$slot"
  sudo test -d "$fat_entry" || { echo "missing FAT entry for $bls_name" >&2; exit 1; }

  linux_path="$(sudo awk '$1 == "linux" { print $2; exit }' "$bls_entry")"
  initrd_path="$(sudo awk '$1 == "initrd" { print $2; exit }' "$bls_entry")"
  options="$(sudo sed -nE 's/^options[[:space:]]+//p' "$bls_entry" | head -n 1)"
  linux_path="${linux_path#/boot/}"
  linux_path="${linux_path#/}"
  initrd_path="${initrd_path#/boot/}"
  initrd_path="${initrd_path#/}"

  require_nonempty_file "$linux_boot_mount" "$linux_path"
  require_nonempty_file "$linux_boot_mount" "$initrd_path"
  sudo cmp -s "$linux_boot_mount/$linux_path" "$fat_entry/vmlinuz" || { echo "FAT kernel differs from $bls_name" >&2; exit 1; }
  sudo cmp -s "$linux_boot_mount/$initrd_path" "$fat_entry/initrd" || { echo "FAT initrd differs from $bls_name" >&2; exit 1; }
  fat_options="$(sudo tr -d '\r\n' < "$fat_entry/cmdline.txt")"
  [ "$fat_options" = "$options" ] || { echo "FAT cmdline differs from $bls_name" >&2; exit 1; }
done < <(sudo find "$linux_boot_mount/loader/entries" -maxdepth 1 -type f -name 'ostree-*.conf' -print0 2>/dev/null)
[ "$bls_count" -gt 0 ] || { echo "no active OSTree BLS entries found on /boot" >&2; exit 1; }

if ! sudo find "$root_mount" -path '*/usr/bin/rpi-bootc-bootloader' -type f -print -quit | grep -q .; then
  echo "root deployment lacks rpi-bootc-bootloader" >&2
  exit 1
fi
if ! sudo find "$root_mount" -path '*/usr/lib/systemd/system/ostree-finalize-staged.service.d/rpi-bootc-bootloader.conf' -type f -print -quit | grep -q .; then
  echo "root deployment lacks the bootloader finalization hook" >&2
  exit 1
fi

echo "Compressed Raspberry Pi 4 direct-boot artifact smoke check passed."
