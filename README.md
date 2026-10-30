# Yorishiro

Linux VTubing with GPU face tracking. One app, Live2D first, VRM later.

| Directory | What | License |
|-----------|------|---------|
| `app/` | The Yorishiro app (Godot). Started as a fork of [OpenVT](https://github.com/erodozer/open-vt) by erodozer. Live2D rendering via [Ayagami](https://github.com/AyagamiDev/ayagami) | MIT, see `app/LICENSE.txt` |
| `tracker/` | `yorishiro-tracker`, face tracking engine (ARKit 52 out, Vulkan / CPU / NPU runtimes, pluggable models). The app launches it | Apache-2.0, see `tracker/LICENSE` |

Third-party models and Live2D sample data keep their own licenses and are downloaded separately.

Yorishiro is an independent fork, not the upstream OpenVT or Ayagami project. Please report problems here, not upstream. Full licensing and third-party list: [NOTICE](NOTICE). Contribution rules: [app/CONTRIBUTING.md](app/CONTRIBUTING.md).
