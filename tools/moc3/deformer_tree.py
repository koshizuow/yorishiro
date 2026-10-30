import pickle, json, sys

m = pickle.load(open(sys.argv[1], "rb")); cdi = {p["Id"]: p["Name"] for p in json.load(open(sys.argv[2]))["Parts"]}
v = lambda x: x["v"] if isinstance(x, dict) else x
D, W, WF, A, Pt = m["deformer"], m["warp_deformer"], m["warp_form"], m["art_mesh"], m["part"]
exec(open(__file__.rsplit("/", 1)[0] + "/bindings_lib.py").read())
targets = sys.argv[3].split(",")
for name in targets:
    i = D["id"].index(name)
    chain = []; j = i
    while j != -1:
        chain.append(D["id"][j]); j = v(D["i_parent"][j])
    w = v(D["i_typed"][i]) if D["deformer_type"][i] == "Warp" else None
    op = None
    if w is not None:
        f0 = v(W["i_forms"][w]); op = [round(x, 2) for x in WF["opacity"][f0:f0 + W["cnt_forms"][w]]]
    kids = [A["id"][k] for k in range(A["count"]) if v(A["i_deformer"][k]) == i]
    subdef = [D["id"][k] for k in range(D["count"]) if v(D["i_parent"][k]) == i]
    print(name, "part", cdi.get(Pt["id"][v(D["i_part"][i])]), Pt["id"][v(D["i_part"][i])], "visible", D["visible"][i], "chain", "<".join(chain))
    print("   keys", binding(v(D["i_param_map_set"][i])), "opacity", op)
    for k in kids:
        a = A["id"].index(k)
        print("   mesh", k, "part", cdi.get(Pt["id"][v(A["i_part"][a])]), Pt["id"][v(A["i_part"][a])], "visible", A["visible"][a], "clips", A["cnt_clips"][a], "keys", binding(v(A["i_param_map_set"][a])))
    if subdef: print("   subdeformers", subdef)
