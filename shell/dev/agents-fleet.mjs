/**
 * The agent fleet the gate and the design renders check the Agents screen and widget against (ui/agents.tsx,
 * fleet.ts): the manager working, 3 helpers working on board tasks with plans and steps, 1 session stopped with
 * model_not_found, 12 idle sessions (raw labels among them: "<task-notification>", "idle", "model_not_found"-free),
 * 4 helpers done today. FLEET_SETUP is an async function body over (U: module import, E: the mock's events, sleep):
 * the mock's own ticking stopped, the board and the agents in place. Run it AFTER opening what shows them (the screen,
 * the widget): they subscribe then, and the mock's snapshot would replace these if they came first.
 */
export const FLEET_SETUP = `
  window.__powosMockQuiet = true;
  const now = Date.now();
  const F = await U('./fleet.ts');
  const st = (texts, cur) => JSON.stringify(texts.map((text, i) => ({ text, state: i < cur ? 'done' : i === cur ? 'current' : 'next' })));
  const task = (id, title, steps, cur) => [id, { id, title, owner: 'coder', status: 'working', progressDone: cur, progressTotal: steps.length, step: steps[cur], steps: st(steps, cur) }];
  F.workRows.value = new Map([
    task('media-card', 'Media card redesign', ['look at the old card', 'new layout', 'album art crop', 'renders', 'land'], 3),
    task('ds2-launcher', 'Tap opens the launcher, hold to talk', ['find the tap handler', 'open on tap', 'hold to talk', 'device check'], 1),
    task('perf-binder', 'Phone stutters: main thread waits on the system', ['trace', 'find the blocking calls', 'move them off the main thread', 'measure', 'land', 'phone check'], 2),
  ]);
  const row = (id, role, state, o) => ({ id, host: id.split(':')[0], role, parent: null, state, title: '', step: '', cwd: 'PowOS', pid: 0, subs: 0, unread: 0, report: '', work: '', started: now - 3_600_000, last: now - 60_000, rev: 1, ...o });
  const sub = (n, work, title, step, ago, started) => row('mac:c0/s' + n, 'general-purpose', 'working', { parent: 'mac:c0', title, step, work, last: now - ago, started: now - started });
  const idleTitles = ['<task-notification>', 'idle', '', 'set it up properly so it stops eating my space', '<ta', 'idle', 'Discord alerts for disk, VM, NAS, mounts, containers', 'cnt we integrate the buttons instead of changing the padding?', '', 'idle', 'I want to play arc raiders', '<task-notification>'];
  const agents = [
    row('phone:m1', 'manager', 'working', { title: 'Is it a manual thing or is it automatically updated?', step: 'mcp__comms__send_message', last: now - 4_000, pid: 4242 }),
    row('mac:c0', 'coder', 'working', { title: '<task-notification>', step: 'Agent', subs: 3, last: now - 20_000 }),
    sub(1, 'media-card', 'MD: media card redesign', 'Bash final renders and crops', 48_000, 1_500_000),
    sub(2, 'ds2-launcher', 'DS2 final: tap opens launcher, hold PTT', 'Bash keep foot still during morph', 60_000, 2_400_000),
    sub(3, 'perf-binder', 'Perf A: main-thread binder blocks', 'Bash check whether the phone is idle', 1_000, 900_000),
    row('mac:e1', 'coder', 'blocked', { title: '', step: 'model_not_found', last: now - 600_000 }),
    ...idleTitles.map((title, i) => row('mac:i' + i, 'coder', 'idle', { title, last: now - (i < 9 ? (i + 1) * 3_000_000 : 2 * 86_400_000 + i * 1000) })),
    ...[0, 1, 2, 3].map((i) => row('mac:c0/d' + i, 'general-purpose', 'gone', { parent: 'mac:c0', title: ['AO4 crop thumb', 'Plasma app: first launch', 'powos-progress app', 'AI page redesign'][i], sha: 'ab12cd' + i, last: now - (i + 1) * 1_800_000, started: now - (i + 2) * 1_800_000 })),
  ];
  await sleep(400);
  E.emit('agents.delta', { full: true, agents, tasks: [], messages: [], asks: [] });
  await sleep(200);
`;
