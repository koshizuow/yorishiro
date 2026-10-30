# usage: python3 -I param_users.py MODEL.pkl MODEL.cdi3.json ParamA,ParamB
import pickle, json, sys
m = pickle.load(open(sys.argv[1], "rb"))
v = lambda x: x["v"] if isinstance(x, dict) else x
exec(open(__file__.rsplit("/", 1)[0] + "/bindings_lib.py").read())
parts = m["part"]; pid = parts["id"]
cdi = {p["Id"]: p["Name"] for p in json.load(open(sys.argv[2]))["Parts"]}
def part_path(i):
    names = []
    while i is not None and i != -1:
        names.append(cdi.get(pid[i], pid[i])); par = parts["i_parent"][i]; i = v(par) if par not in (None, "None") else None
        if isinstance(i, int) and i < 0: break
    return "/".join(reversed(names))
A = m["art_mesh"]; F = m["art_mesh_form"]
want = set(sys.argv[3].split(","))
for i in range(A["count"]):
    b = binding(v(A["i_param_map_set"][i]))
    if want & {p for p, _ in b}:
        f0 = v(A["i_forms"][i]); op = F["opacity"][f0:f0 + A["cnt_forms"][i]]
        print(A["id"][i], "| part", part_path(v(A["i_part"][i])), "| deformer", A["i_deformer"][i], "| tex", A["texture"][i], "| clips", A["cnt_clips"][i])
        print("    keys", b, "opacity", [round(x, 2) for x in op])
for kind in ("part",):
    for i in range(parts["count"]):
        b = binding(v(parts["i_param_map_set"][i]))
        if want & {p for p, _ in b}: print("PART", part_path(i), b)
D = m["deformer"]
for i in range(D["count"]):
    b = binding(v(D["i_param_map_set"][i]))
    if want & {p for p, _ in b}: print("DEFORMER", D["id"][i], b)
