//! v4's SalvoClock shell read: what each enemy is loading against us, from the type of its salvos landing here.

use std::collections::HashMap;

/// Landings further apart than this start a new salvo.
const SALVO_GAP_S: f64 = 3.0;

#[derive(Default, Clone, Copy)]
struct Seen {
    last_land: f64,
    /// The last two salvo types, newest last; None: not seen.
    types: [Option<bool>; 2],
}

#[derive(Default)]
pub struct ShellReads {
    by: HashMap<i64, Seen>,
}

impl ShellReads {
    /// A shell from `shooter` landing at `land_t`, HE or not.
    pub fn note(&mut self, shooter: i64, land_t: f64, he: bool) {
        let s = self.by.entry(shooter).or_insert(Seen { last_land: f64::NEG_INFINITY, types: [None; 2] });
        if land_t - s.last_land > SALVO_GAP_S {
            s.types = [s.types[1], Some(he)];
        }
        s.last_land = s.last_land.max(land_t);
    }

    /// 0 = AP after one AP salvo, 1 = HE after two HE in a row; None: price the worse.
    pub fn read(&self, shooter: i64) -> Option<usize> {
        match self.by.get(&shooter)?.types {
            [_, Some(false)] => Some(0),
            [Some(true), Some(true)] => Some(1),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ap_at_once_he_after_two() {
        let mut r = ShellReads::default();
        assert_eq!(r.read(1), None);
        r.note(1, 10.0, true);
        r.note(1, 10.5, true);
        assert_eq!(r.read(1), None);
        r.note(1, 20.0, true);
        assert_eq!(r.read(1), Some(1));
        r.note(1, 30.0, false);
        assert_eq!(r.read(1), Some(0));
        r.note(1, 40.0, true);
        assert_eq!(r.read(1), None);
    }
}
