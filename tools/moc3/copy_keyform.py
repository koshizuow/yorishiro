"""Copy one art mesh keyform's vertices over other keyforms of the same mesh, in place in a .moc3.

    python3 -I moc3_copy_keyform.py MODEL.pkl MODEL.moc3 SRC_FORM DST_FORMS ArtMeshA[,ArtMeshB...]

MODEL.pkl comes from `load-model MODEL.moc3 > dump.txt; rsdebug.py dump.txt MODEL.pkl` (Ayagami's parser).
Form numbers count within the mesh, first binding parameter fastest (form = i0 + n0 * i1).
The vertex_coord section is found by its first values, starts are in floats. Writes MODEL.moc3.bak once.
"""
import pickle, shutil, struct, sys
from pathlib import Path

pkl, moc, src, dsts, names = sys.argv[1], Path(sys.argv[2]), int(sys.argv[3]), [int(x) for x in sys.argv[4].split(",")], sys.argv[5].split(",")
m = pickle.load(open(pkl, "rb"))
v = lambda x: x["v"] if isinstance(x, dict) else x
vals = [q["v"] for q in m["vertex_coord"]["values"]]
raw = bytearray(moc.read_bytes())
head = struct.pack("<8f", *[c for p in vals[:4] for c in p])
assert raw.count(head) == 1, "vertex_coord start not unique"
base = raw.find(head)
A, F = m["art_mesh"], m["art_mesh_form"]
for n in names:
    a = A["id"].index(n); f0 = v(A["i_forms"][a]); c = A["vertex_count"][a]
    start = lambda k: v(F["i_start_vertex"][f0 + k])
    data = raw[base + start(src) * 4: base + (start(src) + 2 * c) * 4]
    for k in dsts:
        raw[base + start(k) * 4: base + (start(k) + 2 * c) * 4] = data
    print(f"{n}: form {src} -> {dsts} ({c} vertices)")
bak = moc.with_name(moc.name + ".bak")
if not bak.exists():
    shutil.copy2(moc, bak)
moc.write_bytes(raw)
