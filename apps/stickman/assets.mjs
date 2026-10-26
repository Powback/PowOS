// Converts robotsupremacy's stickman export (assets.sh) into what the widget loads:
//   brain.json + brain.bin  the policy with every weight array moved into one float32 file (the export's JSON is
//                           ~5 MB of decimal text; this is ~1/5 of it and needs no parsing of numbers on the phone)
//   parkour.json            the lessons that are courses (worlds with checkpoints), only the fields the widget uses
//   meta.json, stickman.xml as they are
// Usage: node assets.mjs <export dir> <out dir>
import { copyFileSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const [src, out] = process.argv.slice(2);
const read = (f) => JSON.parse(readFileSync(join(src, f), "utf8"));

// ---- brain ----------------------------------------------------------------------------------------------------------
const policy = read("policy.json");
// The critic only decides turning for a brain with a value-based turn rule; without one it's dead weight.
if (!policy.turn) delete policy.critic;
delete policy.keys; // the checkpoint's tensor names, for debugging the export
const chunks = [];
let offset = 0;
const isNum = (a) => Array.isArray(a) && a.length > 0 && typeof a[0] === "number";
const isMat = (a) => Array.isArray(a) && a.length > 0 && isNum(a[0]);
function pack(v) {
  if (isNum(v) || isMat(v)) {
    const flat = isMat(v) ? v.flat() : v;
    const f = Float32Array.from(flat);
    chunks.push(f);
    const ref = { f32: [offset, f.length], shape: isMat(v) ? [v.length, v[0].length] : [v.length] };
    offset += f.length;
    return ref;
  }
  if (Array.isArray(v)) return v.map(pack);
  if (v && typeof v === "object") return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, pack(x)]));
  return v;
}
const brain = pack(policy);
const bin = new Float32Array(offset);
let at = 0;
for (const c of chunks) {
  bin.set(c, at);
  at += c.length;
}
writeFileSync(join(out, "brain.bin"), Buffer.from(bin.buffer));
writeFileSync(join(out, "brain.json"), JSON.stringify(brain));

// ---- parkour lessons ------------------------------------------------------------------------------------------------
const lessons = read("lessons.json").lessons;
const parkour = lessons
  .filter((l) => l.worlds.length && l.worlds.every((w) => w.wps))
  .map((l) => ({
    name: l.name,
    episode_s: l.episode_s,
    worlds: l.worlds.map((w) => ({ W: w.W, H: w.H, pieces: w.pieces, phi: w.phi, spawn: w.spawn, wps: w.wps, pit_z: w.pit_z })),
  }));
writeFileSync(join(out, "parkour.json"), JSON.stringify(parkour));

copyFileSync(join(src, "meta.json"), join(out, "meta.json"));
copyFileSync(join(src, "stickman.xml"), join(out, "stickman.xml"));
console.log(`brain ${policy.exp} @${policy.ckpt}: ${(bin.byteLength / 1e6).toFixed(2)} MB; ${parkour.length} parkour lessons`);
