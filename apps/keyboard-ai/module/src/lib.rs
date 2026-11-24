//! Keyboard AI: what the swipe keyboard's AI reply button learned about how the user writes (docs/POWAI-ASSISTANT.md
//! §3.9). Text only, never screenshots. `powos manager --drafts` (lib/ai/manager/reply_learn.py) writes an `offer` per
//! answered draft request and an `outcome` when the keyboard reports what happened to it (picked + the text actually
//! committed, "more", dismissed); it reads the user's committed replies back as few-shot examples and keeps a short
//! per-app / per-contact style `profile`. The app's page ("What the keyboard learned") shows it, switches learning off
//! per app and clears it. Other apps never touch these tables (one DB per app).
//!
//! Bounded: at most MAX_REPLIES reply rows (oldest dropped), none older than REPLY_DAYS; day stats kept STAT_DAYS.
//! Rows carry `origin` (the host that wrote them) and `at` so the per-table sync (docs/REMOTE-POWOS.md §2.5, M7) can
//! merge them last-writer-wins once it exists; powos-app.json lists the synced tables.
//! Reducers take one JSON string (the Rust lint's 4-argument limit; no reducer-only structs, f137).
//! Keep schema changes additive (new tables, new columns at the END with #[default(..)]).
use serde::Deserialize;
use spacetimedb::{ReducerContext, Table};

const DAY_MS: u64 = 86_400_000;
const MAX_REPLIES: usize = 2_000;
const REPLY_DAYS: u64 = 120;
const STAT_DAYS: u64 = 400;
const MAX_DRAFTS: usize = 5;
const MAX_TEXT: usize = 2_000;
const MAX_DRAFT: usize = 600;
const MAX_PROFILE: usize = 1_200;
const ACTIONS: [&str; 4] = ["picked", "more", "dismissed", "offered"];

/// One answered draft request and what became of it.
#[spacetimedb::table(accessor = reply, public)]
pub struct Reply {
    /// The request id the drafts answer carried ("rid"): `<origin>-<ms>-<n>`.
    #[primary_key]
    id: String,
    /// The keyboard's press (its screenshot id): "more" rounds of one press share it - the pick rate counts presses.
    session: String,
    /// The app typed into (Android package).
    #[index(btree)]
    app: String,
    /// The contact / thread title the model read off the screen ("" when none was visible).
    contact: String,
    /// The field's hint ("Message").
    hint: String,
    /// The variations offered, a JSON list of strings.
    drafts: String,
    /// offered (no word yet) | picked | more | dismissed
    action: String,
    /// The picked variation's index, -1 for none.
    picked: i32,
    /// The text actually committed: the field when the user sent it or left it after inserting the draft.
    final_text: String,
    /// Edit distance picked draft -> final text, normalised to 0..1 (0 = sent as drafted); -1 when nothing was picked.
    edit: f32,
    /// The field was sent (cleared by the app / the enter action), not just left.
    sent: bool,
    /// Offered at (Unix ms).
    at: u64,
    /// The outcome's time (0 = none yet).
    done_at: u64,
    origin: String,
}

/// A short style summary regenerated from history by the same AI path (reply_learn.py, off the request path).
#[spacetimedb::table(accessor = profile, public)]
pub struct Profile {
    /// "app|<package>" or "contact|<package>|<contact>"
    #[primary_key]
    id: String,
    #[index(btree)]
    app: String,
    contact: String,
    text: String,
    /// How many committed replies it was made from (the regeneration trigger compares against this).
    outcomes: u32,
    at: u64,
    origin: String,
}

/// Learning switched per app: no row = on.
#[spacetimedb::table(accessor = app_pref, public)]
pub struct AppPref {
    #[primary_key]
    app: String,
    learn: bool,
    at: u64,
    origin: String,
}

/// Counts per local day and app: what the page draws pick rate and edit distance over time from (no text).
#[spacetimedb::table(accessor = day_stat, public)]
pub struct DayStat {
    /// "<day>|<app>"
    #[primary_key]
    id: String,
    /// Midnight UTC (Unix ms) of the day.
    #[index(btree)]
    day: u64,
    app: String,
    /// Button presses that got drafts.
    sessions: u32,
    /// Presses that ended in a pick.
    picks: u32,
    /// Sum and count of the picks' edit distances (mean = edit_sum / edit_n).
    edit_sum: f64,
    edit_n: u32,
}

#[derive(Deserialize)]
struct OfferIn {
    id: String,
    session: String,
    app: String,
    #[serde(default)]
    contact: String,
    #[serde(default)]
    hint: String,
    drafts: Vec<String>,
    #[serde(default)]
    origin: String,
}

#[derive(Deserialize)]
struct OutcomeIn {
    id: String,
    action: String,
    #[serde(default = "minus_one")]
    picked: i32,
    #[serde(default)]
    final_text: String,
    #[serde(default = "minus_one_f")]
    edit: f32,
    #[serde(default)]
    sent: bool,
}

#[derive(Deserialize)]
struct ProfileIn {
    app: String,
    #[serde(default)]
    contact: String,
    text: String,
    outcomes: u32,
    #[serde(default)]
    origin: String,
}

fn minus_one() -> i32 {
    -1
}

fn minus_one_f() -> f32 {
    -1.0
}

fn now_ms(ctx: &ReducerContext) -> u64 {
    (ctx.timestamp.to_micros_since_unix_epoch() / 1000).max(0) as u64
}

fn cut(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}

fn learning(ctx: &ReducerContext, app: &str) -> bool {
    ctx.db.app_pref().app().find(app.to_string()).is_none_or(|p| p.learn)
}

fn stat_id(day: u64, app: &str) -> String {
    format!("{day}|{app}")
}

/// The day's counts for [app] (a new row when none), taken out to be changed and put back with [put_stat].
fn take_stat(ctx: &ReducerContext, at: u64, app: &str) -> DayStat {
    let day = at / DAY_MS * DAY_MS;
    let id = stat_id(day, app);
    let old = ctx.db.day_stat().id().find(id.clone());
    ctx.db.day_stat().id().delete(id.clone());
    old.unwrap_or(DayStat { id, day, app: app.into(), sessions: 0, picks: 0, edit_sum: 0.0, edit_n: 0 })
}

fn put_stat(ctx: &ReducerContext, s: DayStat) {
    ctx.db.day_stat().insert(s);
}

/// One press more that got drafts.
fn count_session(ctx: &ReducerContext, at: u64, app: &str) {
    let mut s = take_stat(ctx, at, app);
    s.sessions += 1;
    put_stat(ctx, s);
}

/// One press ended in a pick, edited by [edit] (< 0: unknown).
fn count_pick(ctx: &ReducerContext, at: u64, app: &str, edit: f32) {
    let mut s = take_stat(ctx, at, app);
    s.picks += 1;
    if edit >= 0.0 {
        s.edit_sum += edit as f64;
        s.edit_n += 1;
    }
    put_stat(ctx, s);
}

/// Old rows out: replies past REPLY_DAYS or beyond MAX_REPLIES (oldest first), stats past STAT_DAYS.
fn expire(ctx: &ReducerContext, now: u64) {
    let cutoff = now.saturating_sub(REPLY_DAYS * DAY_MS);
    let mut rows: Vec<(u64, String)> = ctx.db.reply().iter().map(|r| (r.at, r.id)).collect();
    rows.sort();
    let over = rows.len().saturating_sub(MAX_REPLIES);
    for (i, (at, id)) in rows.into_iter().enumerate() {
        if i < over || at < cutoff {
            ctx.db.reply().id().delete(id);
        }
    }
    let stat_cutoff = now.saturating_sub(STAT_DAYS * DAY_MS);
    let old: Vec<String> = ctx.db.day_stat().iter().filter(|s| s.day < stat_cutoff).map(|s| s.id).collect();
    for id in old {
        ctx.db.day_stat().id().delete(id);
    }
}

/// An answered draft request: the variations offered. Nothing is stored for an app whose learning is off.
#[spacetimedb::reducer]
pub fn offer(ctx: &ReducerContext, json: String) -> Result<(), String> {
    let o: OfferIn = serde_json::from_str(&json).map_err(|e| format!("offer: {e}"))?;
    if o.id.is_empty() || o.id.len() > 100 || o.app.is_empty() || o.app.len() > 200 || o.session.len() > 100 {
        return Err("offer: id/app/session empty or too long".into());
    }
    if !learning(ctx, &o.app) || ctx.db.reply().id().find(o.id.clone()).is_some() {
        return Ok(());
    }
    let now = now_ms(ctx);
    let drafts: Vec<String> = o.drafts.iter().take(MAX_DRAFTS).map(|d| cut(d, MAX_DRAFT)).collect();
    let new_session = !ctx.db.reply().app().filter(&o.app).any(|r| r.session == o.session);
    ctx.db.reply().insert(Reply {
        id: o.id,
        session: o.session,
        app: o.app.clone(),
        contact: cut(&o.contact, 100),
        hint: cut(&o.hint, 200),
        drafts: serde_json::to_string(&drafts).map_err(|e| e.to_string())?,
        action: "offered".into(),
        picked: -1,
        final_text: String::new(),
        edit: -1.0,
        sent: false,
        at: now,
        done_at: 0,
        origin: cut(&o.origin, 64),
    });
    if new_session {
        count_session(ctx, now, &o.app);
    }
    expire(ctx, now);
    Ok(())
}

/// What the keyboard reported for an offer: picked (+ the committed text and its edit distance), more, dismissed.
/// The first outcome of a row counts (the keyboard sends one per round); a later one is ignored. A press counts one
/// pick in the day's stats however many rounds it took.
#[spacetimedb::reducer]
pub fn outcome(ctx: &ReducerContext, json: String) -> Result<(), String> {
    let o: OutcomeIn = serde_json::from_str(&json).map_err(|e| format!("outcome: {e}"))?;
    if !ACTIONS[..3].contains(&o.action.as_str()) {
        return Err(format!("outcome: action {}", o.action));
    }
    let Some(r) = ctx.db.reply().id().find(o.id.clone()) else { return Ok(()) };
    if r.action != "offered" || !learning(ctx, &r.app) {
        return Ok(());
    }
    let picked = o.action == "picked";
    let edit = if picked { o.edit.clamp(-1.0, 1.0) } else { -1.0 };
    let already = picked && ctx.db.reply().app().filter(&r.app).any(|x| x.session == r.session && x.action == "picked");
    let (app, at) = (r.app.clone(), r.at);
    ctx.db.reply().id().update(Reply {
        action: o.action,
        picked: if picked { o.picked.clamp(-1, MAX_DRAFTS as i32) } else { -1 },
        final_text: if picked { cut(&o.final_text, MAX_TEXT) } else { String::new() },
        edit,
        sent: picked && o.sent,
        done_at: now_ms(ctx),
        ..r
    });
    if picked && !already {
        count_pick(ctx, at, &app, edit);
    }
    Ok(())
}

/// A regenerated style profile for an app ("" contact) or one contact in it.
#[spacetimedb::reducer]
pub fn profile_set(ctx: &ReducerContext, json: String) -> Result<(), String> {
    let p: ProfileIn = serde_json::from_str(&json).map_err(|e| format!("profile: {e}"))?;
    if p.app.is_empty() || p.app.len() > 200 || p.contact.len() > 100 {
        return Err("profile: app empty or too long".into());
    }
    if !learning(ctx, &p.app) {
        return Ok(());
    }
    let id = if p.contact.is_empty() { format!("app|{}", p.app) } else { format!("contact|{}|{}", p.app, p.contact) };
    ctx.db.profile().id().delete(id.clone());
    let at = now_ms(ctx);
    ctx.db.profile().insert(Profile { id, app: p.app, contact: p.contact, text: cut(&p.text, MAX_PROFILE), outcomes: p.outcomes, at, origin: cut(&p.origin, 64) });
    Ok(())
}

/// Learning on / off for one app. Off also forgets what was learned there.
#[spacetimedb::reducer]
pub fn set_learn(ctx: &ReducerContext, app: String, learn: bool) -> Result<(), String> {
    if app.is_empty() || app.len() > 200 {
        return Err("set_learn: app".into());
    }
    ctx.db.app_pref().app().delete(app.clone());
    if !learn {
        forget_app(ctx, &app);
        ctx.db.app_pref().insert(AppPref { app, learn, at: now_ms(ctx), origin: String::new() });
    }
    Ok(())
}

fn forget_app(ctx: &ReducerContext, app: &str) {
    let replies: Vec<String> = ctx.db.reply().app().filter(app).map(|r| r.id).collect();
    for id in replies {
        ctx.db.reply().id().delete(id);
    }
    let profiles: Vec<String> = ctx.db.profile().app().filter(app).map(|p| p.id).collect();
    for id in profiles {
        ctx.db.profile().id().delete(id);
    }
    let stats: Vec<String> = ctx.db.day_stat().iter().filter(|s| s.app == app).map(|s| s.id).collect();
    for id in stats {
        ctx.db.day_stat().id().delete(id);
    }
}

/// Forgets what was learned in one app ([app]), or everywhere ("" - the off switches stay as they are).
#[spacetimedb::reducer]
pub fn forget(ctx: &ReducerContext, app: String) {
    if !app.is_empty() {
        forget_app(ctx, &app);
        return;
    }
    let ids: Vec<String> = ctx.db.reply().iter().map(|r| r.id).collect();
    for id in ids {
        ctx.db.reply().id().delete(id);
    }
    let ids: Vec<String> = ctx.db.profile().iter().map(|p| p.id).collect();
    for id in ids {
        ctx.db.profile().id().delete(id);
    }
    let ids: Vec<String> = ctx.db.day_stat().iter().map(|s| s.id).collect();
    for id in ids {
        ctx.db.day_stat().id().delete(id);
    }
}
