//! Panic containment for the Godot-facing entry points.
//!
//! A Rust panic crossing the FFI boundary aborts the process. gdext converts a
//! panic inside a `#[func]` into "Invalid call error code 1337", which names
//! neither the panic message nor where it happened. This installs a hook that
//! prints the message, the source location and a full Rust backtrace into the
//! Godot console, and gives callers `guard()` to contain a panic so one bad
//! frame is skipped instead of taking the whole game down.

use godot::global::{godot_error, godot_print};
use std::backtrace::Backtrace;
use std::panic::{self, AssertUnwindSafe};
use std::sync::Once;

static HOOK: Once = Once::new();

/// Idempotent; safe to call from every entry point.
pub fn install() {
    HOOK.call_once(|| {
        panic::set_hook(Box::new(|info| {
            // Captured here, inside the hook, because the panicking stack is
            // still live at this point — by the time catch_unwind returns it
            // has already been unwound.
            let backtrace = Backtrace::force_capture();

            let payload = info
                .payload()
                .downcast_ref::<&str>()
                .map(|s| (*s).to_string())
                .or_else(|| info.payload().downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "<non-string panic payload>".to_string());

            let location = info
                .location()
                .map(|l| format!("{}:{}:{}", l.file(), l.line(), l.column()))
                .unwrap_or_else(|| "<unknown location>".to_string());

            godot_error!(
                "[ships_core_rs] RUST PANIC\n  message : {payload}\n  location: {location}"
            );
            // Separate call: the backtrace is long and Godot truncates very
            // long single messages in some consoles.
            godot_print!("[ships_core_rs] Rust backtrace:\n{backtrace}");
        }));
    });
}

/// Run `body`, containing any panic. Returns false if it panicked.
///
/// The hook above has already printed the message, location and backtrace by
/// the time this returns, so the caller only needs to say which entry point
/// was lost.
pub fn guard<F: FnOnce()>(what: &str, body: F) -> bool {
    install();
    if panic::catch_unwind(AssertUnwindSafe(body)).is_err() {
        godot_error!("[ships_core_rs] {what} panicked — frame skipped (details above)");
        false
    } else {
        true
    }
}
