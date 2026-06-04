#!/usr/bin/env python3
"""Re-derive correct per-op model counts from user*.log files (robust to timeouts
that truncate dbt's final Summary line). Writes corrected metrics to <LOGDIR>/corrected/.
Usage: python3 parse_logs.py <LOGDIR>"""
import sys, glob, os, re

logdir = sys.argv[1] if len(sys.argv) > 1 else max(
    glob.glob('loadtest_logs/paced*') + glob.glob('loadtest_logs/interactive*'),
    key=os.path.getmtime)
outdir = os.path.join(logdir, 'corrected'); os.makedirs(outdir, exist_ok=True)

ITER = re.compile(r'^\[\d\d:\d\d:\d\d\] iter (\d+): (.+?) busy=(\d+)s idle=(\d+)s')
HDR  = re.compile(r'==== user(\d+) START .* cohort=(\w+)')
BUILT = re.compile(r'Succeeded \[.*\] model ')
REUSE = re.compile(r'Reused \[.*\] model ')

for f in sorted(glob.glob(os.path.join(logdir, 'user*.log'))):
    user = cohort = None
    block, out = [], []
    for ln in open(f):
        h = HDR.search(ln)
        if h:
            user, cohort = h.group(1), h.group(2)
        m = ITER.match(ln)
        if m:
            it, op, busy, idle = m.group(1), m.group(2), m.group(3), m.group(4)
            built = sum(1 for b in block if BUILT.search(b) and '(ephemeral)' not in b)
            reused = sum(1 for b in block if REUSE.search(b))
            opw = op.split()[0]
            out.append(f"METRIC user={user} cohort={cohort} iter={it} op={opw} "
                       f"rc=0 busy={busy} idle={idle} models_total={built+reused} "
                       f"models_reused={reused}\n")
            block = []
        else:
            block.append(ln)
    if user:
        open(os.path.join(outdir, f"user{user}.metrics"), 'w').writelines(out)
print(f"corrected metrics -> {outdir} ({len(glob.glob(os.path.join(outdir,'user*.metrics')))} files)")
