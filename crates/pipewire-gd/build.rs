//! Builds libfunnel (MIT, thirdparty/libfunnel) into the node: its core and Vulkan parts, linked to the
//! system's libpipewire (1.4 or newer), GBM, libdrm and the Vulkan loader.
fn main() {
    let funnel = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../thirdparty/libfunnel");
    let mut build = cc::Build::new();
    for lib in ["libpipewire-0.3", "gbm", "libdrm", "vulkan"] {
        let found = pkg_config::Config::new()
            .atleast_version(if lib == "libpipewire-0.3" { "1.4" } else { "0" })
            .probe(lib)
            .unwrap_or_else(|e| panic!("{lib}: {e}"));
        build.includes(found.include_paths);
    }
    // libfunnel calls functions inside assert(), so NDEBUG must stay off
    build
        .include(funnel.join("include"))
        .file(funnel.join("src/funnel.c"))
        .file(funnel.join("src/vulkan.c"))
        .flag("-UNDEBUG")
        .warnings(false)
        .compile("funnel");
    println!("cargo:rerun-if-changed={}", funnel.join("src").display());
    println!("cargo:rerun-if-changed={}", funnel.join("include").display());
}
