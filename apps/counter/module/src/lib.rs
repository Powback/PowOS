//! The counter app's logic - a Tier 0 PowOS app (docs/POWOS-APPS-FEASIBILITY.md section 5.2): the whole app is this
//! module in the device's SpacetimeDB plus a static UI; no process of its own. One shared count and the last taps,
//! each stamped with the module version that wrote it, so a hot republish (section 5.4) shows on the next tap while
//! subscribed clients stay connected. Schema changes stay additive.
use spacetimedb::{ReducerContext, Table, Timestamp};

const MODULE: &str = env!("CARGO_PKG_VERSION");
const ONLY: u32 = 0;
const KEEP_TAPS: usize = 20;

#[spacetimedb::table(accessor = counter, public)]
pub struct Counter {
    #[primary_key]
    id: u32,
    value: i64,
    updated_at: Timestamp,
    module: String,
}

#[spacetimedb::table(accessor = tap, public)]
pub struct Tap {
    #[primary_key]
    #[auto_inc]
    id: u64,
    by: i64,
    at: Timestamp,
    module: String,
}

#[spacetimedb::reducer(init)]
pub fn init(ctx: &ReducerContext) {
    if ctx.db.counter().id().find(ONLY).is_none() {
        ctx.db.counter().insert(Counter { id: ONLY, value: 0, updated_at: ctx.timestamp, module: MODULE.into() });
    }
}

fn bump(ctx: &ReducerContext, by: i64) {
    let value = ctx.db.counter().id().find(ONLY).map_or(0, |c| c.value) + by;
    ctx.db.counter().id().delete(ONLY);
    ctx.db.counter().insert(Counter { id: ONLY, value, updated_at: ctx.timestamp, module: MODULE.into() });
    ctx.db.tap().insert(Tap { id: 0, by, at: ctx.timestamp, module: MODULE.into() });
    // The log stays short: the newest KEEP_TAPS.
    let mut ids: Vec<u64> = ctx.db.tap().iter().map(|t| t.id).collect();
    ids.sort_unstable();
    for id in ids.iter().take(ids.len().saturating_sub(KEEP_TAPS)) {
        ctx.db.tap().id().delete(*id);
    }
}

#[spacetimedb::reducer]
pub fn add(ctx: &ReducerContext, by: i64) -> Result<(), String> {
    if by == 0 || by.abs() > 1000 {
        return Err("by: 1..1000 either way".into());
    }
    bump(ctx, by);
    Ok(())
}

#[spacetimedb::reducer]
pub fn reset(ctx: &ReducerContext) {
    let value = ctx.db.counter().id().find(ONLY).map_or(0, |c| c.value);
    if value != 0 {
        bump(ctx, -value);
    }
}
