#!/usr/bin/env python3
"""Per scenario: the expectation, then per traced hull the stance it held each second and how the duel went."""
import glob, json, os, re, sys

out_dir, sc_dir = sys.argv[1], sys.argv[2]
for f in sorted(glob.glob(f"{sc_dir}/*.json")):
    name = os.path.basename(f)[:-5]
    sc = json.load(open(f)).get("scenario", {})
    log = f"{out_dir}/{name}.log"
    if not os.path.exists(log):
        continue
    print(f"\n== {name}: {sc.get('expect', '')}")
    lines = open(log, errors="replace").read().splitlines()
    for hull in sc.get("trace", []):
        seq = []
        for l in lines:
            m = re.match(rf"SCN t=\s*([\d.]+) {re.escape(hull)} hp=(\d+).*?(?:d=(\d+))?.*?\| (Stance[^|]*)", l)
            if m:
                st = m.group(4).strip()
                st = re.sub(r"\s+\d+/4.*|\s+astern.*", "", st)
                seq.append(f"{float(m.group(1)):.0f}s {st} hp {m.group(2)} d {m.group(3) or '-'}")
        print(f"  {hull}:")
        prev = None
        for s in seq:
            key = s.split(" hp ")[0].split(" ", 1)[1]
            if key != prev:
                print("    " + s)
                prev = key
    met = f"{out_dir}/{name}.json"
    if os.path.exists(met):
        for row in json.load(open(met)).get("ships", []):
            if row.get("torpedoes_fired", 0):
                print(f"  torpedoes {row.get('ship_name', row.get('ship', '?'))}: fired {row['torpedoes_fired']} hit {row.get('torpedo_count', 0)}"
                      f" grounded {row.get('torpedoes_grounded', 0)} dmg {row.get('torpedo_damage', 0):.0f}")
    end = [l for l in lines if "Match ended" in l or "SCRIPT ERROR" in l]
    print("  end: " + (end[0] if end else "duration"))
