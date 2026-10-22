//! powos-agents: the Agents view's data on the device's own SpacetimeDB (docs/AGENTS-VIEW-DESIGN.md §3, §8). The
//! tables are §3's schema exactly - the spool's rows - so a viewer switching from the spool to this is a backend
//! change only. Each device has its own server and works offline; another host's agents arrive as rows of their own
//! `host` (a mirror), never by depending on a hub.
//!
//! One writer per host: its `powos-agentsd`, which folds the hook events (one implementation of the folding) and
//! calls `sync` with what changed after each batch - the spool stays the fallback. Writers are the module's owner
//! (the device's PowOS user, which published it) and identities it adds with `allow_reporter`. Everyone connected may
//! read (the port is locked to the PowOS uid).
use serde::Deserialize;
use spacetimedb::{Identity, ReducerContext, Table};

const RING: usize = 64;
const MESSAGES: usize = 200;
const TASKS_PER_AGENT: usize = 50;
/// The work board keeps what's open, and what's done for this long (the "done recently" list).
const WORK_DONE_KEEP_MS: u64 = 7 * 24 * 3600 * 1000;
const WORK_MAX: usize = 200;
const WORK_STATES: [&str; 4] = ["working", "blocked", "waiting", "done"];

#[spacetimedb::table(accessor = reporter)]
pub struct Reporter {
    #[primary_key]
    identity: Identity,
    host: String,
}

#[spacetimedb::table(accessor = agent, public)]
#[derive(Clone)]
pub struct Agent {
    #[primary_key]
    id: String,
    #[index(btree)]
    host: String,
    role: String,
    parent: Option<String>,
    state: String,
    title: String,
    step: String,
    cwd: String,
    pid: u32,
    subs: u16,
    unread: u16,
    report: String,
    started: u64,
    last: u64,
    rev: u32,
}

#[spacetimedb::table(accessor = task, public)]
pub struct Task {
    #[primary_key]
    id: String,
    #[index(btree)]
    agent: String,
    subject: String,
    status: String,
    order: u16,
    updated: u64,
}

/// One agent's ring of the last 64 events; `key` is "<agent>#<id>" (`id` is per agent).
#[spacetimedb::table(accessor = event, public)]
pub struct Event {
    #[primary_key]
    key: String,
    id: u64,
    #[index(btree)]
    agent: String,
    ts: u64,
    kind: String,
    name: String,
    hint: String,
    ok: Option<bool>,
    n: u16,
    ms: u32,
}

#[spacetimedb::table(accessor = message, public)]
pub struct Message {
    #[primary_key]
    id: String,
    from: String,
    to: String,
    kind: String,
    priority: String,
    #[index(btree)]
    ts: u64,
    body: String,
    read: bool,
}

#[spacetimedb::table(accessor = ask, public)]
pub struct Ask {
    #[primary_key]
    id: String,
    #[index(btree)]
    agent: String,
    tool: String,
    summary: String,
    ts: u64,
    expires: u64,
    answer: Option<String>,
    reason: Option<String>,
    by: Option<String>,
}

/// The work board: the tasks the agents are on, in plain words, across every agent - what the manager hands out
/// (`powos agents task add|set|done`, on each handoff) and what an agent reports for itself. Not the per-session
/// `task` rows (those are each Claude session's own todo list, replaced by `sync`): a `work` row outlives sessions
/// and is written only through `work_set`/`work_drop`. The PowOS AI page lists it.
#[spacetimedb::table(accessor = work, public)]
pub struct Work {
    #[primary_key]
    id: String,
    /// Short and plain ("Switcher follows finger").
    title: String,
    /// The agent's role ("switcher", "manager"), or "" when nobody has it yet.
    owner: String,
    /// "working" | "blocked" | "waiting" (on the user) | "done".
    status: String,
    /// One line of detail: what it's blocked on, what's next, what landed.
    note: String,
    created: u64,
    #[index(btree)]
    updated: u64,
    /// When it went done (0 while open).
    done: u64,
    /// What it belongs to ("PowOS · phone UI", "Shopping app"): the page groups by it. Last, with a default, so the
    /// table migrates in place.
    #[default("")]
    project: String,
    /// How far along: step [progress_done] of [progress_total] (0/0: no bar). `powos agents task set --progress 3/10`,
    /// or counted from [steps]. These columns come last, with defaults, so the table migrates in place.
    #[default(0u32)]
    progress_done: u32,
    #[default(0u32)]
    progress_total: u32,
    /// The current step, one line ("checking on device"); "" when none.
    #[default("")]
    step: String,
    /// The steps in order, JSON `[{"text", "state": "done"|"current"|"next"}]` ("" = none): done ones are kept.
    #[default("")]
    steps: String,
    /// Linked commits, JSON `[{"sha", "subject"}]`, oldest first ("" = none): `--commit`, or a commit mentioning the id.
    #[default("")]
    commits: String,
    /// Review images (design-qa paths), JSON `["path", ...]` ("" = none).
    #[default("")]
    images: String,
    /// The last activity on it (ms): any change, step or commit link. 0 on rows from before it (use `updated`).
    #[default(0u64)]
    activity: u64,
}

/// The unit registry's fleet view (lib/apps/powos-units, `powos units publish`): every unit on every host - what is
/// installed or running, whose it is, why, its status and resource use, its limits - plus one `_check` row per host
/// with its drift. Each publish replaces that host's rows. The PowOS AI page lists it per host, orphans first.
#[spacetimedb::table(accessor = unit, public)]
pub struct Unit {
    /// "<host>/<id>".
    #[primary_key]
    key: String,
    #[index(btree)]
    host: String,
    id: String,
    name: String,
    /// app | service | container | system | package | watcher | compose | scratch.
    kind: String,
    /// app:<id> | agent:<role> | user | system:<what installed it>.
    owner: String,
    purpose: String,
    /// running | asleep | stopped | installed | missing (the `_check` row: clean | drift).
    status: String,
    mem_kb: u64,
    /// CPU in tenths of a percent of one core.
    cpu_permille: u32,
    limits: String,
    autosleep: String,
    /// Found with no clear owner or purpose: the user decides (`decide` is the question).
    orphan: bool,
    decide: String,
    updated: u64,
}

#[derive(Deserialize)]
struct UnitIn {
    id: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    kind: String,
    #[serde(default)]
    owner: String,
    #[serde(default)]
    purpose: String,
    #[serde(default)]
    status: String,
    #[serde(default, rename = "memKB")]
    mem_kb: u64,
    #[serde(default, rename = "cpuPct")]
    cpu_pct: f64,
    #[serde(default)]
    limits: String,
    #[serde(default)]
    autosleep: String,
    #[serde(default)]
    orphan: bool,
    #[serde(default)]
    decide: String,
}

const UNITS_PER_HOST: usize = 400;

/// One host's units (`powos units publish`): replaces every row of that host. Writers: the host's reporters.
#[spacetimedb::reducer]
pub fn unit_sync(ctx: &ReducerContext, host: String, units: String) -> Result<(), String> {
    may_write(ctx, &host)?;
    let rows: Vec<UnitIn> = serde_json::from_str(&units).map_err(|e| format!("units: {e}"))?;
    let now = now_ms(ctx);
    let keep: std::collections::HashSet<String> =
        rows.iter().take(UNITS_PER_HOST).map(|u| format!("{host}/{}", u.id)).collect();
    let gone: Vec<String> = ctx.db.unit().host().filter(&host).map(|u| u.key).filter(|k| !keep.contains(k)).collect();
    for k in gone {
        ctx.db.unit().key().delete(k);
    }
    for u in rows.into_iter().take(UNITS_PER_HOST) {
        let key = format!("{host}/{}", u.id);
        ctx.db.unit().key().delete(key.clone());
        ctx.db.unit().insert(Unit {
            key,
            host: host.clone(),
            id: cut(u.id, 96),
            name: cut(u.name, 96),
            kind: cut(u.kind, 16),
            owner: cut(u.owner, 96),
            purpose: cut(u.purpose, 300),
            status: cut(u.status, 16),
            mem_kb: u.mem_kb,
            cpu_permille: (u.cpu_pct.max(0.0) * 10.0) as u32,
            limits: cut(u.limits, 120),
            autosleep: cut(u.autosleep, 48),
            orphan: u.orphan,
            decide: cut(u.decide, 300),
            updated: now,
        });
    }
    Ok(())
}

// The batch powos-agentsd sends: its spool rows as JSON (§3 field names).
#[derive(Deserialize)]
struct Batch {
    /// This host's agents, tasks and asks, all of them, when any changed (replaces the host's rows).
    #[serde(default)]
    state: Option<HostState>,
    /// Rings that changed: agent id -> its whole ring.
    #[serde(default)]
    events: std::collections::HashMap<String, Vec<EventRow>>,
    /// Agents gone from the host (their events and tasks go too).
    #[serde(default)]
    dropped: Vec<String>,
    /// The latest messages, when they changed.
    #[serde(default)]
    messages: Option<Vec<MessageRow>>,
}

#[derive(Deserialize)]
struct HostState {
    agents: Vec<AgentRow>,
    #[serde(default)]
    tasks: Vec<TaskRow>,
    #[serde(default)]
    asks: Vec<AskRow>,
}

#[derive(Deserialize)]
struct AgentRow {
    id: String,
    #[serde(default)]
    role: String,
    #[serde(default)]
    parent: Option<String>,
    #[serde(default)]
    state: String,
    #[serde(default)]
    title: String,
    #[serde(default)]
    step: String,
    #[serde(default)]
    cwd: String,
    #[serde(default)]
    pid: u32,
    #[serde(default)]
    subs: u16,
    #[serde(default)]
    unread: u16,
    #[serde(default)]
    report: String,
    #[serde(default)]
    started: u64,
    #[serde(default)]
    last: u64,
    #[serde(default)]
    rev: u32,
}

#[derive(Deserialize)]
struct TaskRow {
    id: String,
    agent: String,
    #[serde(default)]
    subject: String,
    #[serde(default)]
    status: String,
    #[serde(default)]
    order: u16,
    #[serde(default)]
    updated: u64,
}

#[derive(Deserialize)]
struct EventRow {
    id: u64,
    #[serde(default)]
    ts: u64,
    #[serde(default)]
    kind: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    hint: String,
    #[serde(default)]
    ok: Option<bool>,
    #[serde(default)]
    n: u16,
    #[serde(default)]
    ms: u32,
}

#[derive(Deserialize)]
struct MessageRow {
    id: String,
    #[serde(default)]
    from: String,
    #[serde(default)]
    to: String,
    #[serde(default)]
    kind: String,
    #[serde(default)]
    priority: String,
    #[serde(default)]
    ts: u64,
    #[serde(default)]
    body: String,
    #[serde(default)]
    read: bool,
}

#[derive(Deserialize)]
struct AskRow {
    id: String,
    agent: String,
    #[serde(default)]
    tool: String,
    #[serde(default)]
    summary: String,
    #[serde(default)]
    ts: u64,
    #[serde(default)]
    expires: u64,
    #[serde(default)]
    answer: Option<String>,
    #[serde(default)]
    reason: Option<String>,
    #[serde(default)]
    by: Option<String>,
}

fn cut(s: String, n: usize) -> String {
    if s.chars().count() <= n { s } else { s.chars().take(n).collect() }
}

#[spacetimedb::reducer(init)]
pub fn init(ctx: &ReducerContext) {
    ctx.db.reporter().insert(Reporter { identity: ctx.sender(), host: "*".into() });
}

/// The hosts a caller may write: "*" (the owner: any host) or one.
fn may_write(ctx: &ReducerContext, host: &str) -> Result<(), String> {
    match ctx.db.reporter().identity().find(ctx.sender()) {
        Some(r) if r.host == "*" || r.host == host => Ok(()),
        _ => Err(format!("not a reporter for host {host}")),
    }
}

/// Lets another identity report one host (a mirror's writer). Owner only.
#[spacetimedb::reducer]
pub fn allow_reporter(ctx: &ReducerContext, identity: Identity, host: String) -> Result<(), String> {
    may_write(ctx, "*")?;
    ctx.db.reporter().identity().delete(identity);
    ctx.db.reporter().insert(Reporter { identity, host });
    Ok(())
}

fn drop_agent(ctx: &ReducerContext, id: &str) {
    ctx.db.agent().id().delete(id.to_string());
    let keys: Vec<String> = ctx.db.event().agent().filter(&id.to_string()).map(|e| e.key).collect();
    for k in keys {
        ctx.db.event().key().delete(k);
    }
    let tasks: Vec<String> = ctx.db.task().agent().filter(&id.to_string()).map(|t| t.id).collect();
    for t in tasks {
        ctx.db.task().id().delete(t);
    }
}

/// What changed on `host` since its last batch (powos-agentsd, after each flush of its spool).
#[spacetimedb::reducer]
pub fn sync(ctx: &ReducerContext, host: String, batch: String) -> Result<(), String> {
    may_write(ctx, &host)?;
    let b: Batch = serde_json::from_str(&batch).map_err(|e| format!("batch: {e}"))?;
    let prefix = format!("{host}:");
    let mine = |id: &str| id.starts_with(&prefix);
    for id in b.dropped.iter().filter(|id| mine(id)) {
        drop_agent(ctx, id);
    }
    if let Some(st) = b.state {
        sync_agents(ctx, &host, &mine, st.agents);
        sync_tasks(ctx, &mine, st.tasks);
        sync_asks(ctx, &mine, st.asks);
    }
    for (aid, ring) in b.events.into_iter().filter(|(aid, _)| mine(aid)) {
        sync_ring(ctx, &aid, ring);
    }
    if let Some(msgs) = b.messages {
        sync_messages(ctx, msgs);
    }
    Ok(())
}

/// The host's agents: those not in the batch go (with their events and tasks), changed ones are replaced.
fn sync_agents(ctx: &ReducerContext, host: &str, mine: &dyn Fn(&str) -> bool, agents: Vec<AgentRow>) {
    let keep: std::collections::HashSet<&str> = agents.iter().map(|a| a.id.as_str()).collect();
    let gone: Vec<String> =
        ctx.db.agent().host().filter(&host.to_string()).map(|a| a.id).filter(|id| !keep.contains(id.as_str())).collect();
    for id in gone {
        drop_agent(ctx, &id);
    }
    for a in agents.into_iter().filter(|a| mine(&a.id)) {
        // Unchanged rows (same rev) are left alone: no delta to subscribers.
        if ctx.db.agent().id().find(a.id.clone()).is_some_and(|old| old.rev == a.rev && old.state == a.state) {
            continue;
        }
        ctx.db.agent().id().delete(a.id.clone());
        ctx.db.agent().insert(agent_of(host, a));
    }
}

fn agent_of(host: &str, a: AgentRow) -> Agent {
    Agent {
        id: a.id,
        host: host.to_string(),
        role: cut(a.role, 64),
        parent: a.parent,
        state: cut(a.state, 16),
        title: cut(a.title, 80),
        step: cut(a.step, 60),
        cwd: cut(a.cwd, 80),
        pid: a.pid,
        subs: a.subs,
        unread: a.unread,
        report: cut(a.report, 280),
        started: a.started,
        last: a.last,
        rev: a.rev,
    }
}

/// The host's agents' tasks, replaced as a set (at most TASKS_PER_AGENT each).
fn sync_tasks(ctx: &ReducerContext, mine: &dyn Fn(&str) -> bool, tasks: Vec<TaskRow>) {
    let old: Vec<String> = ctx.db.task().iter().filter(|t| mine(&t.agent)).map(|t| t.id).collect();
    for t in old {
        ctx.db.task().id().delete(t);
    }
    let mut per: std::collections::HashMap<String, usize> = Default::default();
    for t in tasks.into_iter().filter(|t| mine(&t.agent)) {
        let n = per.entry(t.agent.clone()).or_default();
        *n += 1;
        if *n > TASKS_PER_AGENT {
            continue;
        }
        ctx.db.task().insert(Task {
            id: t.id,
            agent: t.agent,
            subject: cut(t.subject, 100),
            status: t.status,
            order: t.order,
            updated: t.updated,
        });
    }
}

/// The host's agents' asks, replaced as a set.
fn sync_asks(ctx: &ReducerContext, mine: &dyn Fn(&str) -> bool, asks: Vec<AskRow>) {
    let old: Vec<String> = ctx.db.ask().iter().filter(|a| mine(&a.agent)).map(|a| a.id).collect();
    for a in old {
        ctx.db.ask().id().delete(a);
    }
    for a in asks.into_iter().filter(|a| mine(&a.agent)) {
        ctx.db.ask().insert(Ask {
            id: a.id,
            agent: a.agent,
            tool: cut(a.tool, 64),
            summary: cut(a.summary, 200),
            ts: a.ts,
            expires: a.expires,
            answer: a.answer,
            reason: a.reason,
            by: a.by,
        });
    }
}

/// One agent's ring: its last RING events written (a coalesced one, Read×6, replaced in place), the rest dropped.
fn sync_ring(ctx: &ReducerContext, aid: &str, ring: Vec<EventRow>) {
    let have: std::collections::HashSet<String> = ctx.db.event().agent().filter(&aid.to_string()).map(|e| e.key).collect();
    let start = ring.len().saturating_sub(RING);
    let mut want = std::collections::HashSet::new();
    for e in ring.into_iter().skip(start) {
        let key = format!("{aid}#{}", e.id);
        want.insert(key.clone());
        ctx.db.event().key().delete(key.clone());
        ctx.db.event().insert(Event {
            key,
            id: e.id,
            agent: aid.to_string(),
            ts: e.ts,
            kind: cut(e.kind, 16),
            name: cut(e.name, 64),
            hint: cut(e.hint, 60),
            ok: e.ok,
            n: e.n,
            ms: e.ms,
        });
    }
    for k in have.difference(&want) {
        ctx.db.event().key().delete(k.clone());
    }
}

/// The latest messages: new or changed (read) ones written, whole; past MESSAGES the oldest go.
fn sync_messages(ctx: &ReducerContext, msgs: Vec<MessageRow>) {
    for m in msgs {
        if ctx.db.message().id().find(m.id.clone()).is_some_and(|old| old.read == m.read) {
            continue;
        }
        ctx.db.message().id().delete(m.id.clone());
        ctx.db.message().insert(Message {
            id: m.id,
            from: cut(m.from, 64),
            to: cut(m.to, 64),
            kind: m.kind,
            priority: m.priority,
            ts: m.ts,
            // Whole: the view previews a line and opens the rest (a message is never cut on the way to the user).
            body: m.body,
            read: m.read,
        });
    }
    let mut all: Vec<(u64, String)> = ctx.db.message().iter().map(|m| (m.ts, m.id)).collect();
    if all.len() <= MESSAGES {
        return;
    }
    all.sort();
    let extra = all.len() - MESSAGES;
    for (_, id) in all.into_iter().take(extra) {
        ctx.db.message().id().delete(id);
    }
}

fn now_ms(ctx: &ReducerContext) -> u64 {
    (ctx.timestamp.to_micros_since_unix_epoch().max(0) as u64) / 1000
}

/// Adds or changes one work item (`powos agents task add|set|done`). Empty strings keep what the row has; a new row
/// needs a title. Writers: reporters (the device's PowOS user - the CLI's identity - and what it allowed).
#[spacetimedb::reducer]
pub fn work_set(
    ctx: &ReducerContext,
    id: String,
    title: String,
    owner: String,
    status: String,
    note: String,
    project: String,
) -> Result<(), String> {
    match ctx.db.reporter().identity().find(ctx.sender()) {
        Some(_) => {}
        None => return Err("not a reporter".into()),
    }
    let id = cut(id.trim().to_string(), 64);
    if id.is_empty() {
        return Err("work_set: no id".into());
    }
    if !status.is_empty() && !WORK_STATES.contains(&status.as_str()) {
        return Err(format!("work_set: status is one of {}", WORK_STATES.join("|")));
    }
    let now = now_ms(ctx);
    let old = ctx.db.work().id().find(id.clone());
    let row = match old {
        Some(o) => {
            ctx.db.work().id().delete(id.clone());
            let st = if status.is_empty() { o.status } else { status };
            Work {
                done: if st == "done" { if o.done > 0 { o.done } else { now } } else { 0 },
                id,
                title: if title.trim().is_empty() { o.title } else { cut(title.trim().to_string(), 100) },
                owner: if owner.is_empty() { o.owner } else { cut(owner, 64) },
                status: st,
                note: if note.is_empty() { o.note } else { cut(note, 280) },
                created: o.created,
                updated: now,
                project: if project.is_empty() { o.project } else { cut(project, 64) },
                progress_done: o.progress_done,
                progress_total: o.progress_total,
                step: o.step,
                steps: o.steps,
                commits: o.commits,
                images: o.images,
                activity: now,
            }
        }
        None => {
            if title.trim().is_empty() {
                return Err(format!("work_set: no work item '{id}' (a new one needs a title)"));
            }
            let st = if status.is_empty() { "working".to_string() } else { status };
            Work {
                done: if st == "done" { now } else { 0 },
                id,
                title: cut(title.trim().to_string(), 100),
                owner: cut(owner, 64),
                status: st,
                note: cut(note, 280),
                created: now,
                updated: now,
                project: cut(project, 64),
                progress_done: 0,
                progress_total: 0,
                step: String::new(),
                steps: String::new(),
                commits: String::new(),
                images: String::new(),
                activity: now,
            }
        }
    };
    ctx.db.work().insert(row);
    // Bounded: done items leave after a week; past WORK_MAX the oldest done ones go first, then the oldest at all.
    let stale: Vec<String> = ctx.db.work().iter().filter(|w| w.done > 0 && now.saturating_sub(w.done) > WORK_DONE_KEEP_MS).map(|w| w.id).collect();
    for id in stale {
        ctx.db.work().id().delete(id);
    }
    let mut all: Vec<(bool, u64, String)> = ctx.db.work().iter().map(|w| (w.done == 0, w.updated, w.id)).collect();
    if all.len() > WORK_MAX {
        all.sort();
        let extra = all.len() - WORK_MAX;
        for (_, _, id) in all.into_iter().take(extra) {
            ctx.db.work().id().delete(id);
        }
    }
    Ok(())
}

#[derive(Deserialize)]
struct StepIn {
    text: String,
    state: String,
}

#[derive(Deserialize)]
struct CommitIn {
    sha: String,
    #[serde(default)]
    subject: String,
}

const WORK_STEPS_MAX: usize = 100;
const WORK_COMMITS_MAX: usize = 50;
const WORK_IMAGES_MAX: usize = 20;

fn one_line(s: String, n: usize) -> String {
    cut(s.split_whitespace().collect::<Vec<_>>().join(" "), n)
}

/// A JSON-array column: "" stays "", else parsed as [T], the oldest past [cap] dropped, each item [map]ped and the
/// whole stored compact.
fn json_list<T: serde::de::DeserializeOwned, F: Fn(T) -> Result<serde_json::Value, String>>(
    s: &str,
    what: &str,
    cap: usize,
    map: F,
) -> Result<String, String> {
    if s.trim().is_empty() {
        return Ok(String::new());
    }
    let mut v: Vec<T> = serde_json::from_str(s).map_err(|e| format!("{what}: {e}"))?;
    if v.len() > cap {
        v.drain(..v.len() - cap);
    }
    let out = v.into_iter().map(map).collect::<Result<Vec<_>, _>>()?;
    serde_json::to_string(&out).map_err(|e| e.to_string())
}

fn steps_json(s: &str) -> Result<String, String> {
    json_list::<StepIn, _>(s, "steps", WORK_STEPS_MAX, |st| {
        if !["done", "current", "next"].contains(&st.state.as_str()) {
            return Err("steps: a state is done|current|next".into());
        }
        Ok(serde_json::json!({"text": one_line(st.text, 200), "state": st.state}))
    })
}

fn commits_json(s: &str) -> Result<String, String> {
    json_list::<CommitIn, _>(s, "commits", WORK_COMMITS_MAX, |c| {
        if c.sha.is_empty() || !c.sha.chars().all(|ch| ch.is_ascii_hexdigit()) {
            return Err("commits: a sha is hex".into());
        }
        Ok(serde_json::json!({"sha": cut(c.sha, 40), "subject": one_line(c.subject, 200)}))
    })
}

/// A work item's progress, all of it at once (`powos agents task set --progress/--step/--plan/--commit/--image`: the
/// CLI works out the step history from the row and writes the result). `steps`/`commits`/`images` are JSON arrays
/// ("" = none), checked here and stored compact; the oldest past each cap go.
#[spacetimedb::reducer]
pub fn work_track(
    ctx: &ReducerContext,
    id: String,
    progress_done: u32,
    progress_total: u32,
    step: String,
    steps: String,
    commits: String,
    images: String,
) -> Result<(), String> {
    if ctx.db.reporter().identity().find(ctx.sender()).is_none() {
        return Err("not a reporter".into());
    }
    let Some(o) = ctx.db.work().id().find(id.clone()) else {
        return Err(format!("work_track: no work item '{id}'"));
    };
    if progress_done > progress_total {
        return Err(format!("work_track: progress {progress_done}/{progress_total}"));
    }
    let steps = steps_json(&steps)?;
    let commits = commits_json(&commits)?;
    let images = json_list::<String, _>(&images, "images", WORK_IMAGES_MAX, |p| Ok(serde_json::json!(cut(p, 300))))?;
    let now = now_ms(ctx);
    ctx.db.work().id().delete(id.clone());
    ctx.db.work().insert(Work {
        progress_done,
        progress_total,
        step: one_line(step, 200),
        steps,
        commits,
        images,
        activity: now,
        updated: now,
        ..o
    });
    Ok(())
}

/// Removes a work item (a mistake, a duplicate): `powos agents task rm`.
#[spacetimedb::reducer]
pub fn work_drop(ctx: &ReducerContext, id: String) -> Result<(), String> {
    if ctx.db.reporter().identity().find(ctx.sender()).is_none() {
        return Err("not a reporter".into());
    }
    ctx.db.work().id().delete(id);
    Ok(())
}
