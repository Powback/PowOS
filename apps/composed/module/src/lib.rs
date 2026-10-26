//! The one module every composed PowOS app or widget runs (lib/apps/powos-compose, docs/COMPOSER.md), each in a
//! database of its own (`local-<name>`): a composition is a manifest, so composing never builds Rust.
//!
//! It keeps what the composition last read from its building blocks: one `snapshot` row per source (the manifest's
//! `uses[].as`), written by the composition's own widget when a read came back different. So the last state survives
//! a reload and shows greyed while a block is unreachable, and a composition is itself a building block: another
//! composition subscribes to this table (read only) instead of calling the same blocks again.
//!
//! Nothing here reaches another app: the blocks are called through their own surfaces (App API's call path for
//! capability actions), never by writing their tables. Keep schema changes additive (new tables, new columns at the
//! END with `#[default(...)]`): every composed database runs this module.
use spacetimedb::{ReducerContext, Table, Timestamp};

/// Stamped on the rows this module writes: a republished module shows on the next change.
const MODULE: &str = env!("CARGO_PKG_VERSION");
/// A read's JSON as kept (the runtime returns at most 512 KB; a widget's rows are far less).
const MAX_JSON: usize = 256 * 1024;
const MAX_SOURCE: usize = 32;

#[spacetimedb::table(accessor = snapshot, public)]
pub struct Snapshot {
    /// The manifest's `uses[].as` ("rooms").
    #[primary_key]
    source: String,
    /// What the block returned, as JSON.
    json: String,
    at: Timestamp,
    module: String,
}

fn source_ok(source: &str) -> bool {
    !source.is_empty()
        && source.len() <= MAX_SOURCE
        && source.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_' || b == b'-')
}

/// The last read of [source]: replaced whole (unchanged JSON = no write, no update to subscribers).
#[spacetimedb::reducer]
pub fn keep(ctx: &ReducerContext, source: String, json: String) -> Result<(), String> {
    if !source_ok(&source) {
        return Err(format!("source: 1..{MAX_SOURCE} of a-z 0-9 _ -"));
    }
    if json.len() > MAX_JSON {
        return Err(format!("json: at most {MAX_JSON} bytes"));
    }
    if let Some(old) = ctx.db.snapshot().source().find(source.clone()) {
        if old.json == json {
            return Ok(());
        }
        ctx.db.snapshot().source().delete(source.clone());
    }
    ctx.db.snapshot().insert(Snapshot { source, json, at: ctx.timestamp, module: MODULE.into() });
    Ok(())
}

/// Forget every snapshot (the composition's sources changed).
#[spacetimedb::reducer]
pub fn forget(ctx: &ReducerContext) {
    let all: Vec<String> = ctx.db.snapshot().iter().map(|s| s.source).collect();
    for s in all {
        ctx.db.snapshot().source().delete(s);
    }
}
