macro_rules! names {
    ($($f:ident),* ; $($c:ident = $s:literal),*) => {
        struct Names { $($f: StringName,)* $($c: StringName,)* }
        impl Names {
            fn new() -> Self {
                Self { $($f: StringName::from(stringify!($f)),)* $($c: StringName::from($s),)* }
            }
        }
    };
}

pub(crate) use names;
