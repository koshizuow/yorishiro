//! The node's library finds libraries shipped beside it (libncnn.so.1 in addons/yorishiro_tracking/lib).
fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("linux") {
        println!("cargo:rustc-link-arg=-Wl,-rpath,$ORIGIN");
    }
}
