#!/bin/bash
# Runs INSIDE a built PowOS image (CI, right after the image is pushed): writes what the phone build needs to
# derive the same OS on Arch Linux ARM, so nothing about PowOS's content is maintained twice.
#   $1 = output dir     $2 = phone-rules.conf (from the same repo checkout)
# Output (a few MB):
#   packages.tsv   every RPM: NAME<TAB>ARCH
#   leaves.tsv     the top-level RPMs (nothing requires them): the phone maps these to Arch packages via the rules
#   flatpaks.txt   the image's first-boot Flatpak list(s)
#   content.tar.zst  architecture-independent files no RPM owns (PowOS's layer, Bazzite's system_files,
#                  Containerfile drops) + files of the content-only packages the rules say to bundle
#   content.list   the paths in content.tar.zst
#   index.tsv      what the image offers a user (commands, apps, autostart, enabled units) and who provides it
set -euo pipefail
out=$1 rules=$2
mkdir -p "$out"

rpm -qa --qf '%{NAME}\t%{ARCH}\n' | sort -u > "$out/packages.tsv"
# Top level: packages nothing else installed requires. These are what the phone maps (Arch pulls in
# their dependencies itself); packages.tsv stays for reference and for "bundle" lookups.
dnf5 repoquery --installed --leaves --qf '%{name}|%{arch}\n' 2>/dev/null | tr '|' '\t' | sort -u > "$out/leaves.tsv" \
  || cp "$out/packages.tsv" "$out/leaves.tsv"

: > "$out/flatpaks.txt"
find /usr/share/ublue-os -path '*/flatpak/install' -type f 2>/dev/null | while read -r f; do
  echo "# $f" >> "$out/flatpaks.txt"; cat "$f" >> "$out/flatpaks.txt"
done

# Files no package owns, in the places PowOS/Bazzite put content; generated caches and machine state left out.
rpm -qa --qf '[%{FILENAMES}\n]' | sort -u > /tmp/owned
# Everywhere the image keeps files: PowOS's and Bazzite's own live all over /usr/lib too (systemd units, udev
# rules, tmpfiles/sysusers, environment.d...), not only in /usr/lib/powos. /usr/lib64 is x86 libraries.
find /etc /usr/share /usr/lib /usr/bin /usr/sbin /usr/libexec /usr/local /opt \( -type f -o -type l \) 2>/dev/null \
  | grep -vE '^/usr/lib/(modules|firmware|sysimage|ostree-boot|debug|locale/locale-archive|fontconfig/cache)(/|$)' \
  | sort -u > /tmp/all
# ^ generated or machine state: kernel modules + initramfs, firmware, the RPM database, boot files, caches.
comm -23 /tmp/all /tmp/owned \
  | grep -vE '^/etc/(machine-id|hostname|shadow|gshadow|passwd|group|subuid|subgid|ld\.so\.cache|pki|selinux|ssh/ssh_host_|fstab|resolv\.conf|yum\.repos\.d|dnf|rpm|ostree|containers/storage)' \
  | grep -vE '^/usr/share/(mime/[^/]+$|icons/[^/]+/icon-theme\.cache|fonts/.*\.uuid|applications/mimeinfo\.cache|glib-2\.0/schemas/gschemas\.compiled)' \
  | grep -vE '^/usr/share/rpm/' \
  > /tmp/unowned
# ^ Fedora's package database: machine state like /etc/rpm, not PowOS content (the phone has pacman's).

# Content-only packages the phone takes as files (rules: "bundle <rpm-name>").
for p in $(awk '$1 == "bundle" {print $2}' "$rules"); do
  rpm -ql "$p" 2>/dev/null | grep -v '^(contains no files)' || echo "emit-manifest: bundle $p is not installed" >&2
done >> /tmp/unowned

# Architecture-independent only: ELF files can't run on the phone (they come from Arch packages instead).
: > "$out/content.list"
sort -u /tmp/unowned | while read -r f; do
  [ -L "$f" ] || [ -f "$f" ] || continue
  if [ -f "$f" ] && [ ! -L "$f" ] && [ "$(head -c 4 "$f" 2>/dev/null | od -An -c | tr -d ' ')" = '177ELF' ]; then continue; fi
  echo "${f#/}" >> "$out/content.list"
done
tar -C / --no-recursion --hard-dereference -cf - -T "$out/content.list" | zstd -q -19 -o "$out/content.tar.zst"

# What the image offers a user, for the phone's parity check (tools/phone-parity.py): KIND<TAB>NAME<TAB>OWNER.
# OWNER is the RPM, or "image" for files no package owns (PowOS's layer). Units are the ENABLED ones: what
# actually runs on a booted PowOS, system-wide and per user.
rpm -qa --qf '[%{FILENAMES}\t%{=NAME}\n]' > /tmp/owners
unit_file() { ls "$@" 2>/dev/null | head -1; }
{ # KIND<TAB>NAME<TAB>PATH
  # /usr/sbin is a symlink to bin on current Fedora: only list it when it is a real directory.
  sbin=; [ -L /usr/sbin ] || sbin=/usr/sbin
  for f in /usr/bin/* ${sbin:+$sbin/*}; do { [ -e "$f" ] || [ -L "$f" ]; } && printf 'bin\t%s\t%s\n' "${f##*/}" "$f"; done
  for f in /usr/share/applications/*.desktop; do
    grep -q '^NoDisplay=true' "$f" 2>/dev/null || printf 'app\t%s\t%s\n' "${f##*/}" "$f"
  done
  for f in /etc/xdg/autostart/*.desktop; do printf 'autostart\t%s\t%s\n' "${f##*/}" "$f"; done
  systemctl list-unit-files --state=enabled --no-legend 2>/dev/null | awk '{print $1}' | while read -r u; do
    printf 'unit\t%s\t%s\n' "$u" "$(unit_file /etc/systemd/system/"$u" /usr/lib/systemd/system/"$u")"; done
  systemctl --global list-unit-files --state=enabled --no-legend 2>/dev/null | awk '{print $1}' | while read -r u; do
    printf 'user-unit\t%s\t%s\n' "$u" "$(unit_file /etc/systemd/user/"$u" /usr/lib/systemd/user/"$u")"; done
} > /tmp/surface
awk -F'\t' 'NR == FNR {owner[$1] = $2; next} {print $1 "\t" $2 "\t" ($3 in owner ? owner[$3] : "image")}' \
  /tmp/owners /tmp/surface | sort -u > "$out/index.tsv"
echo "emit-manifest: $(wc -l < "$out/packages.tsv") packages, $(grep -vc '^#' "$out/flatpaks.txt") flatpak lines, $(wc -l < "$out/content.list") content files ($(du -h "$out/content.tar.zst" | cut -f1))"
