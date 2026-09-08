use godot::prelude::*;

pub mod ballistics;
pub mod nav;
pub mod projectile;

struct ShipsCoreRs;

#[gdextension]
unsafe impl ExtensionLibrary for ShipsCoreRs {}
