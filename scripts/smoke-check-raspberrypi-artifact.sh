#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 /path/to/image.raw.zst /path/to/image.raw.zst.sha256" >&2
  exit 64
fi

image_path="$1"
checksum_path="$2"

if [ ! -f "$image_path" ]; then
  echo "image not found: $image_path" >&2
  exit 66
fi

if [ ! -f "$checksum_path" ]; then
  echo "checksum not found: $checksum_path" >&2
  exit 66
fi

for cmd in zstd sha256sum python3 fsck.fat mdir dd; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "required command not found: $cmd" >&2
    exit 69
  fi
done

work_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

checksum_dir="$(cd "$(dirname "$checksum_path")" && pwd)"
checksum_name="$(basename "$checksum_path")"
(cd "$checksum_dir" && sha256sum -c "$checksum_name")
zstd -t "$image_path"

header_path="$work_dir/header.bin"
set +e
zstd -dc "$image_path" 2>"$work_dir/zstd-header.err" \
  | dd of="$header_path" bs=1M count=1 status=none
dd_status=${PIPESTATUS[1]}
set -e
if [ "$dd_status" -ne 0 ]; then
  echo "failed to extract GPT header from compressed image" >&2
  cat "$work_dir/zstd-header.err" >&2
  exit 1
fi

read -r first_lba sector_count < <(python3 - "$header_path" <<'PY'
import struct
import sys

header_path = sys.argv[1]
with open(header_path, "rb") as f:
    data = f.read()

if data[512:520] != b"EFI PART":
    raise SystemExit("missing GPT header")

entry_lba = struct.unpack_from("<Q", data, 512 + 72)[0]
entry_count = struct.unpack_from("<I", data, 512 + 80)[0]
entry_size = struct.unpack_from("<I", data, 512 + 84)[0]
entries_offset = entry_lba * 512

for index in range(entry_count):
    start = entries_offset + index * entry_size
    entry = data[start:start + entry_size]
    if len(entry) < 56:
        break
    if entry[:16] == b"\x00" * 16:
        continue
    first_lba = struct.unpack_from("<Q", entry, 32)[0]
    last_lba = struct.unpack_from("<Q", entry, 40)[0]
    print(first_lba, last_lba - first_lba + 1)
    break
else:
    raise SystemExit("no GPT partitions found")
PY
)

boot_img="$work_dir/boot.img"
set +e
zstd -dc "$image_path" 2>"$work_dir/zstd-boot.err" \
  | dd of="$boot_img" bs=512 skip="$first_lba" count="$sector_count" status=none
dd_status=${PIPESTATUS[1]}
set -e
if [ "$dd_status" -ne 0 ]; then
  echo "failed to extract FAT boot partition from compressed image" >&2
  cat "$work_dir/zstd-boot.err" >&2
  exit 1
fi

fsck.fat -n "$boot_img"

require_file() {
  local path="$1"
  if ! mdir -i "$boot_img" "::/$path" >/dev/null 2>&1; then
    echo "missing required Pi boot file: $path" >&2
    exit 1
  fi
}

require_glob() {
  local pattern="$1"
  if ! mdir -i "$boot_img" "::/$pattern" >/dev/null 2>&1; then
    echo "missing required Pi boot asset pattern: $pattern" >&2
    exit 1
  fi
}

require_file "config.txt"
require_file "u-boot.bin"
require_file "EFI/BOOT/BOOTAA64.EFI"
require_glob "start*.elf"
require_glob "fixup*.dat"
require_glob "overlays/*.dtbo"

echo "Compressed Raspberry Pi arm64 artifact smoke check passed."
