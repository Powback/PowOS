// The stickman widget's worker: robotsupremacy's trained stick figure (http://robotsupremacy.pow/stickman) running its
// parkour lessons, simulated and drawn here, off the shell's main thread. The physics is the same MuJoCo model as
// training (MuJoCo's WebAssembly build) and the only thing that knows about collisions: the course is its line pieces
// (the export's own data, not read off any page) loaded into the model's segment slots. The brain is the exported
// policy, fed the same 77 observations env.py computes. Drawing is a few canvas strokes in the theme's colours on a
// transparent OffscreenCanvas - no renderer, no HUD.
//
// Ported from robotsupremacy viewer/web/src/scripts/stickman.ts (observe, act, controlStep, resetBody, loadLesson):
// keep the two in step - the observation must match training's (its parity test is stickman/parity.py there).
// HACK: a copy, because robotsupremacy has no browser core library yet; its stickman/web/PLAN.md step 1 ("pull the sim
// and brain out of stickman.ts") is the real fix, and then this imports it.
//
// Messages in:  { type: "init", canvas, base, colors, width, height, dpr, fps }
//               { type: "run", on, fps? }               frames on (the tile is on screen) or off; fps: at most 30
//               { type: "size", width, height, dpr }    { type: "colors", colors }
//               { type: "alive" }                       the page is really drawn (about once a second while on)
//               { type: "nodraw", on }                  checks only: simulate without drawing
//               { type: "stats" }                       answers { type: "stats", lesson, checkpoint, prof, ... } (checks)
// Messages out: { type: "ready", brain, lessons } | { type: "error", message }
//
// Pacing: while on, a frame at most every 1/fps s on a timer, and only while the page's heartbeat ("alive", from its
// requestAnimationFrame) keeps coming. Off: nothing scheduled at all, no timer, no physics; it carries on where it
// stopped, not with the time it was away.

type V2 = [number, number];
type F32Ref = { f32: [number, number]; shape: number[] };
type Mat = { w: Float32Array; rows: number; cols: number };
type Layer = { w: Mat; b: Float32Array };
type Rnn = { ih: Mat; hh: Mat; bih: Float32Array; bhh: Float32Array };
type Norm = { mean?: Float32Array; std?: Float32Array; var?: Float32Array };
type Mlp = { norm: Norm; layers: Layer[] };
type Policy = {
  exp: string; ckpt: number; norm: Norm; layers: Layer[]; rnn?: Rnn; nav_hint?: boolean;
  mem?: { kind: "add" | "twotick"; gru: Rnn; out: Layer }; critic?: Mlp; turn?: { by: "value"; votes: number; margin: number };
};
type Meta = {
  nseg: number; nray: number; ray_max: number; coin_r: number; obs_dim: number; act_dim: number; decimation: number; timestep: number;
  g: number; torso_home_z: number; torso_centre: number; turn_cooldown?: number; action_smooth?: number; turn_time?: number;
  anat_range?: [number, number][]; head_hit_speed?: number; root_q: number[]; root_v: number[]; joint_q: number[]; joint_v: number[];
  joint_range: [number, number][]; seg_mocap: number[]; wall_mocap: number[]; body_mass: number[]; mobile: number[]; sites: string[];
  touch: string[]; kp: number[]; kv: number[]; fmax: number[];
  stamina: { stamina_drain: number; stamina_recover: number; grip_drain: number; min_strength: number };
  draw: { body: number; name: string; kind: "line" | "circle"; r: number; a: V2; b: V2 }[];
};
type World = { W: number; H: number; pieces: number[][]; phi: number; spawn: V2; wps: V2[]; pit_z?: number };
type Lesson = { name: string; episode_s: number; worlds: World[] };
type Seg = { a: V2; b: V2 };
type Colors = { fg: string; muted: string; accent: string };

let canvas: OffscreenCanvas;
let ctx: OffscreenCanvasRenderingContext2D;
let colors: Colors = { fg: "#ddd", muted: "#888", accent: "#e8a33d" };
let dpr = 1;

let mj: any, model: any, data: any, meta: Meta, policy: Policy | null = null;
let lessons: Lesson[] = [];
let lessonIdx = 0, lessonT = 0;
let W = 10, H = 6;
let segs: Seg[] = [];
let worldDirty = true;
let phi = 0;
let route: V2[] = [];
let wpI = 1;
let coin: V2 = [0, 0];
let spawn: V2 = [0, 0];
let pitZ = -Infinity;
let stamina = 1, facing = 1, blend = 1, turnWait = 0, turnVotes = 0;
let lastAction: Float64Array = new Float64Array(15);
let smooth: Float64Array = new Float64Array(10);
let prevHead: V2 | null = null;
let hidden: Float64Array | null = null;
let last = 0, acc = 0;
let cam: V2 | null = null;
const segBody: number[] = []; // mocap index -> body id
let segContype = new Int32Array(0); // each geom's contype as the model has it

// ---- loading --------------------------------------------------------------------------------------------------------
function unpack(v: any, bin: Float32Array): any {
  if (v && typeof v === "object" && "f32" in v) {
    const r = v as F32Ref;
    const a = bin.subarray(r.f32[0], r.f32[0] + r.f32[1]);
    return r.shape.length === 2 ? ({ w: a, rows: r.shape[0], cols: r.shape[1] } as Mat) : a;
  }
  if (Array.isArray(v)) return v.map((x) => unpack(x, bin));
  if (v && typeof v === "object") return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, unpack(x, bin)]));
  return v;
}
const vec = (m: any): Float32Array => (m instanceof Float32Array ? m : m.w);
const norm = (n: Record<string, any>): Norm => ({ mean: n._mean ?? n.mean, std: n._std ?? n.std, var: n._var ?? n.var });
const rnn = (r: any): Rnn => ({ ih: r.weight_ih, hh: r.weight_hh, bih: vec(r.bias_ih), bhh: vec(r.bias_hh) });
const layer = (l: any): Layer => ({ w: l.w, b: vec(l.b) });

async function load(base: string) {
  const get = async (f: string) => {
    const r = await fetch(base + f);
    if (!r.ok) throw new Error(`${f}: ${r.status}`);
    return r;
  };
  // The wasm fetched here and handed over: the shell serves it as application/octet-stream, which streaming
  // compilation refuses (it would fall back to this anyway, after a console warning).
  const [loader, wasm, xml, m, brainJson, brainBin, les] = await Promise.all([
    import(/* @vite-ignore */ base + "mujoco/mujoco.js"),
    get("mujoco/mujoco.wasm").then((r) => r.arrayBuffer()),
    get("data/stickman.xml").then((r) => r.text()),
    get("data/meta.json").then((r) => r.json()),
    get("data/brain.json").then((r) => r.json()),
    get("data/brain.bin").then((r) => r.arrayBuffer()),
    get("data/parkour.json").then((r) => r.json()),
  ]);
  mj = await loader.default({ wasmBinary: wasm });
  meta = m;
  lessons = les;
  const p = unpack(brainJson, new Float32Array(brainBin));
  policy = {
    exp: p.exp, ckpt: p.ckpt, nav_hint: p.nav_hint, turn: p.turn,
    norm: norm(p.norm), layers: p.layers.map(layer),
    rnn: p.rnn ? rnn(p.rnn) : undefined,
    mem: p.mem ? { kind: p.mem.kind, gru: rnn(p.mem.gru), out: layer(p.mem.out) } : undefined,
    critic: p.critic ? { norm: norm(p.critic.norm), layers: p.critic.layers.map(layer) } : undefined,
  };
  model = mj.MjModel.from_xml_string(xml);
  data = new mj.MjData(model);
  const mocapId = model.body_mocapid;
  for (let b = 0; b < mocapId.length; b++) if (mocapId[b] >= 0) segBody[mocapId[b]] = b;
  segContype = Int32Array.from(model.geom_contype);
  lastAction = new Float64Array(meta.act_dim);
  if (!lessons.length) throw new Error("no parkour lessons in the export");
  loadLesson(Math.floor(Math.random() * lessons.length));
}

// ---- world -> mocap (stickman.ts writeWorld) -------------------------------------------------------------------------
function writeWorld() {
  const mp = data.mocap_pos, mq = data.mocap_quat;
  for (let i = 0; i < meta.nseg; i++) {
    const m = meta.seg_mocap[i];
    const s = segs[i];
    if (!s) { mp[m * 3] = 0; mp[m * 3 + 1] = 0; mp[m * 3 + 2] = -50; mq.set([1, 0, 0, 0], m * 4); continue; }
    const cx = (s.a[0] + s.b[0]) / 2, cz = (s.a[1] + s.b[1]) / 2;
    const ang = Math.atan2(s.b[1] - s.a[1], s.b[0] - s.a[0]);
    mp[m * 3] = cx; mp[m * 3 + 1] = 0; mp[m * 3 + 2] = cz;
    mq.set([Math.cos(-ang / 2), 0, Math.sin(-ang / 2), 0], m * 4);
  }
  const walls: [number, number, number][] = [[W / 2, 0, 0], [W, H / 2, -Math.PI / 2], [W / 2, H, Math.PI], [0, H / 2, Math.PI / 2]];
  walls.forEach(([x, z, th], i) => {
    const m = meta.wall_mocap[i];
    mp[m * 3] = x; mp[m * 3 + 1] = 0; mp[m * 3 + 2] = z;
    mq.set([Math.cos(th / 2), 0, Math.sin(th / 2), 0], m * 4);
  });
  // Slots the course doesn't use are parked far below it; their collisions are switched off too, so the collision
  // pass only sees the pieces there are (the same contacts as before: nothing ever reaches the parked ones).
  const ct = model.geom_contype;
  for (let i = 0; i < meta.nseg; i++) {
    const b = segBody[meta.seg_mocap[i]];
    for (let g = model.body_geomadr[b], n = g + model.body_geomnum[b]; g < n; g++) ct[g] = segs[i] ? segContype[g] : 0;
  }
  worldDirty = false;
}
const surfaces = (): Seg[] => [...segs, { a: [0, 0], b: [W, 0] }, { a: [W, 0], b: [W, H] }, { a: [W, H], b: [0, H] }, { a: [0, H], b: [0, 0] }];

function writeGravity() {
  const gx = Math.sin(phi) * meta.g, gz = -Math.cos(phi) * meta.g;
  const xf = data.xfrc_applied;
  xf.fill(0);
  for (const b of meta.mobile) {
    xf[b * 6] = meta.body_mass[b] * gx;
    xf[b * 6 + 2] = meta.body_mass[b] * gz;
  }
}

// ---- kinematics + observation (stickman.ts observe = env.py compute_obs) ---------------------------------------------
function root() {
  const q = data.qpos, v = data.qvel, [ix, iz, ir] = meta.root_q;
  return { x: q[ix], z: q[iz] + meta.torso_home_z, th: q[ir], vx: v[meta.root_v[0]], vz: v[meta.root_v[1]], w: v[meta.root_v[2]] };
}
function torsoPos(): V2 {
  const r = root();
  return [r.x + meta.torso_centre * Math.sin(r.th), r.z + meta.torso_centre * Math.cos(r.th)];
}
function sitePos(i: number): V2 { const s = data.sensordata; return [s[i * 3], s[i * 3 + 2]]; }
function rayDist(p: V2, d: V2, S: Seg[], rmax: number) {
  let best = rmax;
  for (const s of S) {
    const ex = s.b[0] - s.a[0], ez = s.b[1] - s.a[1];
    const den = d[0] * ez - d[1] * ex;
    if (Math.abs(den) < 1e-12) continue;
    const wx = s.a[0] - p[0], wz = s.a[1] - p[1];
    const t = (wx * ez - wz * ex) / den;
    const u = (wx * d[1] - wz * d[0]) / den;
    if (t > 0 && u >= 0 && u <= 1 && t < best) best = t;
  }
  return best;
}
function observe(alt?: number): Float64Array {
  const o = new Float64Array(meta.obs_dim);
  const r = root();
  const c = Math.cos(r.th), s = Math.sin(r.th);
  const bx: V2 = [c, -s], bz: V2 = [s, c];
  const toBody = (w: V2): V2 => [w[0] * bx[0] + w[1] * bx[1], w[0] * bz[0] + w[1] * bz[1]];
  let k = 0;
  const fc = alt ?? facing;
  const g = toBody([Math.sin(phi), -Math.cos(phi)]); o[k++] = fc * g[0]; o[k++] = g[1];
  const vel = toBody([r.vx + r.w * meta.torso_centre * c, r.vz - r.w * meta.torso_centre * s]);
  o[k++] = (fc * vel[0]) / 3; o[k++] = vel[1] / 3; o[k++] = (fc * r.w) / 10;
  for (const qi of meta.joint_q) o[k++] = facing * data.qpos[qi];
  for (const vi of meta.joint_v) o[k++] = (facing * data.qvel[vi]) / 10;
  for (let i = 0; i < meta.act_dim; i++) o[k++] = lastAction[i];
  const t0 = meta.sites.length * 3;
  for (let i = 0; i < meta.touch.length; i++) o[k++] = data.sensordata[t0 + i] > 1e-3 ? 1 : 0;
  const tp = torsoPos();
  const S = surfaces();
  for (let i = 0; i < meta.nray; i++) {
    const j = fc > 0 ? i : (((meta.nray / 2 - i) % meta.nray) + meta.nray) % meta.nray;
    const a = (2 * Math.PI * j) / meta.nray;
    const d: V2 = [Math.cos(a) * bx[0] + Math.sin(a) * bz[0], Math.cos(a) * bx[1] + Math.sin(a) * bz[1]];
    o[k++] = rayDist(tp, d, S, meta.ray_max) / meta.ray_max;
  }
  const cv = toBody([coin[0] - tp[0], coin[1] - tp[1]]);
  const cd = Math.hypot(cv[0], cv[1]);
  const f = Math.max(cd / 5, 1);
  o[k++] = (fc * cv[0]) / 5 / f; o[k++] = cv[1] / 5 / f; o[k++] = Math.min(cd / 5, 1);
  o[k++] = stamina;
  o[k++] = alt === undefined ? blend * facing : 1;
  return o;
}

// ---- the brain (stickman.ts act / gru / mlpForward, on flat float32 weights) ------------------------------------------
// One output buffer per layer, reused every step (the page's version allocates arrays per step); the loops are the same
// sums in the same order, so the numbers match it.
const bufs = new WeakMap<object, Float64Array>();
function buf(key: object, n: number) {
  let b = bufs.get(key);
  if (!b || b.length !== n) bufs.set(key, (b = new Float64Array(n)));
  return b;
}
function matVec(m: Mat, x: Float64Array, bias: Float32Array, into: Float64Array) {
  const w = m.w, cols = m.cols, rows = m.rows;
  for (let j = 0; j < rows; j++) {
    let s = bias[j];
    const o = j * cols;
    for (let i = 0; i < cols; i++) s += w[o + i] * x[i];
    into[j] = s;
  }
  return into;
}
const f64 = (a: ArrayLike<number>) => (a instanceof Float64Array ? a : Float64Array.from(a));
function gru(x: Float64Array, R: Rnn): Float64Array {
  const Hn = R.hh.cols;
  const h = hidden ?? new Float64Array(Hn);
  const gi = matVec(R.ih, x, R.bih, buf(R.ih, 3 * Hn));
  const gh = matVec(R.hh, h, R.bhh, buf(R.hh, 3 * Hn));
  const sig = (t: number) => 1 / (1 + Math.exp(-t));
  const out = new Float64Array(Hn);
  for (let j = 0; j < Hn; j++) {
    const r = sig(gi[j] + gh[j]), z = sig(gi[Hn + j] + gh[Hn + j]);
    const n = Math.tanh(gi[2 * Hn + j] + r * gh[2 * Hn + j]);
    out[j] = (1 - z) * n + z * h[j];
  }
  hidden = out;
  return out;
}
function normalize(obs: ArrayLike<number>, n: Norm, off = 0): Float64Array {
  const x = Float64Array.from(obs);
  if (!n.mean) return x;
  for (let i = 0; i < x.length; i++) x[i] = (x[i] - n.mean[off + i]) / ((n.std ? n.std[off + i] : Math.sqrt(n.var![off + i])) + 1e-2);
  return x;
}
function mlpForward(layers: Layer[], x: Float64Array, add?: Float64Array): Float64Array {
  for (let li = 0; li < layers.length; li++) {
    const L = layers[li];
    const y = matVec(L.w, x, L.b, buf(L, L.w.rows));
    if (li === 0 && add) for (let j = 0; j < y.length; j++) y[j] += add[j];
    if (li < layers.length - 1) for (let j = 0; j < y.length; j++) y[j] = y[j] > 0 ? y[j] : Math.expm1(y[j]);
    x = y;
  }
  return x;
}
const linear = (L: Layer, x: Float64Array) => matVec(L.w, x, L.b, new Float64Array(L.w.rows));
function act(obs: Float64Array): Float64Array {
  const a = new Float64Array(meta.act_dim);
  const nIn = policy?.layers[0].w.cols ?? 0;
  // a one-brain-for-everything brain takes the 77 inputs then 15 opponent inputs: zero here, as on the page
  if (policy && !policy.rnn && !policy.mem && nIn > obs.length) { const p = new Float64Array(nIn); p.set(obs); obs = p; }
  if (!policy || (nIn !== obs.length && !policy.rnn)) return a;
  let x = normalize(obs, policy.norm);
  let add: Float64Array | undefined;
  if (policy.mem) {
    const h = gru(policy.mem.kind === "twotick" ? f64([...x, 0]) : x, policy.mem.gru);
    if (policy.mem.kind === "twotick") gru(f64([...normalize(observe(-facing), policy.norm, meta.obs_dim), 1]), policy.mem.gru);
    add = linear(policy.mem.out, h);
  } else if (policy.rnn) x = gru(x, policy.rnn);
  const out = mlpForward(policy.layers, x, add);
  for (let i = 0; i < meta.act_dim; i++) a[i] = Math.max(-1, Math.min(1, out[i]));
  return a;
}
const value = (obs: Float64Array) => mlpForward(policy!.critic!.layers, normalize(obs, policy!.critic!.norm))[0];

// ---- one 50 Hz control step (stickman.ts controlStep, without the page's drag, tilt and coin lessons) ------------------
function controlStep() {
  if (worldDirty) writeWorld();
  const ta = performance.now();
  const a = act(observe());
  prof.act += performance.now() - ta;
  const dt = meta.timestep * meta.decimation;
  turnWait = Math.max(0, turnWait - dt);
  let want = a[14] > 0.5;
  if (policy?.turn?.by === "value" && policy.critic) {
    const gap = value(observe(-facing)) - value(observe());
    turnVotes = gap > policy.turn.margin ? turnVotes + 1 : 0;
    want = turnVotes >= policy.turn.votes;
  }
  if (want && turnWait <= 0) { facing = -facing; turnWait = meta.turn_cooldown ?? 1.0; turnVotes = 0; }
  const stepB = (2 * dt) / (meta.turn_time ?? 0.3);
  blend += Math.max(-stepB, Math.min(stepB, facing - blend));
  const u = data.ctrl;
  const st = meta.stamina;
  const strength = st.min_strength + (1 - st.min_strength) * stamina;
  (meta.anat_range ?? meta.joint_range).forEach(([lo, hi], i) => {
    const q = data.qpos[meta.joint_q[i]];
    smooth[i] += (meta.action_smooth ?? 1) * (a[i] - smooth[i]);
    const target = blend * ((lo + hi) / 2 + ((hi - lo) / 2) * smooth[i]);
    u[i] = q + (target - q) * strength;
  });
  for (let i = 10; i < 14; i++) u[i] = Math.max(0, Math.min(1, a[i])) * strength;
  writeGravity();
  const ts = performance.now();
  for (let i = 0; i < meta.decimation; i++) mj.mj_step(model, data);
  prof.step += performance.now() - ts;
  lastAction = a;
  // a hard knock to the head ends the episode (env.py head_hit): the lesson starts over
  const head = sitePos(1);
  const touchingHead = data.sensordata[meta.sites.length * 3] > 1e-3;
  if (prevHead && touchingHead && Math.hypot(head[0] - prevHead[0], head[1] - prevHead[1]) / dt > (meta.head_hit_speed ?? 1.5)) {
    loadLesson(lessonIdx);
    return;
  }
  prevHead = head;
  let power = 0;
  for (let i = 0; i < 10; i++) {
    const q = data.qpos[meta.joint_q[i]], qd = data.qvel[meta.joint_v[i]];
    const tau = Math.max(-meta.fmax[i], Math.min(meta.fmax[i], meta.kp[i] * (u[i] - q) - meta.kv[i] * qd));
    power += Math.abs(tau * qd);
  }
  let grip = 0;
  for (let i = 10; i < 14; i++) grip += u[i];
  stamina = Math.max(0, Math.min(1, stamina + (st.stamina_recover - st.stamina_drain * power - st.grip_drain * grip) * dt));
  // the next checkpoint reached with the torso, head or a hand: on to the one after; at the finish it runs it back
  for (let i = 0; i < 4; i++) {
    const p = sitePos(i);
    if (Math.hypot(p[0] - coin[0], p[1] - coin[1]) < meta.coin_r) {
      if (++wpI >= route.length) { route.reverse(); wpI = 1; }
      coin = route[wpI];
      hidden = null;
      break;
    }
  }
  // one episode per lesson, then the next (the page's "All lessons" rotation)
  lessonT += dt;
  if (lessonT > lessons[lessonIdx].episode_s) { loadLesson(lessonIdx + 1); return; }
  const r = root();
  if (!Number.isFinite(r.x) || r.x < -1 || r.x > W + 1 || r.z < -1 || r.z > H + 1 || r.z < pitZ) loadLesson(lessonIdx);
}

function resetBody() {
  hidden = null;
  facing = blend = Math.random() < 0.5 ? 1 : -1;
  mj.mj_resetData(model, data);
  data.qpos[meta.root_q[0]] = spawn[0];
  data.qpos[meta.root_q[1]] = spawn[1] + 0.62 - meta.torso_home_z;
  worldDirty = true;
  writeWorld();
  mj.mj_forward(model, data);
  lastAction = new Float64Array(meta.act_dim);
  smooth = new Float64Array(10).map((_, i) => {
    const [lo, hi] = (meta.anat_range ?? meta.joint_range)[i];
    return Math.max(-1, Math.min(1, (facing * data.qpos[meta.joint_q[i]] - (lo + hi) / 2) / ((hi - lo) / 2)));
  });
  stamina = 1;
  turnWait = 0;
  prevHead = null;
}

function loadLesson(i: number) {
  const n = lessons.length;
  lessonIdx = ((i % n) + n) % n;
  const w = lessons[lessonIdx].worlds[Math.floor(Math.random() * lessons[lessonIdx].worlds.length)];
  W = w.W; H = w.H;
  segs = w.pieces.map((p) => ({ a: [p[0], p[1]] as V2, b: [p[2], p[3]] as V2 })).slice(0, meta.nseg);
  phi = w.phi;
  pitZ = w.pit_z ?? -Infinity;
  spawn = [w.spawn[0], w.spawn[1]];
  route = w.wps.map((p) => [p[0], p[1]] as V2);
  wpI = 1;
  lessonT = 0;
  resetBody();
  coin = route[wpI];
  cam = null;
}

// ---- drawing: the camera follows the figure through the course, the room's height (or as much as fits) in view ---------
function bodyPoint(b: number, l: V2): V2 {
  const xp = data.xpos, xm = data.xmat;
  return [xp[b * 3] + xm[b * 9] * l[0] + xm[b * 9 + 2] * l[1], xp[b * 3 + 2] + xm[b * 9 + 6] * l[0] + xm[b * 9 + 8] * l[1]];
}

// What the last drawn frame showed (camera, checkpoint, every body part's ends, in device px): a frame that would look
// the same - the figure standing still, the camera settled - isn't drawn, so the canvas isn't committed and the WebView
// has nothing to composite. [force] after a resize or a theme change.
let shown: Float64Array | null = null, shownWp = 0, shownHp = 0;
let force = true;
let noDraw = false; // (checks: simulate without drawing, to tell the two costs apart)
const SAME_PX = 0.5;
function unchanged(key: Float64Array, Wp: number, Hp: number) {
  if (force || !shown || shown.length !== key.length || Wp !== shownWp || Hp !== shownHp) return false;
  for (let i = 0; i < key.length; i++) if (Math.abs(key[i] - shown[i]) > SAME_PX) return false;
  return true;
}
function draw() {
  const Wp = canvas.width, Hp = canvas.height;
  if (!Wp || !Hp) return;
  // 4.5 m of height at most (the figure ~1.3 m tall stays big in a small tile), all of it if the room is lower; wide
  // tiles show more of the course, never more than the room
  const viewH = Math.min(H + 0.3, 4.5);
  const scale = Math.max(Hp / viewH, Wp / (W + 0.3));
  const vw = Wp / scale, vh = Hp / scale;
  const tp = torsoPos();
  const want: V2 = [
    Math.max(-0.15, Math.min(W + 0.15 - vw, tp[0] - vw / 2)),
    Math.max(-0.15, Math.min(H + 0.15 - vh, tp[1] - vh * 0.42)),
  ];
  cam = cam ? [cam[0] + (want[0] - cam[0]) * 0.12, cam[1] + (want[1] - cam[1]) * 0.12] : want;
  const [cx, cz] = cam;
  const X = (x: number) => (x - cx) * scale, Z = (z: number) => Hp - (z - cz) * scale;
  const key = new Float64Array(5 + meta.draw.length * 4);
  key[0] = cx * scale; key[1] = cz * scale; key[2] = wpI; key[3] = X(coin[0]); key[4] = Z(coin[1]);
  meta.draw.forEach((p, i) => {
    const a = bodyPoint(p.body, p.a), b = bodyPoint(p.body, p.b);
    key[5 + i * 4] = X(a[0]); key[6 + i * 4] = Z(a[1]); key[7 + i * 4] = X(b[0]); key[8 + i * 4] = Z(b[1]);
  });
  if (noDraw || unchanged(key, Wp, Hp)) { prof.skipped++; return; }
  shown = key; shownWp = Wp; shownHp = Hp; force = false;
  ctx.clearRect(0, 0, Wp, Hp);
  ctx.lineCap = "round";
  ctx.lineJoin = "round";
  // the room (its floor and walls) faint, the course's pieces in the foreground colour
  ctx.globalAlpha = 0.35;
  ctx.strokeStyle = colors.muted;
  ctx.lineWidth = 0.04 * scale;
  ctx.strokeRect(X(0), Z(H), W * scale, H * scale);
  ctx.globalAlpha = 0.85;
  ctx.strokeStyle = colors.fg;
  ctx.lineWidth = 0.06 * scale;
  ctx.beginPath();
  for (const s of segs) { ctx.moveTo(X(s.a[0]), Z(s.a[1])); ctx.lineTo(X(s.b[0]), Z(s.b[1])); }
  ctx.stroke();
  // the checkpoints still to come, faint; the next one, and the finish flag, in the accent
  ctx.globalAlpha = 0.35;
  ctx.fillStyle = colors.accent;
  ctx.beginPath();
  for (let i = wpI + 1; i < route.length; i++) { ctx.moveTo(X(route[i][0]) + 0.08 * scale, Z(route[i][1])); ctx.arc(X(route[i][0]), Z(route[i][1]), 0.08 * scale, 0, 2 * Math.PI); }
  ctx.fill();
  ctx.globalAlpha = 1;
  const f = route[route.length - 1];
  ctx.strokeStyle = colors.muted;
  ctx.lineWidth = 0.03 * scale;
  ctx.beginPath(); ctx.moveTo(X(f[0]), Z(f[1] - 0.55)); ctx.lineTo(X(f[0]), Z(f[1] + 0.45)); ctx.stroke();
  ctx.beginPath();
  ctx.moveTo(X(f[0]), Z(f[1] + 0.45)); ctx.lineTo(X(f[0] + 0.35), Z(f[1] + 0.33)); ctx.lineTo(X(f[0]), Z(f[1] + 0.21));
  ctx.fill();
  ctx.beginPath(); ctx.arc(X(coin[0]), Z(coin[1]), 0.15 * scale, 0, 2 * Math.PI); ctx.fill();
  // the figure, Pivot style: far limbs (_l) behind and muted, then torso and head, then near limbs (_r)
  const order = (n: string) => (n.endsWith("_l") ? 0 : n.endsWith("_r") ? 2 : 1);
  for (const p of [...meta.draw].sort((p, q) => order(p.name) - order(q.name))) {
    const far = order(p.name) === 0;
    ctx.strokeStyle = ctx.fillStyle = far ? colors.muted : colors.fg;
    const a = bodyPoint(p.body, p.a);
    if (p.kind === "circle") {
      ctx.beginPath(); ctx.arc(X(a[0]), Z(a[1]), (p.name === "head" ? p.r * 1.15 : p.r * 1.2) * scale, 0, 2 * Math.PI); ctx.fill();
    } else {
      const b = bodyPoint(p.body, p.b);
      ctx.lineWidth = (p.r * 2 + (far ? 0 : 0.02)) * scale;
      ctx.beginPath(); ctx.moveTo(X(a[0]), Z(a[1])); ctx.lineTo(X(b[0]), Z(b[1])); ctx.stroke();
    }
  }
}

// ---- the loop: one frame per "frame" message; the page sends none while the tile isn't on screen ------------------------
const prof = { act: 0, step: 0, fwd: 0, draw: 0, frames: 0, steps: 0, gaps: new Array(10).fill(0), maxGap: 0, skipped: 0 };
function frame() {
  const now = performance.now();
  // Real time, but never more than 0.1 s of it at once: after a pause it carries on where it stopped.
  acc = Math.min(acc + (last ? (now - last) / 1000 : 0), 0.1);
  last = now;
  const dt = meta.timestep * meta.decimation;
  while (acc >= dt) { controlStep(); acc -= dt; prof.steps++; }
  const t1 = performance.now();
  mj.mj_forward(model, data);
  const t2 = performance.now();
  draw();
  prof.fwd += t2 - t1; prof.draw += performance.now() - t2; prof.frames++;
}

function size(w: number, h: number, r: number) {
  // Device pixels capped at 2x: strokes this thick look the same on the 2.6x panel and cost less to fill.
  dpr = Math.min(r || 1, 2);
  canvas.width = Math.max(1, Math.round(w * dpr));
  canvas.height = Math.max(1, Math.round(h * dpr));
}

let ready = false, running = false, fps = 15, timer = 0, lastAt = 0;
// Paced by a timer: the canvas is committed only when a frame is drawn, so the compositor (and the app's own render
// threads behind it) have nothing to do in between - a requestAnimationFrame here kept them waking every vsync.
// A frame never comes sooner than 1/fps after the last.
//
// Liveness: the page sends "alive" from its own requestAnimationFrame about once a second while it wants frames. A
// WebView that isn't drawn gets no requestAnimationFrame (even when it says it's visible), so the heartbeat stops and
// this stops by itself within ALIVE_MS - no frames burnt behind a screen that's off.
const ALIVE_MS = 2500;
let lastAlive = 0, stalled = false;
function schedule() {
  if (!running) return;
  timer = setTimeout(tick, Math.max(0, 1000 / fps - (performance.now() - lastAt))) as unknown as number;
}
function tick() {
  timer = 0;
  if (!running) return;
  const now = performance.now();
  if (now - lastAlive > ALIVE_MS) { stalled = true; return; } // (the next "alive" starts it again)
  if (lastAt) { const g = now - lastAt; prof.gaps[Math.min(9, Math.floor(g / 20))]++; prof.maxGap = Math.max(prof.maxGap, g); }
  lastAt = now;
  frame();
  schedule();
}
function run(on: boolean) {
  if (on === running) return;
  running = on;
  if (on) {
    last = lastAt = 0; // (time away isn't simulated)
    lastAlive = performance.now();
    schedule();
  } else {
    clearTimeout(timer);
    timer = 0;
  }
}

let wantRun = false;
self.onmessage = async (e: MessageEvent) => {
  const m = e.data;
  if (m.type === "init") {
    canvas = m.canvas;
    ctx = canvas.getContext("2d")!;
    colors = m.colors;
    fps = Math.max(1, Math.min(30, m.fps || 15));
    size(m.width, m.height, m.dpr);
    try {
      await load(m.base);
      ready = true;
      (self as any).postMessage({ type: "ready", brain: `${policy!.exp} @${policy!.ckpt}`, lessons: lessons.length });
      run(wantRun);
    } catch (err) {
      (self as any).postMessage({ type: "error", message: String((err as Error)?.message ?? err) });
    }
  } else if (m.type === "run") {
    if (m.fps) fps = Math.max(1, Math.min(30, m.fps));
    wantRun = m.on;
    if (ready) run(m.on);
  } else if (m.type === "alive") {
    lastAlive = performance.now();
    if (stalled && running) {
      stalled = false;
      last = lastAt = 0;
      schedule();
    }
  } else if (m.type === "size") {
    size(m.width, m.height, m.dpr);
    force = true;
    if (ready) draw();
  } else if (m.type === "colors") {
    if (JSON.stringify(m.colors) !== JSON.stringify(colors)) force = true;
    colors = m.colors;
  } else if (m.type === "nodraw") {
    noDraw = !!m.on;
  } else if (m.type === "stats") {
    // for checks from the page (CDP): where it is in which lesson, and where the time goes (ms, summed)
    const r = ready ? root() : null;
    (self as any).postMessage({ type: "stats", running, lesson: lessons[lessonIdx]?.name, t: lessonT, checkpoint: wpI, of: route.length, x: r?.x, z: r?.z, stamina, prof });
  }
};
