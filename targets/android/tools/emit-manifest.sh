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
set -euo pipefail
out=$1 rules=$2
mkdir -p "$out"

rpm -qa --qf '%{NAME}\t%{ARCH}\n' | sort -u > "$out/packages.tsv"
# Top level: packages nothing else installed requires. These are what the phone maps (Arch pulls in
# their dependencies itself); packages.tsv stays for reference and for "bundle" lookups.
dnf5 repoquery --installed --leaves --qf '%{name}\t%{arch}\n' 2>/dev/null | sort -u > "$out/leaves.tsv" \
  || cp "$out/packages.tsv" "$out/leaves.tsv"

: > "$out/flatpaks.txt"
find /usr/share/ublue-os -path '*/flatpak/install' -type f 2>/dev/null | while read -r f; do
  echo "# $f" >> "$out/flatpaks.txt"; cat "$f" >> "$out/flatpaks.txt"
done

# Files no package owns, in the places PowOS/Bazzite put content; generated caches and machine state left out.
rpm -qa --qf '[%{FILENAMES}\n]' | sort -u > /tmp/owned
find /etc /usr/share /usr/lib/powos /usr/bin /usr/libexec \( -type f -o -type l \) 2>/dev/null | sort -u > /tmp/all
comm -23 /tmp/all /tmp/owned \
  | grep -vE '^/etc/(machine-id|hostname|shadow|gshadow|passwd|group|subuid|subgid|ld\.so\.cache|pki|selinux|ssh/ssh_host_|fstab|resolv\.conf|yum\.repos\.d|dnf|rpm|ostree|containers/storage)' \
  | grep -vE '^/usr/share/(mime/[^/]+$|icons/[^/]+/icon-theme\.cache|fonts/.*\.uuid|applications/mimeinfo\.cache|glib-2\.0/schemas/gschemas\.compiled)' \
  > /tmp/unowned

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
tar -C / --no-recursion -cf - -T "$out/content.list" | zstd -q -19 -o "$out/content.tar.zst"
echo "emit-manifest: $(wc -l < "$out/packages.tsv") packages, $(grep -vc '^#' "$out/flatpaks.txt") flatpak lines, $(wc -l < "$out/content.list") content files ($(du -h "$out/content.tar.zst" | cut -f1))"
