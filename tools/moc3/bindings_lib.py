P = m["param"]; nP = P["count"]
map_param = {}
for i in range(nP):
    for k in range(v(P["i_maps"][i]), v(P["i_maps"][i]) + P["cnt_maps"][i]): map_param[k] = P["id"][i]
refs = [v(r) for r in m["param_map_ref"]["i_map"]]
sets = list(zip([v(x) for x in m["param_map_set"]["i_refs"]], m["param_map_set"]["cnt_refs"]))
kp = m["keypoint"]["values"]
maps = [(v(a), b) for a, b in zip(m["param_map"]["i_keypoints"], m["param_map"]["cnt_keypoints"])]
def binding(iset):
    a, c = sets[iset]
    out = []
    for r in range(a, a + c):
        mp = refs[r]; ka, kc = maps[mp]
        out.append((map_param[mp], kp[ka:ka + kc]))
    return out
