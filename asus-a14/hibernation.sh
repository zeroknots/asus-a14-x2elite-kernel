#!/usr/bin/env bash
# Usage:
#   hibernation.sh check            readiness report (root adds the swapfile offset)
#   sudo hibernation.sh test        in-memory test: write the image to the swapfile
#                                   and restore it without powering off (test_resume)
#   sudo hibernation.sh enable  RELEASE   add the resume hook and resume= to one entry
#   sudo hibernation.sh disable RELEASE   remove resume= from that entry again
#
# Assumes the Omarchy Snapdragon layout: encrypted btrfs root (/dev/mapper/root)
# with a swapfile. Only the named test entry changes; the default entry and all
# other entries are verified unchanged. Booting any entry without resume= after
# a hibernation discards the image (swapon rewrites the swap signature), so the
# worst case of picking the wrong entry is a lost session, not a resumed stale one.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
swapfile=${A14_SWAPFILE:-/swap/swapfile}
grub=${A14_GRUB_CFG:-/boot/oma-snap/grub/grub.cfg}
entries=${A14_ENTRIES:-/boot/oma-snap/entries}

need_root() { [[ $EUID == 0 ]] || die 'root is required'; }
kib() { awk -v k="$1" '$1 == k":" { print $2 }' /proc/meminfo; }

swap_device() {
  local source
  source=$(findmnt -no SOURCE -T "$(dirname -- "$swapfile")" | sed 's/\[.*//')
  [[ -b $source ]] || die "cannot find the block device holding $swapfile"
  echo "$source"
}
swap_offset() {
  [[ $(findmnt -no FSTYPE -T "$(dirname -- "$swapfile")") == btrfs ]] || die "$swapfile is not on btrfs"
  btrfs inspect-internal map-swapfile -r "$swapfile"
}
swap_active() { awk -v f="$swapfile" '$1 == f { found = 1 } END { exit !found }' /proc/swaps; }
# Free space on the swapfile in KiB.
swap_free_kib() { awk -v f="$swapfile" '$1 == f { print $3 - $4 }' /proc/swaps; }
# Rough upper bound of the image: memory in use (the kernel compresses and may
# shrink it, but we require the uncompressed size to be safe).
used_kib() { echo $(( $(kib MemTotal) - $(kib MemAvailable) )); }

check() {
  local ok=1
  echo "kernel:        $(uname -r)"
  if grep -q '\bdisk\b' /sys/power/state; then echo 'hibernation:   supported by the kernel'; else echo 'hibernation:   NOT supported by the kernel'; ok=0; fi
  echo "disk modes:    $(cat /sys/power/disk)"
  if [[ -r /sys/kernel/security/lockdown ]]; then echo "lockdown:      $(cat /sys/kernel/security/lockdown)"; fi
  if swap_active; then
    echo "swapfile:      $swapfile active, $(( $(swap_free_kib) / 1048576 )) GiB free"
  else
    echo "swapfile:      $swapfile NOT active"; ok=0
  fi
  echo "memory in use: $(( $(used_kib) / 1048576 )) GiB (image must fit in the swapfile)"
  (( $(swap_free_kib 2>/dev/null || echo 0) > $(used_kib) )) || { echo '               swapfile free space is below memory in use'; ok=0; }
  local device
  if device=$(swap_device 2>&1); then echo "resume device: $device"; else echo "resume device: NOT FOUND ($device)"; ok=0; fi
  if [[ $EUID == 0 ]]; then echo "resume_offset: $(swap_offset)"; else echo 'resume_offset: (run as root to compute)'; fi
  if grep -qw 'resume=[^ ]*' /proc/cmdline; then
    echo "boot cmdline:  $(grep -o 'resume[_a-z]*=[^ ]*' /proc/cmdline | tr '\n' ' ')"
  else
    echo 'boot cmdline:  no resume= (a real hibernation would not be resumed; "test" works anyway)'
  fi
  echo "runtime:       /sys/power/resume=$(cat /sys/power/resume) resume_offset=$(cat /sys/power/resume_offset)"
  (( ok )) && echo 'READY for "test"' || { echo 'NOT READY'; return 1; }
}

test_resume() {
  need_root
  check >/dev/null || { check; die 'not ready'; }
  local device majmin offset old_disk old_resume old_offset since rc=0
  device=$(swap_device)
  majmin=$(lsblk -dno MAJ:MIN "$device" | tr -d ' ')
  offset=$(swap_offset)
  [[ $majmin =~ ^[0-9]+:[0-9]+$ && $offset =~ ^[0-9]+$ ]] || die "bad resume device/offset: $majmin $offset"
  old_disk=$(sed -n 's/.*\[\([a-z_]*\)\].*/\1/p' /sys/power/disk)
  old_resume=$(cat /sys/power/resume); old_offset=$(cat /sys/power/resume_offset)
  echo "Writing a hibernation image to $swapfile ($device $majmin, offset $offset) and"
  echo 'restoring it without powering off. The screen goes dark for up to a minute.'
  echo 'If the machine hangs, hold the power button and boot normally: no entry has'
  echo 'resume= yet, so the image is discarded at the next swapon.'
  since=$(date '+%Y-%m-%d %H:%M:%S')
  echo "$offset" > /sys/power/resume_offset
  echo "$majmin" > /sys/power/resume
  echo test_resume > /sys/power/disk
  sync
  echo disk > /sys/power/state || rc=$?
  echo "$old_disk" > /sys/power/disk
  # Restore the runtime resume target so a later hibernate uses the boot config.
  echo "$old_offset" > /sys/power/resume_offset
  echo "$old_resume" > /sys/power/resume 2>/dev/null || echo "WARNING: could not reset /sys/power/resume to $old_resume" >&2
  echo "Back. Kernel messages since $since:"
  journalctl -k --since "$since" --no-pager | grep -E 'PM: |hibernat|Image|restor|freez|thaw' | tail -40 || true
  (( rc == 0 )) || die "hibernation test returned error $rc"
  echo 'PASS: image written and restored. Check display, Wi-Fi, audio, Bluetooth and camera now.'
}

# Verify the default entry and every entry with a manifest, before and after edits.
snapshot_default() {
  local default_line
  default_line=$(sed -n '/^set default=oma-snap-/p' "$grub")
  [[ $(wc -l <<<"$default_line") == 1 && -n $default_line ]] || die 'expected one oma-snap-* default'
  default_entry=$entries/${default_line#set default=oma-snap-}
  (cd "$default_entry" && sha256sum entry.cfg vmlinuz.efi initramfs.img) > "$work/default.sha256"
  echo "$default_line" > "$work/default.line"
}
verify_entries() {
  local manifest
  (cd "$default_entry" && sha256sum --check --quiet "$work/default.sha256") || die 'default entry changed'
  [[ $(sed -n '/^set default=oma-snap-/p' "$grub") == "$(cat "$work/default.line")" ]] || die 'default changed'
  for manifest in "$entries"/*/SHA256SUMS; do
    [[ -e $manifest ]] || continue
    (cd "${manifest%/SHA256SUMS}" && sha256sum --check --quiet SHA256SUMS) || die "${manifest%/SHA256SUMS} fails its manifest"
  done
}

# block_count ENTRY_CFG: how often that exact block occurs in grub.cfg.
block_count() {
  python3 -c 'import sys; print(open(sys.argv[1]).read().count(open(sys.argv[2]).read()))' "$grub" "$1"
}

# rewrite_entry ENTRY_DIR NEW_ENTRY_CFG: replace the entry's block in grub.cfg
# (it must occur exactly once), install entry.cfg, refresh SHA256SUMS.
rewrite_entry() {
  local entry=$1 new_cfg=$2
  python3 - "$grub" "$entry/entry.cfg" "$new_cfg" "$work/grub.cfg" <<'PY'
import sys
grub, old, new, out = (open(p).read() if i < 3 else p for i, p in enumerate(sys.argv[1:]))
if grub.count(old) != 1:
    sys.exit(f"entry block occurs {grub.count(old)} times in grub.cfg")
open(out, "w").write(grub.replace(old, new))
PY
  grub-script-check "$work/grub.cfg"
  local backup; backup=$grub.before-hibernation-$(date +%Y%m%d-%H%M%S-%N)
  [[ ! -e $backup ]] || die "backup $backup exists"
  cp -p "$grub" "$backup"
  install -m644 "$new_cfg" "$entry/entry.cfg.new"
  mv "$entry/entry.cfg.new" "$entry/entry.cfg"
  install -m644 "$work/grub.cfg" "$grub.asus-a14-new"
  mv "$grub.asus-a14-new" "$grub"
  (cd "$entry" && sha256sum vmlinuz.efi "$dtb" initramfs.img config provenance.json entry.cfg > SHA256SUMS.new && mv SHA256SUMS.new SHA256SUMS)
}

enable() {
  need_root
  local tag=${1:?usage: hibernation.sh enable RELEASE} entry release device offset
  entry=$entries/oma-a14-$tag-test
  [[ -f $entry/entry.cfg ]] || die "no installed entry $entry"
  release=$(sed -n "s/^menuentry '.*(\(.*\))' --id .*/\1/p" "$entry/entry.cfg")
  [[ $release == *-zenbook-$tag && -d /usr/lib/modules/$release ]] || die "cannot determine the release of $entry"
  ! grep -q 'resume=' "$entry/entry.cfg" || die 'entry already has resume='
  swap_active || die "$swapfile is not active"
  device=$(swap_device); offset=$(swap_offset)
  [[ $device == /dev/mapper/root && $offset =~ ^[0-9]+$ ]] || die "unexpected resume device/offset: $device $offset"
  work=$(mktemp -d /var/tmp/asus-a14-hibernation.XXXXXXXX); trap 'rm -rf -- "$work"' EXIT
  (cd "$entry" && sha256sum --check --quiet SHA256SUMS) || die "$entry fails its manifest"
  snapshot_default; verify_entries
  build_initramfs "$release" "$work/initramfs.img" "$work" resume
  local need avail
  need=$(( $(stat -c %s "$work/initramfs.img") + 16777216 ))
  avail=$(df --output=avail -B1 /boot | tail -1)
  (( avail >= need )) || die "ESP needs $need bytes free for the new initramfs; $avail available"
  sed "/^  linux / s|\$| resume=$device resume_offset=$offset|" "$entry/entry.cfg" > "$work/entry.cfg"
  grep -q "resume=$device resume_offset=$offset" "$work/entry.cfg" || die 'could not add resume='
  # Refuse before touching the ESP if grub.cfg does not hold this entry exactly once.
  block_count "$entry/entry.cfg" | grep -qx 1 || die 'grub.cfg does not contain this entry.cfg block exactly once'
  cp -p "$entry/entry.cfg" "$entry/entry.cfg.before-hibernation"
  install -m644 "$work/initramfs.img" "$entry/initramfs.img.new"
  cmp -s "$work/initramfs.img" "$entry/initramfs.img.new" || die 'ESP copy of the initramfs differs'
  mv "$entry/initramfs.img.new" "$entry/initramfs.img"
  rewrite_entry "$entry" "$work/entry.cfg"
  (cd "$entry" && sha256sum --check --quiet SHA256SUMS)
  verify_entries
  echo "PASS: $entry now resumes from $device offset $offset (resume hook after encrypt)."
  echo 'Boot that entry, run "hibernation.sh check", then "systemctl hibernate".'
  echo 'After hibernating, pick the same entry at power-on; any other entry discards the image.'
}

disable() {
  need_root
  local tag=${1:?usage: hibernation.sh disable RELEASE} entry
  entry=$entries/oma-a14-$tag-test
  grep -q 'resume=' "$entry/entry.cfg" || die 'entry has no resume='
  work=$(mktemp -d /var/tmp/asus-a14-hibernation.XXXXXXXX); trap 'rm -rf -- "$work"' EXIT
  (cd "$entry" && sha256sum --check --quiet SHA256SUMS) || die "$entry fails its manifest"
  snapshot_default; verify_entries
  sed -E '/^  linux / s/ resume=[^ ]+ resume_offset=[0-9]+//' "$entry/entry.cfg" > "$work/entry.cfg"
  ! grep -q 'resume=' "$work/entry.cfg" || die 'could not remove resume='
  rewrite_entry "$entry" "$work/entry.cfg"
  verify_entries
  echo "PASS: resume= removed from $entry (its initramfs keeps the inert resume hook)."
}

# Allow sourcing for tests.
[[ ${BASH_SOURCE[0]} == "$0" ]] || return 0
case ${1:-} in
  check) check ;;
  test) test_resume ;;
  enable) enable "${2:-}" ;;
  disable) disable "${2:-}" ;;
  *) die 'usage: hibernation.sh check | test | enable RELEASE | disable RELEASE' ;;
esac
