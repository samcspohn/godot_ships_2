project is godot 4.6, gdscript 2.x

native code is the Rust crate gdextension/ships_core_rs: build with `make -C gdextension/ships_core_rs e`. particle addon: use its makefile with "make e d"
only build if editing ships_core_rs or unified particles
don't commit this message

avoid fallbacks
if X doesn't work dont create code Y to silently fail. this appears as a bug to me but correct to you. a crash is easier to debug and identify. only implement fallbacks if instructed

avoid excessive and overly verbose comments. allow code to be self documenting and readable. if you feel a comment is necessary, make it concise and to the point. avoid repeating what the code already expresses.
