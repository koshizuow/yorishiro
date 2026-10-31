//! The node's library finds libraries shipped beside it (libncnn.so.1 in addons/yorishiro_core/lib).
fn main() {
    println!("cargo:rustc-link-arg=-Wl,-rpath,$ORIGIN");
}
