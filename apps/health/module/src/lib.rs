//! Health: the one place for the user's health data from every wearable (docs/app-to-widget.md, "Health central").
//! Health Connect (the phone's bridge, powos.health) is the first source: the app's UI side reads it and writes here
//! through `ingest`, the only reducer that adds samples. Other apps never touch these tables (one DB per app); widgets
//! and superwidgets subscribe to `daily` (today and the last days, per type and per source) or ask through appcap.
//!
//! Samples are kept indefinitely (the user's decision): nothing here deletes by age. Times are Unix milliseconds (u64).
//! `daily` is derived from `sample` in the phone's local day (the tz the sync sends); `rebuild` recomputes it.
//! Keep schema changes additive (new tables, new columns at the END with #[default(..)]).
use spacetimedb::{ReducerContext, SpacetimeType, Table};

const DAY_MS: i64 = 86_400_000;
const MAX_BATCH: usize = 5_000;
const KINDS: [&str; 6] = ["steps", "heart_rate", "sleep", "exercise", "weight", "active_calories"];

/// One reading from one wearable's app: what Health Connect holds (steps in a span, a heart-rate beat, a sleep session ...).
#[spacetimedb::table(accessor = sample, public)]
pub struct Sample {
    /// The source's own record id (Health Connect's, heart rate "<id>:<n>"): the same record ingested again replaces it.
    #[primary_key]
    id: String,
    /// steps | heart_rate | sleep | exercise | weight | active_calories
    kind: String,
    start: u64,
    end: u64,
    value: f64,
    /// count | bpm | min | kg | kcal
    unit: String,
    /// The app that wrote it (Android package), i.e. which wearable.
    source: String,
    /// Exercise: its title or type.
    detail: String,
    /// Local midnight (Unix ms) of the day it belongs to: its start; a sleep session, the morning it ended.
    #[index(btree)]
    day: u64,
}

/// A day's figures for one type from one source - what widgets read. sum/count/min/max/last over its samples.
#[spacetimedb::table(accessor = daily, public)]
pub struct Daily {
    /// "<kind>|<source>|<day>"
    #[primary_key]
    id: String,
    kind: String,
    source: String,
    #[index(btree)]
    day: u64,
    sum: f64,
    count: u32,
    min: f64,
    max: f64,
    /// The newest sample's value (by its end) and time: the latest weight, the latest heart rate.
    last: f64,
    last_at: u64,
}

/// Where the sync is: one row.
#[spacetimedb::table(accessor = cursor, public)]
pub struct Cursor {
    /// Always 0.
    #[primary_key]
    id: u8,
    /// Health Connect's changes token; "" before the first sync.
    token: String,
    /// The newest sample end ingested (ms): where a read starts again when the token expired.
    newest: u64,
    /// When the last ingest happened.
    synced: u64,
    /// The phone's UTC offset (minutes) the day buckets use.
    tz_min: i32,
}

#[derive(SpacetimeType)]
pub struct Incoming {
    id: String,
    kind: String,
    start: u64,
    end: u64,
    value: f64,
    unit: String,
    source: String,
    detail: String,
}

fn day_of(kind: &str, start: u64, end: u64, tz_min: i32) -> u64 {
    let tz = tz_min as i64 * 60_000;
    let t = (if kind == "sleep" { end } else { start }) as i64;
    ((t + tz).div_euclid(DAY_MS) * DAY_MS - tz).max(0) as u64
}

fn key(kind: &str, source: &str, day: u64) -> String {
    format!("{kind}|{source}|{day}")
}

/// Recomputes one (kind, source, day) row of `daily` from its samples.
fn refresh(ctx: &ReducerContext, kind: &str, source: &str, day: u64) {
    let id = key(kind, source, day);
    let mine: Vec<Sample> = ctx.db.sample().day().filter(day).filter(|s| s.kind == kind && s.source == source).collect();
    ctx.db.daily().id().delete(&id);
    if mine.is_empty() {
        return;
    }
    let newest = mine.iter().max_by_key(|s| s.end).unwrap();
    ctx.db.daily().insert(Daily {
        id,
        kind: kind.into(),
        source: source.into(),
        day,
        sum: mine.iter().map(|s| s.value).sum(),
        count: mine.len() as u32,
        min: mine.iter().map(|s| s.value).fold(f64::INFINITY, f64::min),
        max: mine.iter().map(|s| s.value).fold(f64::NEG_INFINITY, f64::max),
        last: newest.value,
        last_at: newest.end,
    });
}

fn cursor_row(ctx: &ReducerContext) -> Cursor {
    ctx.db.cursor().id().find(0).unwrap_or(Cursor { id: 0, token: String::new(), newest: 0, synced: 0, tz_min: 0 })
}

/// One ingest call: [samples] to add or replace, [deleted] ids the source removed, the changes [token] to continue
/// from ("" keeps the stored one), the phone's UTC offset [tz_min] and the caller's clock [now].
#[derive(SpacetimeType)]
pub struct IngestBatch {
    samples: Vec<Incoming>,
    deleted: Vec<String>,
    token: String,
    tz_min: i32,
    now: u64,
}

/// Adds or replaces [samples], removes [deleted] (records the source deleted), keeps the sync cursor. The only way
/// samples get in. [token]: the changes token to continue from ("" keeps the stored one); [now]: the caller's clock.
#[spacetimedb::reducer]
pub fn ingest(ctx: &ReducerContext, batch: IngestBatch) -> Result<(), String> {
    let IngestBatch { samples, deleted, token, tz_min, now } = batch;
    if samples.len() > MAX_BATCH || deleted.len() > MAX_BATCH {
        return Err(format!("at most {MAX_BATCH} samples per ingest"));
    }
    if !(-14 * 60..=14 * 60).contains(&tz_min) {
        return Err("tz_min: minutes from UTC".into());
    }
    let mut touched: Vec<(String, String, u64)> = Vec::new();
    let mut newest = cursor_row(ctx).newest;
    for gone in deleted.iter().take(MAX_BATCH) {
        // Heart rate ids are "<id>:<n>": a deleted record takes all its beats.
        let ids: Vec<Sample> = ctx.db.sample().iter().filter(|s| s.id == *gone || s.id.starts_with(&format!("{gone}:"))).collect();
        for s in ids {
            touched.push((s.kind.clone(), s.source.clone(), s.day));
            ctx.db.sample().id().delete(&s.id);
        }
    }
    for s in samples {
        if !KINDS.contains(&s.kind.as_str()) {
            return Err(format!("unknown kind {}", s.kind));
        }
        if s.id.is_empty() || s.id.len() > 200 || s.source.len() > 200 || s.unit.len() > 16 || s.detail.len() > 200 {
            return Err("id/source/unit/detail too long or empty".into());
        }
        if !s.value.is_finite() || s.end < s.start {
            return Err(format!("bad sample {}", s.id));
        }
        let day = day_of(&s.kind, s.start, s.end, tz_min);
        if let Some(old) = ctx.db.sample().id().find(&s.id) {
            touched.push((old.kind.clone(), old.source.clone(), old.day));
            ctx.db.sample().id().delete(&s.id);
        }
        newest = newest.max(s.end);
        touched.push((s.kind.clone(), s.source.clone(), day));
        ctx.db.sample().insert(Sample { id: s.id, kind: s.kind, start: s.start, end: s.end, value: s.value, unit: s.unit, source: s.source, detail: s.detail, day });
    }
    touched.sort();
    touched.dedup();
    for (kind, source, day) in touched {
        refresh(ctx, &kind, &source, day);
    }
    let old = cursor_row(ctx);
    let keep = if token.is_empty() { old.token } else { token };
    ctx.db.cursor().id().delete(0);
    ctx.db.cursor().insert(Cursor { id: 0, token: keep, newest, synced: now, tz_min });
    Ok(())
}

/// Forgets the stored changes token (it expired, or the types changed): the next sync reads since `newest` again.
#[spacetimedb::reducer]
pub fn reset_token(ctx: &ReducerContext) {
    let c = cursor_row(ctx);
    ctx.db.cursor().id().delete(0);
    ctx.db.cursor().insert(Cursor { token: String::new(), ..c });
}

/// Buckets every sample into days again with [tz_min] (the phone moved time zone) and rebuilds `daily`.
#[spacetimedb::reducer]
pub fn rebuild(ctx: &ReducerContext, tz_min: i32) -> Result<(), String> {
    if !(-14 * 60..=14 * 60).contains(&tz_min) {
        return Err("tz_min: minutes from UTC".into());
    }
    let all: Vec<Sample> = ctx.db.sample().iter().collect();
    let old: Vec<String> = ctx.db.daily().iter().map(|d| d.id).collect();
    for id in old {
        ctx.db.daily().id().delete(&id);
    }
    let mut keys: Vec<(String, String, u64)> = Vec::new();
    for s in all {
        let day = day_of(&s.kind, s.start, s.end, tz_min);
        keys.push((s.kind.clone(), s.source.clone(), day));
        ctx.db.sample().id().update(Sample { day, ..s });
    }
    keys.sort();
    keys.dedup();
    for (kind, source, day) in keys {
        refresh(ctx, &kind, &source, day);
    }
    let c = cursor_row(ctx);
    ctx.db.cursor().id().delete(0);
    ctx.db.cursor().insert(Cursor { tz_min, ..c });
    Ok(())
}
