// Windows: keys and mouse buttons from GetAsyncKeyState once per frame, which sees them while another program has
// the focus (hotkeys during a stream, with the game in front) and needs no administrator. The mouse position comes
// from DisplayServer (the whole screen on Windows). Added for Yorishiro (2026-11-16); upstream's Windows build was
// the no-op one, which only saw keys while its own window had the focus.

use crate::keylogger::{GlobalInput, KeyloggerExtension};
use godot::classes::{DisplayServer, Engine};
use godot::global::{inverse_lerp, Key as GKey, MouseButton};
use godot::prelude::*;

#[link(name = "user32")]
unsafe extern "system" {
    fn GetAsyncKeyState(vkey: i32) -> i16;
}

/// Godot keys and their Windows virtual-key codes
fn table() -> Vec<(GKey, i32)> {
    let mut t: Vec<(GKey, i32)> = Vec::new();
    // letters and digits: Godot's keycodes are their ASCII codes, as are the virtual keys
    for c in (b'A'..=b'Z').chain(b'0'..=b'9') {
        t.push((GKey::from_ord(c as i32), c as i32));
    }
    let f = [
        GKey::F1, GKey::F2, GKey::F3, GKey::F4, GKey::F5, GKey::F6, GKey::F7, GKey::F8, GKey::F9, GKey::F10, GKey::F11,
        GKey::F12, GKey::F13, GKey::F14, GKey::F15, GKey::F16, GKey::F17, GKey::F18, GKey::F19, GKey::F20, GKey::F21,
        GKey::F22, GKey::F23, GKey::F24,
    ];
    for (i, k) in f.into_iter().enumerate() {
        t.push((k, 0x70 + i as i32));
    }
    let kp = [
        GKey::KP_0, GKey::KP_1, GKey::KP_2, GKey::KP_3, GKey::KP_4, GKey::KP_5, GKey::KP_6, GKey::KP_7, GKey::KP_8, GKey::KP_9,
    ];
    for (i, k) in kp.into_iter().enumerate() {
        t.push((k, 0x60 + i as i32));
    }
    t.extend([
        (GKey::SHIFT, 0x10),
        (GKey::CTRL, 0x11),
        (GKey::ALT, 0x12),
        (GKey::META, 0x5B),
        (GKey::ESCAPE, 0x1B),
        (GKey::TAB, 0x09),
        (GKey::BACKSPACE, 0x08),
        (GKey::ENTER, 0x0D),
        (GKey::SPACE, 0x20),
        (GKey::INSERT, 0x2D),
        (GKey::DELETE, 0x2E),
        (GKey::HOME, 0x24),
        (GKey::END, 0x23),
        (GKey::PAGEUP, 0x21),
        (GKey::PAGEDOWN, 0x22),
        (GKey::LEFT, 0x25),
        (GKey::UP, 0x26),
        (GKey::RIGHT, 0x27),
        (GKey::DOWN, 0x28),
        (GKey::PAUSE, 0x13),
        (GKey::CAPSLOCK, 0x14),
        (GKey::PRINT, 0x2C),
        (GKey::SCROLLLOCK, 0x91),
        (GKey::NUMLOCK, 0x90),
        (GKey::KP_MULTIPLY, 0x6A),
        (GKey::KP_ADD, 0x6B),
        (GKey::KP_SUBTRACT, 0x6D),
        (GKey::KP_PERIOD, 0x6E),
        (GKey::KP_DIVIDE, 0x6F),
        (GKey::MINUS, 0xBD),
        (GKey::EQUAL, 0xBB),
        (GKey::BRACKETLEFT, 0xDB),
        (GKey::BRACKETRIGHT, 0xDD),
        (GKey::BACKSLASH, 0xDC),
        (GKey::SEMICOLON, 0xBA),
        (GKey::APOSTROPHE, 0xDE),
        (GKey::COMMA, 0xBC),
        (GKey::PERIOD, 0xBE),
        (GKey::SLASH, 0xBF),
        (GKey::QUOTELEFT, 0xC0),
    ]);
    t
}

fn down(vk: i32) -> bool {
    // the high bit: down now
    unsafe { GetAsyncKeyState(vk) as u16 & 0x8000 != 0 }
}

#[derive(GodotClass)]
#[class(init, singleton, base = Object)]
struct WinKeys {
    keys: Vec<(GKey, i32)>,
}

#[gdextension]
unsafe impl ExtensionLibrary for KeyloggerExtension {
    fn on_stage_init(stage: InitStage) {
        if let InitStage::MainLoop = stage {
            WinKeys::singleton().bind_mut().keys = table();
            // the polling below replaces the node's focus-only input handling
            let mut singleton = GlobalInput::singleton();
            let mut gi = singleton.bind_mut();
            let mut gi_base = gi.base_mut();
            gi_base.set_process(false);
            gi_base.set_process_input(false);
        }
    }

    fn on_main_loop_frame() {
        if Engine::singleton().is_editor_hint() {
            return;
        }
        let keys = WinKeys::singleton().bind().keys.clone();
        let mut singleton = GlobalInput::singleton();
        let mut kl = singleton.bind_mut();
        kl.prev_keystate = kl.keystate.clone();
        for (k, vk) in keys {
            let pressed = down(vk);
            let before = *kl.prev_keystate.get(&k).unwrap_or(&false);
            kl.keystate.insert(k, pressed);
            kl.hold_keystate.insert(k, pressed && before);
        }
        for (b, vk) in [(MouseButton::LEFT, 0x01), (MouseButton::RIGHT, 0x02), (MouseButton::MIDDLE, 0x04)] {
            kl.mousestate.insert(b, down(vk));
        }
        // as GlobalInput's own process(): -1..1 across the screen from its middle
        let dimensions = DisplayServer::singleton().screen_get_size().cast_float();
        let position = DisplayServer::singleton().mouse_get_position().cast_float();
        let half = dimensions / 2.0;
        kl.mouseposition = Vector2 {
            x: inverse_lerp(half.x as f64, dimensions.x as f64, position.x as f64) as f32,
            y: inverse_lerp(half.y as f64, dimensions.y as f64, position.y as f64) as f32,
        };
    }
}
