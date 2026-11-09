//! Progress: how far PowOS is from being the user's everyday phone (the user, 2026-10-31 02:15: "a widget which tracks
//! how much is left of the PowOS development ... use PowOS to develop itself"). A PowOS app module in the device's own
//! SpacetimeDB (Tier 0 - no process of its own).
//!
//! This module holds ONE thing of its own: the daily-driver checklist - plain capabilities ("Calls + SMS work",
//! "Typing in every app"), each with its area, its state (works / partly / broken / untested) and the board tasks it
//! links to. The manager owns it and edits it with `powos progress item add|set|list|rm` (lib/apps/powos-progress-cli).
//!
//! The board itself (what the agents are on) is NOT here: it is the powos-agents module's `work` table, which the UI
//! subscribes to read-only (one DB per app; another app's data only through its subscriptions). This module never
//! writes it and never copies it.
//!
//! It also holds the known hacks: the HACK registry (docs/REMOTE-POWOS.md §4, kept in step with the code's markers by
//! test/tier1/test-hack-registry.sh), pushed whole on every ship (`powos progress hacks sync`, from
//! tools/phone/ship.sh) - a hack leaves the table when its registry row goes.
//!
//! Keep schema changes additive - a new table, or a new column at the END with `#[default(...)]`.
use serde::Deserialize;
use spacetimedb::{Identity, ReducerContext, Table};

/// Stamped on the rows this module writes: a republished module shows on the next change.
const MODULE: &str = env!("CARGO_PKG_VERSION");
const MAX_TEXT: usize = 200;
const MAX_ITEMS: usize = 300;
const STATES: [&str; 4] = ["works", "partly", "broken", "untested"];

/// Who may change the checklist: the module's owner (the device's PowOS user, which published it - the CLI's
/// identity) and identities it adds with `allow_writer`. Private: only the module reads it.
#[spacetimedb::table(accessor = writer)]
pub struct Writer {
    #[primary_key]
    identity: Identity,
}

/// One daily-driver capability: what the user needs from their phone, in plain words, and whether it holds today.
#[spacetimedb::table(accessor = item, public)]
pub struct Item {
    /// A short slug ("calls-sms"): what the CLI names it by.
    #[primary_key]
    id: String,
    /// What it's part of ("Calls & messages", "Notifications"): the widget's bars and the page's sections group by it.
    area: String,
    /// The capability, one plain line ("Calls + SMS work").
    capability: String,
    /// "works" | "partly" | "broken" | "untested".
    state: String,
    /// The board tasks (powos-agents `work` ids) it hangs on, comma-separated ("" = none).
    tasks: String,
    /// One line on why it's in that state ("drops calls on the cover screen"), "" when none.
    note: String,
    /// Its place in its area (lower first; ties by id).
    rank: u32,
    created: u64,
    /// When it last changed (ms).
    updated: u64,
    module: String,
}

#[spacetimedb::reducer(init)]
pub fn init(ctx: &ReducerContext) {
    ctx.db.writer().insert(Writer { identity: ctx.sender() });
}

fn may_write(ctx: &ReducerContext) -> Result<(), String> {
    match ctx.db.writer().identity().find(ctx.sender()) {
        Some(_) => Ok(()),
        None => Err("only the checklist's owner changes it (powos progress item ...)".into()),
    }
}

/// Lets another identity change the checklist. Owner only.
#[spacetimedb::reducer]
pub fn allow_writer(ctx: &ReducerContext, identity: Identity) -> Result<(), String> {
    may_write(ctx)?;
    ctx.db.writer().identity().delete(identity);
    ctx.db.writer().insert(Writer { identity });
    Ok(())
}

fn now_ms(ctx: &ReducerContext) -> u64 {
    (ctx.timestamp.to_micros_since_unix_epoch() / 1000).max(0) as u64
}

fn text(name: &str, v: String, empty_ok: bool) -> Result<String, String> {
    let v = v.trim().to_string();
    if (!empty_ok && v.is_empty()) || v.len() > MAX_TEXT {
        return Err(format!("{name}: {}..{MAX_TEXT} characters", if empty_ok { 0 } else { 1 }));
    }
    Ok(v)
}

/// One item as the CLI sends it (`item_put`'s JSON): every field, the CLI having merged `set`'s changes onto the row it
/// read.
#[derive(Deserialize)]
struct ItemIn {
    id: String,
    area: String,
    capability: String,
    state: String,
    #[serde(default)]
    tasks: String,
    #[serde(default)]
    note: String,
    #[serde(default)]
    rank: u32,
}

/// [tasks]: comma-separated board ids, kept in order without repeats.
fn task_list(tasks: &str) -> Result<String, String> {
    let mut seen: Vec<&str> = Vec::new();
    for t in tasks.split(',').map(str::trim).filter(|t| !t.is_empty()) {
        if !seen.contains(&t) {
            seen.push(t);
        }
    }
    text("tasks", seen.join(","), true)
}

/// A checked row from [i] (its times and module stamped by the caller).
fn checked(i: ItemIn) -> Result<Item, String> {
    let id = text("id", i.id, false)?;
    if !id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_') {
        return Err("id: letters, digits, - and _ only".into());
    }
    let state = i.state.trim().to_lowercase();
    if !STATES.contains(&state.as_str()) {
        return Err(format!("state: one of {}", STATES.join(", ")));
    }
    Ok(Item {
        id,
        area: text("area", i.area, false)?,
        capability: text("capability", i.capability, false)?,
        state,
        tasks: task_list(&i.tasks)?,
        note: text("note", i.note, true)?,
        rank: i.rank,
        created: 0,
        updated: 0,
        module: MODULE.into(),
    })
}

/// Adds or replaces one item, whole: [item] is its JSON ({id, area, capability, state, tasks, note, rank}).
#[spacetimedb::reducer]
pub fn item_put(ctx: &ReducerContext, item: String) -> Result<(), String> {
    may_write(ctx)?;
    let mut row = checked(serde_json::from_str::<ItemIn>(&item).map_err(|e| format!("item: {e}"))?)?;
    let now = now_ms(ctx);
    let old = ctx.db.item().id().find(row.id.clone());
    if old.is_none() && ctx.db.item().count() as usize >= MAX_ITEMS {
        return Err(format!("the checklist holds {MAX_ITEMS} items at most"));
    }
    row.created = old.as_ref().map_or(now, |o| o.created);
    row.updated = now;
    if old.is_some() {
        ctx.db.item().id().update(row);
    } else {
        ctx.db.item().insert(row);
    }
    Ok(())
}

#[spacetimedb::reducer]
pub fn item_rm(ctx: &ReducerContext, id: String) -> Result<(), String> {
    may_write(ctx)?;
    if !ctx.db.item().id().delete(id.trim().to_string()) {
        return Err(format!("no item {id}"));
    }
    Ok(())
}

/// One known hack: a registry row (docs/REMOTE-POWOS.md §4) with its marker's place and age.
#[spacetimedb::table(accessor = hack, public)]
pub struct Hack {
    /// "<file>#<n>": the file's n-th registry row (line numbers move with every edit above them).
    #[primary_key]
    key: String,
    file: String,
    /// The marker's line as of the registry's last edit.
    line: u32,
    /// Where it is, in plain words ("Home & launcher", "Agents & tooling"): from its path.
    area: String,
    /// Why it's a hack: what it works around (the registry's "why").
    why: String,
    /// The real fix (the registry's "real fix").
    fix: String,
    /// The board task for the real fix, when the fix names one ("" = none yet).
    task: String,
    /// When the marker came into the tree (ms; 0 = unknown).
    since: u64,
    updated: u64,
}

#[derive(Deserialize)]
struct HackIn {
    file: String,
    #[serde(default)]
    line: u32,
    #[serde(default)]
    area: String,
    why: String,
    #[serde(default)]
    fix: String,
    #[serde(default)]
    task: String,
    #[serde(default)]
    since: u64,
}

const MAX_HACKS: usize = 1000;
const MAX_HACK_TEXT: usize = 600;

fn clip(s: String) -> String {
    if s.len() <= MAX_HACK_TEXT {
        return s;
    }
    let mut end = MAX_HACK_TEXT;
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}...", &s[..end])
}

fn hack_rows(hacks: Vec<HackIn>, now: u64) -> Vec<Hack> {
    let mut per_file: std::collections::HashMap<String, u32> = std::collections::HashMap::new();
    hacks
        .into_iter()
        .map(|h| {
            let n = per_file.entry(h.file.clone()).or_insert(0);
            *n += 1;
            Hack {
                key: format!("{}#{}", h.file, n),
                file: h.file,
                line: h.line,
                area: h.area,
                why: clip(h.why),
                fix: clip(h.fix),
                task: h.task,
                since: h.since,
                updated: now,
            }
        })
        .collect()
}

/// The whole registry, replacing what's here ([hacks]: a JSON array of {file, line, area, why, fix, task, since}).
#[spacetimedb::reducer]
pub fn hacks_sync(ctx: &ReducerContext, hacks: String) -> Result<(), String> {
    may_write(ctx)?;
    let list: Vec<HackIn> = serde_json::from_str(&hacks).map_err(|e| format!("hacks: {e}"))?;
    if list.len() > MAX_HACKS {
        return Err(format!("hacks: {MAX_HACKS} at most"));
    }
    let rows = hack_rows(list, now_ms(ctx));
    let keep: std::collections::HashSet<String> = rows.iter().map(|h| h.key.clone()).collect();
    let gone: Vec<String> = ctx.db.hack().iter().map(|h| h.key).filter(|k| !keep.contains(k)).collect();
    for k in gone {
        ctx.db.hack().key().delete(k);
    }
    for h in rows {
        if ctx.db.hack().key().find(h.key.clone()).is_some() {
            ctx.db.hack().key().update(h);
        } else {
            ctx.db.hack().insert(h);
        }
    }
    Ok(())
}
