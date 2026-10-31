//! With the ncnn feature: compile the small C++ shim (GPU listing, which ncnn's C API lacks) and link
//! libncnn from NCNN_DIR (an install prefix: include/ncnn, lib/libncnn.so).
fn main() {
    println!("cargo:rerun-if-changed=src/ncnn_shim.cpp");
    println!("cargo:rerun-if-env-changed=NCNN_DIR");
    #[cfg(feature = "ncnn")]
    {
        let dir = std::path::PathBuf::from(std::env::var("NCNN_DIR").expect("set NCNN_DIR to ncnn's install prefix"));
        cc::Build::new()
            .cpp(true)
            .file("src/ncnn_shim.cpp")
            .include(dir.join("include/ncnn"))
            .flag_if_supported("-std=c++17")
            .compile("ncnn_shim");
        let lib = dir.join("lib");
        println!("cargo:rustc-link-search=native={}", lib.display());
        println!("cargo:rustc-link-lib=dylib=ncnn");
        // found at run time without LD_LIBRARY_PATH while developing; packaging (B6) ships it beside the app
        println!("cargo:rustc-link-arg=-Wl,-rpath,{}", lib.display());
    }
}
