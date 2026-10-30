# Contributing to Yorishiro

## Relationship with upstream projects

Yorishiro started as a fork of [OpenVT](https://github.com/erodozer/open-vt) and uses
[Ayagami](https://github.com/AyagamiDev/ayagami-gd) for Live2D rendering. It is an independent
project. Report Yorishiro problems to Yorishiro, not to the upstream projects. See `NOTICE` at the
repository root for licensing.

- OpenVT does not accept contributions written, analyzed or reviewed with AI agents. Yorishiro is
  developed with AI assistance, so changes from this repository must not be submitted to OpenVT.
  Fixes adopted from upstream keep their original authors in git.
- Ayagami follows strict clean-room rules. Yorishiro developers have read Live2D Cubism SDK code
  (the SDK is used as a local reference renderer for testing), so Yorishiro does not contribute to
  Ayagami and keeps its submodule unmodified. Live2D features that Ayagami lacks are implemented in
  the app from public file format documentation, never by copying SDK code.
- Internal names inherited from OpenVT (for example `VtModel` and `.ovt.json` model settings) are
  kept on purpose. They keep model files compatible and make upstream fixes easy to adopt.
  User visible names, identifiers sent to other apps and links must say Yorishiro.

## Godot standards

GDScript is the primary language of the app. Native integrations use godot-rust and live in
`thirdparty/` as git submodules, built into `addons/` by `build_dependencies.sh`.

The app needs Godot 4.7.1 with the Ayagami engine patches (upstream PR godotengine/godot#116686).
Avoid relying on other custom engine changes.

## Live2D material

Never commit Live2D Cubism SDK files or Live2D sample models. They are downloaded by each user
under Live2D's own terms.
