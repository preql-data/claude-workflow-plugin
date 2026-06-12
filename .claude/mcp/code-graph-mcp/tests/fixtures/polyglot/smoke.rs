// smoke.rs — Rust definition smoke. Tests that struct, fn, impl all
// land as symbols.

pub struct RustThing {
    pub val: i32,
}

impl RustThing {
    pub fn make() -> RustThing {
        RustThing { val: 42 }
    }
}

pub fn rust_main() {
    let _ = RustThing::make();
}
