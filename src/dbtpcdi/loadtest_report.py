#!/usr/bin/env python3
"""Aggregate loadtest .metrics files into reuse stats and 'freed-up time' per cohort.
Usage: python3 loadtest_report.py <LOGDIR>"""
import sys, glob, os
from collections import defaultdict

logdir = sys.argv[1] if len(sys.argv) > 1 else max(
    glob.glob('loadtest_logs/paced*') + glob.glob('loadtest_logs/interactive*'),
    key=os.path.getmtime)

MAT = ('run', 'build', 'full', 'edit+run')
agg = defaultdict(lambda: dict(ops=0, busy=0, idle=0, users=set(),
                               mt=0, mr=0, runops=0))
peri = {}   # peri[user][iter] = (op, busy, mt, mr)  for paired-twin analysis
for f in glob.glob(os.path.join(logdir, 'user*.metrics')):
    for ln in open(f):
        if not ln.startswith('METRIC'):
            continue
        kv = dict(p.split('=', 1) for p in ln.split() if '=' in p)
        c = kv.get('cohort', '?')
        u = int(kv.get('user', 0)); it = int(kv.get('iter', 0))
        peri.setdefault(u, {})[it] = (kv.get('op'), int(kv.get('busy', 0)),
                                      int(kv.get('models_total', 0)),
                                      int(kv.get('models_reused', 0)))
        a = agg[c]
        a['ops'] += 1
        a['busy'] += int(kv.get('busy', 0))
        a['idle'] += int(kv.get('idle', 0))
        a['users'].add(kv.get('user'))
        # only materializing ops have meaningful reuse (run/build/full/edit+run);
        # compile/inline/test/list don't create tables.
        if kv.get('op') in ('run', 'build', 'full', 'edit+run'):
            mt = int(kv.get('models_total', 0))
            if mt:
                a['runops'] += 1
                a['mt'] += mt
                a['mr'] += int(kv.get('models_reused', 0))

def hms(s):
    s = int(s); return f"{s//3600}h{(s%3600)//60:02d}m{s%60:02d}s" if s >= 3600 else f"{s//60}m{s%60:02d}s"

print(f"\n=== Load-test report: {logdir} ===\n")
hdr = ("cohort", "users", "ops", "busy(comp)", "idle(freed)", "freed/op",
       "run-ops", "models", "reused", "reuse%")
print("{:<8}{:>6}{:>6}{:>12}{:>13}{:>10}{:>9}{:>8}{:>8}{:>8}".format(*hdr))
for c in sorted(agg):
    a = agg[c]
    reuse = (100.0 * a['mr'] / a['mt']) if a['mt'] else 0.0
    fpo = a['idle'] / a['ops'] if a['ops'] else 0
    print("{:<8}{:>6}{:>6}{:>12}{:>13}{:>10}{:>9}{:>8}{:>8}{:>7.1f}%".format(
        c, len(a['users']), a['ops'], hms(a['busy']), hms(a['idle']),
        f"{fpo:.0f}s", a['runops'], a['mt'], a['mr'], reuse))

if 'state' in agg and 'nostate' in agg:
    s, n = agg['state'], agg['nostate']
    extra = s['idle'] - n['idle']
    print(f"\nState reuse rate:      {(100.0*s['mr']/s['mt'] if s['mt'] else 0):.1f}%"
          f"  ({s['mr']}/{s['mt']} models reused instead of rebuilt)")
    print(f"No-state reuse rate:   {(100.0*n['mr']/n['mt'] if n['mt'] else 0):.1f}%"
          f"  ({n['mr']}/{n['mt']})")
    print(f"Total compute time:    state {hms(s['busy'])}  vs  nostate {hms(n['busy'])}")
    print(f"Total freed/idle time: state {hms(s['idle'])}  vs  nostate {hms(n['idle'])}")
    print(f"=> Slot-idle delta (noisy; dominated by dbt+state client overhead): {hms(abs(extra))}\n")

    # Paired-twin analysis: user b (state) vs twin b+25 (nostate), aligned by iter,
    # materializing ops only -> cancels constant client overhead, isolates rebuild
    # time that reuse skipped (the wall-clock a state user gets back vs their twin).
    freed = 0; pairs = 0; reused_models = 0; rebuilt_models = 0
    for b in range(1, 26):
        t = b + 25
        if b not in peri or t not in peri:
            continue
        for it in set(peri[b]) & set(peri[t]):
            (op_s, busy_s, mt_s, mr_s) = peri[b][it]
            (op_n, busy_n, _, _) = peri[t][it]
            if op_s in MAT and op_n in MAT:
                pairs += 1
                freed += max(0, busy_n - busy_s)
                reused_models += mr_s
                rebuilt_models += mt_s
    print("--- Paired twins (state user i vs no-state user i+25, same op sequence) ---")
    print(f"Matched materializing op-pairs: {pairs}")
    print(f"Models the state users REUSED (rebuild skipped): {reused_models}")
    print(f"Wall-clock the state users got back vs their twins (sum of rebuild>reuse): {hms(freed)}")
    print(f"  ~avg per state user (x25): {hms(freed/25)} of compute time freed for other work\n")
