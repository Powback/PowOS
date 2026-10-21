//! Pet: the face of PowOS's agents (the shell layer: shell/ui/pet.tsx). One small creature the shell floats over home and the PowOS AI page;
//! its look follows what the agents and the phone are doing (the shell works that out from live data),
//! and this module is what it IS and what it SAID - its name, a mood an agent set, energy, level/xp, and the last 50
//! lines spoken through it (`powos pet say`, the shell's bubbles).
//!
//! Times are Unix milliseconds (u64): the CLI and the shell compare them with Date.now() directly.
//! Keep schema changes additive (new tables, new columns at the END with #[default(..)]).
use spacetimedb::{ReducerContext, Table};

/// How many spoken lines are kept.
const KEEP: usize = 50;
const MAX_TEXT: usize = 280;
const MAX_NAME: usize = 24;
/// A mood set with `say --mood` (or set_mood without seconds) holds this long, then the live state shows again.
const MOOD_MS: u64 = 30_000;
/// What a mood may be: the shell's states. "" = none (the live state).
const MOODS: [&str; 8] = ["", "idle", "happy", "working", "looking", "worried", "sleepy", "hungry"];

#[spacetimedb::table(accessor = pet, public)]
pub struct Pet {
    /// Always 0: one pet per device (v2: one per agent role, keyed by role).
    #[primary_key]
    id: u8,
    name: String,
    /// A mood an agent asked for, shown until `mood_until` (ms); "" = none.
    mood: String,
    mood_until: u64,
    /// 0-100 at `fed`; it runs down from there (the UI works out the current value: energy_now).
    energy: u8,
    fed: u64,
    xp: u32,
    level: u32,
    updated: u64,
    /** Over apps too (the PowOS app's pet window, docs/PET.md step d): `powos pet overlay on|off`. */
    #[default(true)]
    overlay: bool,
    /** Where an agent sent it (`powos pet goto`): a tile's name or key, a CSS selector, or "x,y" (CSS px). */
    #[default("")]
    goto_target: String,
    #[default("")]
    goto_say: String,
    /** When (ms): the shell goes once per new value. */
    #[default(0u64)]
    goto_at: u64,
}

#[spacetimedb::table(accessor = said, public)]
pub struct Said {
    #[primary_key]
    #[auto_inc]
    id: u64,
    text: String,
    /// Who spoke through it: "manager", "deploy", an agent's role, "you".
    from: String,
    mood: String,
    at: u64,
}

fn now(ctx: &ReducerContext) -> u64 {
    (ctx.timestamp.to_micros_since_unix_epoch().max(0) as u64) / 1000
}

fn level_of(xp: u32) -> u32 {
    1 + ((xp as f64) / 5.0).sqrt() as u32
}

fn fresh(ctx: &ReducerContext) -> Pet {
    let t = now(ctx);
    Pet { id: 0, name: "Pow".into(), mood: String::new(), mood_until: 0, energy: 80, fed: t, xp: 0, level: 1, updated: t, overlay: true, goto_target: String::new(), goto_say: String::new(), goto_at: 0 }
}

/// The pet's row (made the first time), changed by [f] and written back.
fn with_pet(ctx: &ReducerContext, f: impl FnOnce(&mut Pet, u64)) {
    let t = now(ctx);
    let existing = ctx.db.pet().id().find(0);
    let had = existing.is_some();
    let mut p = existing.unwrap_or_else(|| fresh(ctx));
    f(&mut p, t);
    p.level = level_of(p.xp);
    p.updated = t;
    if had {
        ctx.db.pet().id().update(p);
    } else {
        ctx.db.pet().insert(p);
    }
}

fn check_mood(mood: &str) -> Result<String, String> {
    let m = mood.trim().to_lowercase();
    if MOODS.contains(&m.as_str()) {
        Ok(m)
    } else {
        Err(format!("mood: one of {}", MOODS[1..].join(", ")))
    }
}

#[spacetimedb::reducer(init)]
pub fn init(ctx: &ReducerContext) {
    if ctx.db.pet().id().find(0).is_none() {
        ctx.db.pet().insert(fresh(ctx));
    }
}

/// Speaks through the pet: a line in its bubble (and its history); [mood] ("" = keep) shows for 30 s.
#[spacetimedb::reducer]
pub fn say(ctx: &ReducerContext, text: String, mood: String, from: String) -> Result<(), String> {
    let text = text.trim().to_string();
    if text.is_empty() || text.chars().count() > MAX_TEXT {
        return Err(format!("text: 1..{MAX_TEXT} characters"));
    }
    let mood = check_mood(&mood)?;
    let from: String = from.trim().chars().take(32).collect();
    let t = now(ctx);
    ctx.db.said().insert(Said { id: 0, text, from: if from.is_empty() { "agent".into() } else { from }, mood: mood.clone(), at: t });
    // The oldest go: the last KEEP stay.
    let mut ids: Vec<u64> = ctx.db.said().iter().map(|s| s.id).collect();
    if ids.len() > KEEP {
        ids.sort_unstable();
        for id in &ids[..ids.len() - KEEP] {
            ctx.db.said().id().delete(*id);
        }
    }
    with_pet(ctx, |p, t| {
        p.xp = p.xp.saturating_add(1);
        if !mood.is_empty() {
            p.mood = mood;
            p.mood_until = t + MOOD_MS;
        }
    });
    Ok(())
}

/// A mood for [seconds] (0: 30 s); "" clears it (the live state again).
#[spacetimedb::reducer]
pub fn set_mood(ctx: &ReducerContext, mood: String, seconds: u32) -> Result<(), String> {
    let mood = check_mood(&mood)?;
    with_pet(ctx, |p, t| {
        p.mood_until = if mood.is_empty() { 0 } else { t + if seconds == 0 { MOOD_MS } else { seconds as u64 * 1000 } };
        p.mood = mood;
    });
    Ok(())
}

/// Fed: full energy, a little xp, happy for a moment.
#[spacetimedb::reducer]
pub fn feed(ctx: &ReducerContext) {
    with_pet(ctx, |p, t| {
        p.energy = 100;
        p.fed = t;
        p.xp = p.xp.saturating_add(3);
        p.mood = "happy".into();
        p.mood_until = t + 4000;
    });
}

/// Something went well (a task done, a pat): xp, no mood of its own (the shell jumps).
#[spacetimedb::reducer]
pub fn cheer(ctx: &ReducerContext, xp: u32) {
    with_pet(ctx, |p, _| p.xp = p.xp.saturating_add(xp.clamp(1, 10)));
}

#[spacetimedb::reducer]
pub fn rename(ctx: &ReducerContext, name: String) -> Result<(), String> {
    let name = name.trim().to_string();
    if name.is_empty() || name.chars().count() > MAX_NAME {
        return Err(format!("name: 1..{MAX_NAME} characters"));
    }
    with_pet(ctx, |p, _| p.name = name);
    Ok(())
}

/// Forgets what it said (the history), keeps the pet.
#[spacetimedb::reducer]
pub fn hush(ctx: &ReducerContext) {
    let ids: Vec<u64> = ctx.db.said().iter().map(|s| s.id).collect();
    for id in ids {
        ctx.db.said().id().delete(id);
    }
}

/// The pet over apps on or off (the shell passes it to the PowOS app).
#[spacetimedb::reducer]
pub fn set_overlay(ctx: &ReducerContext, on: bool) {
    with_pet(ctx, |p, _| p.overlay = on);
}

/// Sends it somewhere on screen (the shell walks/jumps there and says [say] on arrival, if anything).
#[spacetimedb::reducer]
pub fn goto(ctx: &ReducerContext, target: String, say: String) -> Result<(), String> {
    let target = target.trim().to_string();
    if target.is_empty() || target.chars().count() > 200 {
        return Err("target: 1..200 characters".into());
    }
    let say: String = say.trim().chars().take(MAX_TEXT).collect();
    with_pet(ctx, |p, t| {
        p.goto_target = target;
        p.goto_say = say;
        p.goto_at = t;
    });
    Ok(())
}
