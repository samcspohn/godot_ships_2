//! C++-parity scalar casts for `Variant`.
//!
//! The C++ original read Godot properties with plain casts — `(double)params->get("overmatch")`
//! — which go through Variant's own conversion rules: an `int` property yields a
//! `double`, a `bool` yields 0/1, and a property that does not exist yields a NIL
//! Variant that casts to 0. gdext's `Variant::to::<T>()` is deliberately stricter:
//! it requires the stored Variant type to match exactly and panics otherwise. A
//! literal transliteration therefore panics on GDScript declarations like
//! `@export var overmatch: int`, which arrive as `VariantType::INT`.
//!
//! These helpers restore the C++ behaviour: Godot's relaxed (GDScript-style)
//! conversion, with NIL and any remaining incompatible type falling back to the
//! zero value instead of panicking.

use godot::builtin::AnyArray;
use godot::prelude::*;

/// Lenient scalar reads, matching C++ `(double)variant` / `(int)variant` semantics.
pub trait VariantCast {
    /// `(double)variant`; 0.0 for NIL or a non-numeric Variant.
    fn to_f64(&self) -> f64;
    /// `(float)variant`; 0.0 for NIL or a non-numeric Variant.
    fn to_f32(&self) -> f32;
    /// `(int)variant`; 0 for NIL or a non-numeric Variant. Floats truncate.
    fn to_i32(&self) -> i32;
    /// `(int64_t)variant`; 0 for NIL or a non-numeric Variant. Floats truncate.
    fn to_i64(&self) -> i64;
    /// `(bool)variant`; false for NIL or a non-convertible Variant.
    fn to_bool(&self) -> bool;
    /// `(Array)variant`, accepting TYPED arrays; empty for anything else.
    ///
    /// `VarArray` is `Array<Variant>` and its `ffi_from_variant` runs
    /// `with_checked_type()`, so a GDScript `var fires: Array[Fire]` read as
    /// `VarArray` panics even though C++ `Array fires = obj->get("fires")` was
    /// happy with it. `AnyArray` is the covariant, read-only array type that
    /// accepts both, and is what every array arriving from GDScript must use.
    fn to_any_array(&self) -> AnyArray;
}

impl VariantCast for Variant {
    fn to_f64(&self) -> f64 {
        self.try_to_relaxed::<f64>().unwrap_or_default()
    }

    fn to_f32(&self) -> f32 {
        self.try_to_relaxed::<f64>().unwrap_or_default() as f32
    }

    fn to_i32(&self) -> i32 {
        self.try_to_relaxed::<i64>().unwrap_or_default() as i32
    }

    fn to_i64(&self) -> i64 {
        self.try_to_relaxed::<i64>().unwrap_or_default()
    }

    fn to_bool(&self) -> bool {
        self.try_to_relaxed::<bool>().unwrap_or_default()
    }

    fn to_any_array(&self) -> AnyArray {
        self.try_to::<AnyArray>()
            .unwrap_or_else(|_| VarArray::new().upcast_any_array())
    }
}
