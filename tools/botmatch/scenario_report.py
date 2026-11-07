#!/usr/bin/env python3
"""scenario_report.py OUT_DIR SC_DIR [--trace] [--only GLOB]: each scenario's "check" list over its seeded runs.
Check forms are in doc/SCENARIOS.md."""
import fnmatch, glob, json, math, os, re, sys

TOKEN = re.compile(r"(\w+)=(\([^)]*\)|\[[^\]]*\]|\S+)")


def num(v):
    if isinstance(v, bool):
        return None
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def compare(a, op, b):
    if a is None:
        return False
    if op == "has":
        return str(b).lower() in str(a).lower()
    if op in ("in", "out"):
        x = num(a)
        return x is not None and (b[0] <= x <= b[1]) == (op == "in")
    x, y = num(a), num(b)
    if x is None or y is None:
        x, y = str(a).lower(), str(b).lower()
        if op not in ("==", "!="):
            return False
    return {"==": x == y, "!=": x != y, ">=": x >= y, "<=": x <= y, ">": x > y, "<": x < y}[op]


def scn_samples(lines):
    """ship name -> [(t, fields)], fields from the SCN tokens plus the stance text."""
    out = {}
    for l in lines:
        m = re.match(r"SCN t=\s*([\d.]+) (.+?) hp=", l)
        if not m:
            continue
        head, _, stance = l.partition(" | ")
        f = {k: v for k, v in TOKEN.findall(head[m.end() - 3:])}
        f["stance"] = stance.strip()
        if "at" in f:
            x, z = f["at"].strip("()").split(",")
            f["x"], f["z"] = float(x), float(z)
        out.setdefault(m.group(2), []).append((float(m.group(1)), f))
    return out


def scn_value(samples, ship, i, field):
    t, f = samples[ship][i]
    kind, _, name = field.partition(":")
    if kind not in ("off_bow", "dist", "xfire"):
        return f.get(field)
    at = lambda n: next((g for s, g in samples.get(n, []) if abs(s - t) < 1e-3), None)
    if kind == "xfire":
        other, _, tgt = name.partition(":")
        o, q = at(other), at(tgt)
        if o is None or q is None:
            return None
        a = math.atan2(f["x"] - q["x"], f["z"] - q["z"]) - math.atan2(o["x"] - q["x"], o["z"] - q["z"])
        return abs(math.degrees((a + math.pi) % (2 * math.pi) - math.pi))
    o = at(name)
    if o is None:
        return None
    if kind == "dist":
        return math.hypot(o["x"] - f["x"], o["z"] - f["z"])
    bearing = math.degrees(math.atan2(o["x"] - f["x"], o["z"] - f["z"]))
    return abs((bearing - float(f["hdg"]) + 180.0) % 360.0 - 180.0)


def row_of(met, ship):
    return next((r for r in met.get("ships", []) if ship in (r.get("ship_name"), r.get("player_name"))), {})


def end_value(met, ship, field):
    row = row_of(met, ship)
    parts = [row.get(k) for k in field.split("+")]
    return parts[0] if len(parts) == 1 else None if None in parts else sum(parts)


def event_t(samples, ev):
    seq = samples.get(ev["ship"], [])
    return next((t for i, (t, _) in enumerate(seq)
                 if compare(scn_value(samples, ev["ship"], i, ev["scn"]), ev.get("op", "=="), ev["value"])), None)


def run_check(c, samples, met):
    if "any" in c:
        res = [run_check(k, samples, met) for k in c["any"]]
        return any(r[0] for r in res), "|".join(str(r[1]) for r in res)
    want = c.get("value")
    if isinstance(want, dict):
        want = end_value(met, want["ship"], want["end"])
    op = c.get("op", "==")
    if "match" in c:
        got = met.get(c["match"])
        return compare(got, op, want), got
    if "end" in c:
        got = end_value(met, c["ship"], c["end"])
        return compare(got, op, want), got
    ship = c["ship"]
    seq = samples.get(ship, [])
    lo = c.get("from_s", 0.0)
    if isinstance(lo, dict):
        lo = event_t(samples, lo)
        if lo is None:
            return False, "no event"
    hi = c.get("to_s", math.inf)
    if isinstance(hi, dict):
        hi = event_t(samples, hi)
        if hi is None:
            return False, "no end event"
    if "within_s" in c:
        hi = lo + c["within_s"]
    idx = [i for i, (t, _) in enumerate(seq) if lo <= t <= hi]
    if not idx:
        return False, "no samples"
    vals = [scn_value(samples, ship, i, c["scn"]) for i in idx]
    if c.get("delta"):
        base = num(vals[0]) or 0.0
        vals = [None if num(v) is None else num(v) - base for v in vals]
    ok = [compare(v, op, want) for v in vals]
    if "within_s" in c:
        hit = next((seq[i][0] for i, k in zip(idx, ok) if k), None)
        return hit is not None, f"t={hit - lo:.1f}s" if hit is not None else f"last {vals[-1]}"
    share = sum(ok) / len(ok)
    return share >= c.get("share", 1.0), f"{share:.0%}"


def label(c):
    if "any" in c:
        return " or ".join(f"({label(k)})" for k in c["any"])
    what = c.get("match") or c.get("end") or c.get("scn")
    s = f"{c.get('ship', 'match')} {what}{' Δ' if c.get('delta') else ''} {c.get('op', '==')} {c.get('value')}"
    if "within_s" in c:
        s += f" within {c['within_s']}s"
    if "share" in c:
        s += f" for {c['share']:.0%}"
    return s


def trace(sc, lines, met):
    for hull in sc.get("trace", []):
        print(f"  {hull}:")
        prev = None
        for l in lines:
            m = re.match(rf"SCN t=\s*([\d.]+) {re.escape(hull)} hp=(\d+).*?(?:d=(\d+))?.*?\| (Stance[^|]*)", l)
            if not m:
                continue
            st = re.sub(r"\s+\d+/4.*|\s+astern.*", "", m.group(4).strip())
            if st != prev:
                print(f"    {float(m.group(1)):.0f}s {st} hp {m.group(2)} d {m.group(3) or '-'}")
                prev = st
    for row in met.get("ships", []):
        if row.get("torpedoes_fired", 0):
            print(f"  torpedoes {row.get('ship_name', '?')}: fired {row['torpedoes_fired']} hit {row.get('torpedo_count', 0)}"
                  f" grounded {row.get('torpedoes_grounded', 0)} dmg {row.get('torpedo_damage', 0):.0f}")


def main():
    args = sys.argv[1:]
    show_trace = "--trace" in args
    only = args[args.index("--only") + 1] if "--only" in args else "*"
    out_dir, sc_dir = [a for a in args if not a.startswith("--") and a != only][:2]
    failed = []
    for f in sorted(glob.glob(f"{sc_dir}/*.json")):
        name = os.path.basename(f)[:-5]
        if not fnmatch.fnmatch(name, only):
            continue
        sc = json.load(open(f)).get("scenario", {})
        logs = sorted(glob.glob(f"{out_dir}/{name}.s*.log"))
        if not logs:
            continue
        checks = sc.get("check", [])
        runs = []
        for log in logs:
            lines = open(log, errors="replace").read().splitlines()
            mf = log[:-4] + ".json"
            met = json.load(open(mf)) if os.path.exists(mf) else {}
            errs = sum("SCRIPT ERROR" in l for l in lines)
            runs.append((lines, met, errs, [run_check(c, scn_samples(lines), met) for c in checks]))
        need = sc.get("pass_rate", 0.5) * len(runs)
        per = [sum(r[3][k][0] for r in runs) for k in range(len(checks))]
        errs = sum(r[2] for r in runs)
        verdict = "NO CHECK" if not checks else "PASS" if all(p >= need for p in per) and not errs else "FAIL"
        if verdict == "FAIL":
            failed.append(name)
        print(f"\n{verdict:8} {name}: {sc.get('expect', sc.get('source', ''))}")
        for k, c in enumerate(checks):
            print(f"  {per[k]}/{len(runs)}  {label(c)}  [{', '.join(str(r[3][k][1]) for r in runs)}]")
        if errs:
            print(f"  {errs} script errors")
        if show_trace:
            trace(sc, runs[0][0], runs[0][1])
    print(f"\n{len(failed)} failed{': ' + ' '.join(failed) if failed else ''}")
    sys.exit(1 if failed else 0)


main()
