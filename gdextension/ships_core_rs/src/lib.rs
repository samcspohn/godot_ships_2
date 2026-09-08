use godot::prelude::*;

pub mod ballistics;
pub mod nav;
pub mod panic_guard;
pub mod projectile;
pub mod variant_cast;

struct ShipsCoreRs;

#[gdextension]
unsafe impl ExtensionLibrary for ShipsCoreRs {}
