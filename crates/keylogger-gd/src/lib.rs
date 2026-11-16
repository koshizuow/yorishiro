mod keylogger;

// Windows: GetAsyncKeyState polling (windows.rs, added for Yorishiro)
#[cfg(target_os = "windows")]
mod windows;

#[cfg(target_os = "macos")]
mod noop;

#[cfg(target_os = "linux")]
mod linuxbsd;
