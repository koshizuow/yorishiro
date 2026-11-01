<p align="center">
  <img alt="yorishiro" src="docs/images/logo-wordmark.png" width="360">
</p>

<p align="center">Live2D VTubing for Linux, with its own GPU face tracker.</p>

<p align="center"><a href="README.zh-TW.md">繁體中文</a></p>

![Yorishiro with ずんだもん](docs/images/hero.jpg)

> Yorishiro is in early development. Expect rough edges and breaking changes.

## Features

- **Live2D models.** Models come in with the settings that usually ship with them (parameter bindings,
  hotkeys, physics, idle animation). Rendering by Katashiro, our fork of the Godot bindings of
  [Ayagami](https://github.com/AyagamiDev/ayagami), an independent Live2D renderer: no Live2D Cubism SDK inside.
- **Face tracking built in.** The app starts its own tracker: MediaPipe FaceMesh landmarks fitted to the 52
  ARKit expressions, an eye model trained on synthetic eyes (holds up behind glasses that reflect the
  screen), gaze, head position. Runs on any GPU through Vulkan, on NVIDIA through CUDA or TensorRT, or on the CPU.
- **Hand tracking.** Optional, beside the face on the same GPU runtime: hand position, angle, openness
  and each finger, as the hand inputs Live2D models with hand rigs use.
- **No camera picture on screen.** A 3D head shows what the tracker sees, so a slip of the settings window
  never shows your room on stream. It even puts on glasses when it notices yours, and shows clay hands
  when hand tracking is on.
- **Tune the model to your face.** Guided calibration, range and smoothing per parameter, both eyes blinking
  together, automatic blinking, follow-the-face movement, what to do when tracking is lost, physics strength
  per part.
- **Hotkeys, expressions and items.** A hotkey list and on-screen buttons, expression toggles, Live2D pose
  groups, an item library for pictures and animations, item scenes.
- **Into OBS with a transparent background.** The stage goes to OBS as a PipeWire video stream with alpha,
  without the app's buttons and menus. A v4l2loopback virtual camera and a transparent window work too.
- **Tracking for other apps.** The tracker can also send its data in common face tracking protocols
  (iFacialMocap and the iPhone tracking protocol other VTuber apps read).
- **Plugins.** A local WebSocket API (port 8001, off by default) in the message format VTuber plugins
  already use: move the model, trigger hotkeys and expressions, send tracking values. Each plugin asks you
  once before it may connect.
- **English and Traditional Chinese** interface.

| | |
|---|---|
| ![Tracking settings with the 3D preview head](docs/images/tracking.jpg) | ![Model and item picker](docs/images/models.jpg) |
| Face tracking settings. The 3D head mirrors your face, the camera picture stays off screen. | Models and items, with thumbnails taken from the stage. |
| ![Sensitivity and physics settings](docs/images/sensitivity.jpg) | ![The stage in OBS over a background](docs/images/obs.jpg) |
| Sensitivity, follow-the-face and physics per part. | The stage in OBS through PipeWire, transparent around the model. |

## Requirements

- Linux on x86_64 with a Vulkan capable GPU (AMD and Intel through Mesa, NVIDIA with its driver).
- A webcam.
- For the PipeWire output to OBS: PipeWire 1.4 or newer for building (1.2 or newer at run time on NVIDIA),
  OBS 31 or newer with the [obs-pwvideo](https://github.com/hoshinolina/obs-pwvideo) plugin.

## Build

1. **Engine.** The official [Godot 4.7.2](https://godotengine.org/download/archive/4.7.2-stable/) editor for
   Linux (x86_64, standard, not .NET). Unzip it into `../tools/godot/` next to the repository, where `run.sh` looks
   for it, or set `GODOT=/path/to/godot`.
2. **System packages** (Debian / Ubuntu names):
   `sudo apt install libudev-dev libinput-dev libclang-dev pkg-config meson ninja-build libpipewire-0.3-dev libgbm-dev libdrm-dev libegl-dev libgl-dev libx11-dev`
3. **Rust** 1.94 or newer through [rustup](https://rustup.rs) (distribution packages are often older).
4. **Native addons:**
   ```sh
   git submodule update --init
   cd app && ./build_dependencies.sh && cd ..
   ```
5. **Tracker** ([uv](https://docs.astral.sh/uv/) manages its Python 3.12 environment):
   ```sh
   cd tracker
   uv sync                                   # CPU and Vulkan runtimes
   uv run python tools/export_mediapipe.py   # downloads and converts the face models
   # NVIDIA only, CUDA and TensorRT runtimes in a second environment the app prefers:
   UV_PROJECT_ENVIRONMENT=.venv-nvidia uv sync --no-group ort-cpu --group ort-nvidia
   cd ..
   ```
6. **PipeWire output helper:** `native/funnel_out/build.sh`
7. **Import the project once:** `./run.sh --headless --import`

## Usage

```sh
./run.sh
```

- On the first start a card in the middle of the stage walks you through it: choose a model, check face
  tracking, place the model.
- A Live2D model is a folder with a `.model3.json` file; settings that come with it are read, never
  changed. Models in
  `userdata/yorishiro/Live2DModels/` show up by themselves.
- The tracker starts with the app. Look straight at the camera with a relaxed face for a moment so it
  can take your neutral face, or use **Auto calibrate** on the Sensitivity page.
- Drag the model to move it, scroll to resize it, hold Shift and scroll to tilt it. The gear in the corner
  opens all settings.
- **OBS:** turn on *Send the stage to OBS* in Settings, then add a *PipeWire video* source in OBS and pick
  Yorishiro.
- App data (settings, model library, thumbnails) lives in `userdata/yorishiro/` while running from source.

## Repository

| Directory | What | License |
|-----------|------|---------|
| `app/` | The Yorishiro app (Godot). Started as a fork of [OpenVT](https://github.com/erodozer/open-vt) by erodozer | MIT, see `app/LICENSE.txt` |
| `crates/tracking`, `crates/tracking-gd` | The face tracking core in Rust and its Godot node | Apache-2.0, see `crates/tracking/LICENSE` |
| `crates/katashiro`, `crates/katashiro-gd` | Katashiro, the Live2D renderer: our fork of [Ayagami](https://github.com/AyagamiDev/ayagami) and its Godot bindings | MIT or Apache-2.0 (core), MIT (Godot part) |
| `native/` | The helper that sends the stage to OBS over PipeWire | MIT |
| `thirdparty/` | Upstream code we build: [libfunnel](https://github.com/hoshinolina/libfunnel), godot-keylogger, gd-virtualcamera | Their own |
| `tracker/` | `yorishiro-tracker`, the face tracking engine (ARKit 52 out, pluggable models, Vulkan / CPU / CUDA / TensorRT) | Apache-2.0, see `tracker/LICENSE` |
| `tools/` | Development and test tools | Same as the part they belong to |

Face recordings and models used for testing are kept outside the repository and never committed.

Yorishiro is an independent project. It is not the upstream OpenVT, Ayagami or libfunnel project and is not
endorsed by their authors; please report problems here. Full licensing and the third-party list:
[NOTICE](NOTICE).

## Credits for the pictures

The model in the screenshots is the Live2D sample model ずんだもん (illustration 坂本アヒル, modeling Live2D Inc.).
本作品のキャラクターには株式会社Live2Dの著作物であるサンプルデータが株式会社Live2Dの定める規約に従って用いられています。
ずんだもん: 東北ずん子・ずんだもんプロジェクト. The model files are not part of this repository, get them from
[Live2D's sample page](https://www.live2d.com/learn/sample/zundamon/).

"Live2D" and "Cubism" are trademarks of Live2D Inc. Yorishiro is not affiliated with Live2D Inc.
