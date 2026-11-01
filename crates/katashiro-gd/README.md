# Ayagami-gd

Godot bindings for [Ayagami](https://github.com/AyagamiDev/ayagami), enabling MOC3 models to be imported or loaded at runtime as Scenes.

Features
- importing `.model3.json` as `PackedScene` resources
- loading `.model3.json` at runtime as Scenes
- importing `.motion3.json` as `Animation` resources
- importing models with motion libraries, consisting of all path relative animations
- import `.exp3.json` expressions
- control expressions with tweenable weights or groupable toggle states

## Rendering in Godot

Katashiro runs on official Godot builds. Live2D's blend modes are drawn with Godot's own: normal as premultiplied
alpha, multiply as `blend_mul` over a white-filled colour, additive as `blend_add` with the colour scaled so its
largest premultiplied channel becomes the alpha. Upstream Ayagami needed an engine patch
(godotengine/godot#116686) instead.

## Asset Attribution

Godot Editor Icons<br>
https://godotengine.github.io/editor-icons/

