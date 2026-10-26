//! __NAME__'s logic: a PowOS app module in the device's own SpacetimeDB (Tier 0 - no process of its own).
//! Tables are the app's state, reducers its actions: the UI (ui/pages, ui/widgets) subscribes to the tables and calls
//! the reducers, and every surface showing the app sees each change live.
//!
//! Hot reload: `powos app publish` (or `powos app dev`) swaps this module in place, clients connected throughout.
//! Keep schema changes additive - a new table, or a new column at the END of a table with
//! `#[default(...)]` - so the data migrates in place; renaming or removing a column is refused by the server.
use spacetimedb::{ReducerContext, Table, Timestamp};

/// Stamped on the rows this module writes: a republished module shows on the next change.
const MODULE: &str = env!("CARGO_PKG_VERSION");
const MAX_TEXT: usize = 200;

#[spacetimedb::table(accessor = entry, public)]
pub struct Entry {
    #[primary_key]
    #[auto_inc]
    id: u64,
    text: String,
    done: bool,
    at: Timestamp,
    module: String,
}

#[spacetimedb::reducer]
pub fn add(ctx: &ReducerContext, text: String) -> Result<(), String> {
    let text = text.trim().to_string();
    if text.is_empty() || text.len() > MAX_TEXT {
        return Err(format!("text: 1..{MAX_TEXT} characters"));
    }
    ctx.db.entry().insert(Entry { id: 0, text, done: false, at: ctx.timestamp, module: MODULE.into() });
    Ok(())
}

#[spacetimedb::reducer]
pub fn toggle(ctx: &ReducerContext, id: u64) -> Result<(), String> {
    let mut e = ctx.db.entry().id().find(id).ok_or("no such entry")?;
    e.done = !e.done;
    e.module = MODULE.into();
    ctx.db.entry().id().update(e);
    Ok(())
}

#[spacetimedb::reducer]
pub fn remove(ctx: &ReducerContext, id: u64) {
    ctx.db.entry().id().delete(id);
}

#[spacetimedb::reducer]
pub fn clear_done(ctx: &ReducerContext) {
    let done: Vec<u64> = ctx.db.entry().iter().filter(|e| e.done).map(|e| e.id).collect();
    for id in done {
        ctx.db.entry().id().delete(id);
    }
}
