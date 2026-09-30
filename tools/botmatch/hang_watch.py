#!/usr/bin/env python3
"""usage: hang_watch.py <binary substring> [silent_s=300] [poll_s=30]

Watches running headless matches. One whose stdout log has been silent for
silent_s and that burned no CPU over the last poll is hung: dump every
thread's backtrace next to its log (<log>.hang.txt), then kill it. Exits when
no matching process has been seen for three polls in a row.
"""
import os, subprocess, sys, time

needle = sys.argv[1]
silent_s = float(sys.argv[2]) if len(sys.argv) > 2 else 300.0
poll_s = float(sys.argv[3]) if len(sys.argv) > 3 else 30.0


def procs():
    out = {}
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            exe = os.readlink(f"/proc/{pid}/exe")
            if needle not in exe:
                continue
            log = os.readlink(f"/proc/{pid}/fd/1")
            fields = open(f"/proc/{pid}/stat").read().rsplit(")", 1)[1].split()
            out[int(pid)] = (log, int(fields[11]) + int(fields[12]))
        except (OSError, IndexError, ValueError):
            continue
    return out


last_cpu = {}
idle_polls = 0
while idle_polls < 3:
    now = time.time()
    ps = procs()
    idle_polls = 0 if ps else idle_polls + 1
    for pid, (log, cpu) in ps.items():
        prev = last_cpu.get(pid)
        last_cpu[pid] = cpu
        if prev is None or cpu - prev > 5 or not os.path.exists(log):
            continue
        if now - os.path.getmtime(log) < silent_s:
            continue
        dump = log + ".hang.txt"
        with open(dump, "w") as f:
            subprocess.run(["gdb", "-p", str(pid), "-batch", "-ex", "thread apply all bt full 30"],
                           stdout=f, stderr=subprocess.STDOUT, timeout=600)
        os.kill(pid, 9)
        print(f"hung pid {pid}: {dump}", flush=True)
    time.sleep(poll_s)
