# Yorishiro app

The Yorishiro VTubing app, built with Godot (official 4.7.2) and Katashiro, our fork of
the Ayagami Live2D renderer's Godot bindings.
It runs Yorishiro's face tracking core (`../crates/tracking`) inside the app as the `yorishiro_tracking` extension.

The app started as a fork of [OpenVT](https://github.com/erodozer/open-vt) by erodozer, released under the
MIT license. Yorishiro has its own interface, theme and names, and is not the OpenVT project. Please report
problems with Yorishiro to Yorishiro, not to OpenVT. See `LICENSE.txt` and the repository's `NOTICE` for
the full attribution and third-party licenses, the app shows them on its About page.

## Running from source

From the repository root:

    ./run.sh

`run.sh` keeps models, settings and logs in `userdata/yorishiro/`. Building the native addons and the
headless import steps are described in the repository README.

## Formats

- Live2D models (`.model3.json`). VTube Studio settings (`.vtube.json`) are read,
  never written.
- Model settings: `<key>.yori.json` in the app's data folder. Settings an OpenVT install left next to a model
  (`.ovt.json`) are imported once.
- Musubi (結繩) node graphs: `*.musubi`. OpenVT `*.blueprint` files can be imported.
