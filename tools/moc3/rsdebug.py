"""Parse Rust {:#?} Debug output into Python values (structs -> dict, tuples/arrays -> list)."""
import re, sys, pickle

TOK = re.compile(r'\s*(?:(".*?(?<!\\)")|([-+]?(?:\d+\.?\d*(?:e[-+]?\d+)?|inf|NaN))|([A-Za-z_][A-Za-z0-9_]*)|(.))', re.S)

def tokens(s):
    for m in TOK.finditer(s):
        if m.group(1) is not None: yield ("s", m.group(1)[1:-1])
        elif m.group(2) is not None: yield ("n", float(m.group(2)) if any(c in m.group(2) for c in ".eiN") else int(m.group(2)))
        elif m.group(3) is not None: yield ("i", m.group(3))
        elif m.group(4) and m.group(4).strip(): yield ("p", m.group(4))

def parse(s):
    t = list(tokens(s)); pos = 0
    def val():
        nonlocal pos
        k, v = t[pos]; pos += 1
        if k in "sn": return v
        if k == "p" and v == "[":
            out = []
            while t[pos] != ("p", "]"):
                out.append(val())
                if t[pos] == ("p", ","): pos += 1
            pos += 1; return out
        if k == "p" and v == "(":
            out = []
            while t[pos] != ("p", ")"):
                out.append(val())
                if t[pos] == ("p", ","): pos += 1
            pos += 1; return out
        if k == "p" and v == "{":
            out = []
            while t[pos] != ("p", "}"):
                key = val(); pos += 1
                out.append((key, val()))
                if t[pos] == ("p", ","): pos += 1
            pos += 1; return out
        if k == "i":
            if v in ("true", "false"): return v == "true"
            if pos < len(t) and t[pos] == ("p", "{"):
                pos += 1; d = {"_": v}
                while t[pos] != ("p", "}"):
                    key = t[pos][1]; pos += 2
                    d[key] = val()
                    if t[pos] == ("p", ","): pos += 1
                pos += 1; return d
            if pos < len(t) and t[pos] == ("p", "("):
                inner = val()
                if v == "Some": return inner[0] if len(inner) == 1 else inner
                return {"_": v, "v": inner[0] if len(inner) == 1 else inner}
            return v
        raise ValueError((k, v, pos))
    return val()

if __name__ == "__main__":
    s = open(sys.argv[1]).read()
    s = s[s.index("ParsedModel"):]
    m = parse(s)
    pickle.dump(m, open(sys.argv[2], "wb"))
    print(list(m.keys()))
