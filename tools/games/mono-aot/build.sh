#!/bin/bash
# build.sh <game dir> <out dir> [jobs] - inside the Containerfile's image (tools/games/mono-aot.sh build runs it).
# For every <X>_Data/Managed/*.dll: the game's own mono.dll AOT-compiles it to gas (`--aot=asmonly,nodebug`), mingw
# assembles + links it into <out>/images/<X>_Data/Managed/<asm>.dll.dll, and <out>/images.tsv gets a row
#   <image path relative to the game dir> \t <sha256 of the source assembly> \t <its GUID, as the image records it>
# Unity 2017.4's aot-runtime.c load_aot_module() opens "<assembly path>.dll" beside each assembly and refuses it on a
# wrong mono_aot_version, assembly GUID or runtime build (docs/research/broforce-engine-init.md, lever 2).
set -euo pipefail
[ "${1:-}" = one ] && { shift; MODE=one; } || MODE=all
G=$(cd "$1" && pwd); O=$2; JOBS=${3:-8}
HERE=$(cd "$(dirname "$0")" && pwd)
W=${MONO_AOT_WORK:-/tmp/mono-aot-work}
export DISPLAY=:9 WINEPREFIX=$W/pfx WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml=;winemenubuilder.exe=d"
data=$(ls -d "$G"/*_Data | head -1)
mono=$data/Mono/EmbedRuntime/mono.dll
win() { echo "Z:${1//\//\\}"; }

one() {  # <assembly file name>
  local a=$1 rel s d
  rel=${data#"$G"/}/Managed/$a.dll; s=$W/s/$a
  if ! timeout 1800 wine "$W/loader.exe" "$(win "$mono")" "$(win "$data/Managed")" "$(win "$data/Mono/etc")" \
      "--aot=asmonly,nodebug,outfile=$(win "$s.s")" "$(win "$data/Managed/$a")" > "$s.log" 2>&1 || [ ! -s "$s.s" ]; then
    echo "skip $a: AOT compile failed ($(tail -1 "$s.log"))"; return 0
  fi
  # HACK: the Win32 asm writer (image-writer.c) still emits ELF-only `.local X` / `.size X,.-X` (aot-compiler.c forces
  # write_symbols on); COFF gas rejects them. They only carry symbol metadata. Real fix: none, the compiler is the
  # game's mono.dll and must stay that exact build.
  sed -E '/^\s*\.(local|size)\s/d' "$s.s" > "$s.coff.s"
  x86_64-w64-mingw32-as --64 -o "$s.o" "$s.coff.s"
  # The writer prefixes globals with "_" (x86 Win32 convention) but the loader asks GetProcAddress for the bare names
  # (mono_assembly_guid, methods, ...): export each bare name as an alias.
  { echo EXPORTS; sed -nE 's/^\s*\.globl\s+_(\S+)/  \1 = _\1/p' "$s.coff.s"; } > "$s.def"
  d=$O/images/$rel; mkdir -p "$(dirname "$d")"
  x86_64-w64-mingw32-gcc -shared -nostdlib -Wl,-e,DllMainCRTStartup -o "$d.tmp" "$s.o" "$W/entry.o" "$s.def"
  mv "$d.tmp" "$d"
  guid=$(sed -nE '/^mono_assembly_guid:/{n;s/.*"(.*)".*/\1/p}' "$s.coff.s")
  printf '%s\t%s\t%s\n' "$rel" "$(sha256sum < "$data/Managed/$a" | cut -d' ' -f1)" "$guid" > "$s.row"
  echo "ok   $a ($(grep -m1 Compiled "$s.log" | tr -d '\r'))"
  rm -f "$s.s" "$s.coff.s" "$s.o"
}

if [ $MODE = one ]; then one "$4"; exit 0; fi
mkdir -p "$W/s" "$O"
[ -e /tmp/.X11-unix/X9 ] || { Xvfb :9 -screen 0 640x480x24 >/dev/null 2>&1 & sleep 1; }
[ -d "$W/pfx/drive_c" ] || timeout 300 wine wineboot -i >/dev/null 2>&1
wineserver -p || true  # one session for every compile (no per-call boot)
x86_64-w64-mingw32-gcc -O1 -o "$W/loader.exe" "$HERE/loader.c"
echo 'int __stdcall DllMainCRTStartup(void *h, unsigned r, void *p) { return 1; }' > "$W/entry.c"
x86_64-w64-mingw32-gcc -O1 -c -o "$W/entry.o" "$W/entry.c"
rm -rf "$O/images" "$O/images.tsv"; rm -f "$W"/s/*.row
ls "$data/Managed" | grep -E '\.dll$' | grep -v '\.dll\.dll$' |
  xargs -P "$JOBS" -I{} env MONO_AOT_WORK="$W" "$0" one "$G" "$O" "$JOBS" {}
cat "$W"/s/*.row 2>/dev/null | sort > "$O/images.tsv"
echo "built $(wc -l < "$O/images.tsv") images in $O/images ($(du -sh "$O/images" | cut -f1))"
wineserver -k || true
