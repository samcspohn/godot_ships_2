use godot::prelude::*;

pub mod ballistics;
pub mod combat;
pub mod nav;
pub(crate) mod names;
pub mod panic_guard;
pub mod projectile;
pub mod ship;
pub mod ui;
pub(crate) mod sched;
pub mod variant_cast;

struct ShipsCoreRs;

#[gdextension]
unsafe impl ExtensionLibrary for ShipsCoreRs {}
