# moc3 inspection tools

Used on 2026-10-31 to find why a test model showed heart, sparkle and swirl eyes on one eye only
(three keyforms of the left eye meshes sat on the right eye), and to fix that model. Built on Katashiro's core, the
moc3 parser from Ayagami, no Cubism SDK (D26).

Build: `cargo build --release -p moc3-tools` (binaries in `target/release/` at the repository root).

| Tool | What it does |
|---|---|
| `load-model X.moc3 > dump.txt` | the core's parser, prints the whole parsed model (Rust Debug) |
| `rsdebug.py dump.txt X.pkl` | turns that dump into a Python pickle (structs to dicts) |
| `param_users.py X.pkl X.cdi3.json ParamA,ParamB` | art meshes, parts and deformers driven by these parameters |
| `deformer_tree.py X.pkl X.cdi3.json Warp1,Warp2` | deformer chain, part, keyform opacity, child meshes |
| `probe X.moc3 "ParamA=1,ParamB=0" ArtMesh1,ArtMesh2` | drives the model and prints visibility, opacity, bbox and draw order (`VERTS=1` for vertices) |
| `copy_keyform.py X.pkl X.moc3 SRC DSTS ArtMesh1,...` | copies one keyform's vertices over others in place, keeps `X.moc3.bak` |

In the app, `--dump-meshes`, `--dump-above`, `--unmask` and `--raise` (lib/automation.gd) show what Godot actually
draws, which is how a wrong vertex buffer is told apart from a wrong mask or draw order.
