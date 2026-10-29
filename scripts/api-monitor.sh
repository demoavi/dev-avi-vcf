#!/bin/bash
#
# API availability monitor (diagnostic, not part of vcf_bootstrap.sh's phases). Probes every API of the platform once per
# second (default) from the gw, in parallel, and writes a raw sample file plus a report that shows WHICH api is not always on:
# per-target availability, latency percentiles, every outage window (start, end, duration, HTTP codes) and the moments where
# several targets were down together (a shared cause, e.g. the ESX host or the storage, rather than one broken service).
#
#   bash api-monitor.sh [json file] [--duration <seconds>] [--interval <seconds>] [--edge-interval <seconds>] [--out <dir>]
#   bash api-monitor.sh --report <dir>        # rebuild the report of an earlier run
#
# Defaults: json /home/ubuntu/json/deployment.json, 1800 s (30 min), one call per target every 3 s, out /home/ubuntu/api-monitor/<timestamp>. Meant to be
# started with nohup on the gw and left alone: `nohup bash api-monitor.sh --duration 1800 > /dev/null 2>&1 &`. Ctrl-C / kill
# stops it cleanly and still writes the report. Output: samples.csv (ts|target|http_code|seconds|ok), report.md, monitor.log.
#
# Variables and credentials are derived like in the phase scripts (variables.sh + functions.sh, generic_password, the
# per-org password derived from gw_accounts_secret); nothing is passed on the command line. Targets whose address is not known
# (e.g. no Supervisor yet, git/harbor disabled) are skipped and listed in monitor.log. Read-only: no call changes anything,
# except that logins create sessions (re-done only when the API answers 401/403 or the token is missing).
#
# What "ok" means: the call answered within 5 s with the expected status (per target below). A timeout or refused connection is
# code 000. Each probe asks something that needs the service's own backend (not just the web server in front of it) where an
# authenticated call is possible, so "up" is not just "the port answers".
#
# Targets: vcenter, vcenter-login (only when a re-login was needed), nsx, avi, vcfa-system, vcfa-system-login, vcfa-org,
# vcfa-org-cci, vcfa-ui, supervisor, installer, esxi-<n>, vault, harbor, git, dns-gw, dns-avi, vcd (vApp use case).
#
# NSX Edge nodes (not a target, no availability figure): every --edge-interval seconds (default 10; NSX only refreshes these figures about every 15-30 s) the status of each Edge transport
# node is read from NSX (/api/v1/transport-nodes/<id>/status and /state: node and tunnel status, CPU of the datapath (DPDK) and the
# other cores, load, memory) into edge.csv, and the report shows them for the moments the targets were down, to tell whether the
# overlay datapath (T0/T1 on the Edge) was busy or stalled when the Supervisor/VKS/git/harbor VIPs timed out. NSX's own alarms
# (Edge down, tunnels down, T0/T1 failover, ...) are read every 30 s into alarms.json and listed next to the outages.
#
# Do not edit this script while it is running (bash reads scripts incrementally).
#
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

duration=1800
interval=3
edge_interval=10
out=""
jsonFile="/home/ubuntu/json/deployment.json"
report_only=""
while [ $# -gt 0 ]; do
  case "$1" in
    --duration) duration="${2:?}"; shift 2 ;;
    --interval) interval="${2:?}"; shift 2 ;;
    --edge-interval) edge_interval="${2:?}"; shift 2 ;;
    --out) out="${2:?}"; shift 2 ;;
    --report) report_only="${2:?}"; shift 2 ;;
    -h|--help) sed -n 2,26p "$0"; exit 0 ;;
    *) jsonFile="$1"; shift ;;
  esac
done

make_report() { # dir
  python3 -I - "$1" <<'PYEOF'
import sys, os, collections, statistics, datetime

d = sys.argv[1]
rows = collections.defaultdict(list)
with open(os.path.join(d, "samples.csv")) as f:
    for line in f:
        p = line.rstrip("\n").split("|")
        if len(p) < 5:
            continue
        try:
            rows[p[1]].append((float(p[0]), p[2], float(p[3]), p[4] == "1"))
        except ValueError:
            pass
skipped = collections.Counter()
try:
    with open(os.path.join(d, "skipped.csv")) as f:
        for line in f:
            p = line.rstrip("\n").split("|")
            if len(p) >= 2:
                skipped[p[1]] += 1
except OSError:
    pass
meta = {}
try:
    with open(os.path.join(d, "meta.txt")) as f:
        for line in f:
            k, _, v = line.rstrip("\n").partition("=")
            meta[k] = v
except OSError:
    pass
tdesc = {}
try:
    with open(os.path.join(d, "targets.tsv")) as f:
        for line in f:
            p = line.rstrip("\n").split("\t")
            if len(p) >= 4:
                tdesc[p[0]] = p[1:4]
except OSError:
    pass
if not rows:
    print("no samples in", d)
    sys.exit(1)

def hms(t):
    return datetime.datetime.fromtimestamp(t).strftime("%H:%M:%S")

def pct(vals, q):
    if not vals:
        return 0.0
    vals = sorted(vals)
    return vals[min(len(vals) - 1, int(round(q * (len(vals) - 1))))]

try:
    IV = float(meta.get("interval") or 1)  # one sample stands for this many seconds
except ValueError:
    IV = 1.0
all_start = min(r[0][0] for r in rows.values())
all_end = max(r[-1][0] for r in rows.values())
outages = []  # (target, start, end, n_fail, codes)
summary = []
for name in sorted(rows):
    s = sorted(rows[name])
    n = len(s)
    bad = [x for x in s if not x[3]]
    lat = [x[2] for x in s if x[3]]
    cur = None
    own = []
    for x in s:
        # an outage is a run of consecutive failed samples; one successful sample ends it (a skipped tick is not a sample)
        if x[3]:
            if cur:
                own.append(cur)
                cur = None
        elif cur:
            cur[1] = x[0]; cur[2] += 1; cur[3][x[1]] += 1
        else:
            cur = [x[0], x[0], 1, collections.Counter({x[1]: 1})]
    if cur:
        own.append(cur)
    for o in own:
        outages.append((name, o[0], o[1], o[2], o[3]))
    longest = max((o[1] - o[0] + IV for o in own), default=0)
    summary.append((name, n, len(bad), 100.0 * (n - len(bad)) / n, len(own), longest,
                    pct(lat, .5), pct(lat, .95), max(lat, default=0.0)))

L = []
L.append("# API availability report")
L.append("")
L.append(f"Window: {hms(all_start)} - {hms(all_end)} ({(all_end-all_start)/60:.1f} min), outage = consecutive failed samples (one successful sample ends it), duration = first to last failure + one interval ({IV:g} s).")
L.append("")
ivl = meta.get("interval", "?")
L.append("## How it was tested")
L.append("")
L.append(f"- From {meta.get('host', '?')}, deployment {meta.get('deployment', '?')}, started {meta.get('started', '?')}, planned duration {meta.get('duration', '?')} s.")
L.append(f"- One call per target every {ivl} s, targets in parallel. A new call is only made when the previous call of the same target has finished (no cascade); a tick skipped for that reason is counted as 'skipped ticks', not as a sample.")
L.append("- Every call: TLS certificate not verified, 3 s to connect, 5 s in total. Failed = no answer in time, or a status other than the expected one. A login is repeated only when the API answers 401/403 (or 419 for Avi) and is recorded as its own '-login' target.")
L.append("")
L.append("| target | request | authentication | ok when |")
L.append("|---|---|---|---|")
for n in sorted(tdesc):
    L.append(f"| {n} | {tdesc[n][0]} | {tdesc[n][1]} | {tdesc[n][2]} |")
L.append("")
L.append("## Per target (worst availability first)")
L.append("")
L.append("| target | samples | failed | skipped ticks | availability % | outages | longest outage (s) | p50 s | p95 s | max s |")
L.append("|---|---|---|---|---|---|---|---|---|---|")
for r in sorted(summary, key=lambda r: (r[3], -r[4])):
    L.append(f"| {r[0]} | {r[1]} | {r[2]} | {skipped[r[0]]} | {r[3]:.2f} | {r[4]} | {r[5]:.0f} | {r[6]:.2f} | {r[7]:.2f} | {r[8]:.2f} |")
L.append("")
L.append("## Outages (chronological)")
L.append("")
if outages:
    L.append("| target | from | to | duration (s) | failed samples | codes |")
    L.append("|---|---|---|---|---|---|")
    for o in sorted(outages, key=lambda o: o[1]):
        codes = ", ".join(f"{k} x{v}" for k, v in o[4].most_common())
        L.append(f"| {o[0]} | {hms(o[1])} | {hms(o[2])} | {o[2]-o[1]+IV:.0f} | {o[3]} | {codes} |")
else:
    L.append("None - every sample of every target was ok.")
L.append("")

# Windows where two or more targets were down at the same time (login probes are excluded: they only exist after a failure).
down = collections.defaultdict(set)
for name, s, e, n, c in outages:
    if name.endswith("-login"):
        continue
    t = int(s)
    while t <= int(e) + 0:
        down[t].add(name)
        t += 1
wins = []
for t in sorted(down):
    if len(down[t]) < 2:
        continue
    if wins and t - wins[-1][1] <= 2:
        wins[-1][1] = t; wins[-1][2] |= down[t]
    else:
        wins.append([t, t, set(down[t])])
L.append("## Shared outages (2+ targets down at once)")
L.append("")
if wins:
    L.append("| from | to | duration (s) | targets |")
    L.append("|---|---|---|---|")
    for w in wins:
        L.append(f"| {hms(w[0])} | {hms(w[1])} | {w[1]-w[0]+1} | {', '.join(sorted(w[2]))} |")
else:
    L.append("None - no two targets were down at the same time.")
L.append("")
# ---- NSX Edge nodes (edge.csv / edge.tsv, written by the collector): own figures, then what the Edges did while targets were down
def fl(v):
    try:
        return float(v)
    except ValueError:
        return None
def outage_clusters():
    """outages of all targets (login probes excluded), less than 4 s apart merged: [start, end, {targets}]"""
    cl = []
    for name, s0, e0, n0, c0 in sorted((o for o in outages if not o[0].endswith("-login")), key=lambda o: o[1]):
        if cl and s0 - cl[-1][1] <= 4:
            cl[-1][1] = max(cl[-1][1], e0 + IV); cl[-1][2].add(name)
        else:
            cl.append([s0, e0 + IV, {name}])
    return cl
edge = collections.defaultdict(list)   # node -> [(ts, api code, api s, state, status, mgmt, ctrl, tunnel, pnic, {metric: value})]
EM = ["load1", "dpdk avg %", "dpdk max %", "other avg %", "other max %", "system mem %", "datapath mem %", "datapath heap %", "datapath pool max %"]
try:
    with open(os.path.join(d, "edge.csv")) as f:
        for line in f:
            p = line.rstrip("\n").split("|")
            if len(p) < 5:
                continue
            p += [""] * (19 - len(p))
            t = fl(p[0])
            if t is None:
                continue
            edge[p[1]].append((t, p[2], fl(p[3]) or 0.0, p[4], p[5], p[6], p[7], p[8], p[9], dict(zip(EM, [fl(v) for v in p[10:19]]))))
except OSError:
    pass
einfo = {}
try:
    with open(os.path.join(d, "edge.tsv")) as f:
        for line in f:
            p = line.rstrip("\n").split("\t")
            if p and p[0]:
                c = (p[3].split("|") + ["", ""])[:2] if len(p) > 3 else ["", ""]
                einfo[p[0]] = f"{p[2] or '?'}, {c[0] or '?'} cores ({c[1] or '?'} datapath)"
except OSError:
    pass
try:
    EI = float(meta.get("edge_interval") or 10)
except ValueError:
    EI = 10.0
etab1 = []   # per node figures
etab2 = []   # per cluster of outages
etab3 = []   # inside the outage windows vs outside
etext = []
if edge:
    def mx(v):
        v = [x for x in v if x is not None]
        return max(v) if v else None
    def av(v):
        v = [x for x in v if x is not None]
        return sum(v) / len(v) if v else None
    def f1(v):
        return "-" if v is None else f"{v:.1f}"
    for n in sorted(edge):
        r = edge[n]
        notup = sum(1 for x in r if x[1] == "200" and (x[4] != "UP" or x[3] not in ("NODE_READY", "")))
        linkdown = sum(1 for x in r if x[1] == "200" and any(y not in ("UP", "") for y in x[5:9]))
        apifail = sum(1 for x in r if x[1] != "200")
        m = lambda k: [x[9][k] for x in r]
        etab1.append((n, einfo.get(n, ""), len(r), apifail, pct([x[2] for x in r], .95), notup, linkdown,
                      f1(av(m("load1"))) + " / " + f1(mx(m("load1"))), f1(mx(m("dpdk max %"))), f1(mx(m("other max %"))),
                      f1(mx(m("system mem %"))), f1(mx(m("datapath pool max %")))))
    cl = outage_clusters()
    wlo = [(c[0] - EI, c[1] + EI) for c in cl]
    def inside(t):
        return any(a <= t <= b for a, b in wlo)
    for c in cl:
        cells = []
        for n in sorted(edge):
            rs = [x for x in edge[n] if c[0] - EI <= x[0] <= c[1] + EI]
            if not rs:
                cells.append("no sample")
                continue
            cells.append("load " + f1(mx([x[9]["load1"] for x in rs])) + ", dpdk " + f1(mx([x[9]["dpdk max %"] for x in rs])) +
                         ", other " + f1(mx([x[9]["other max %"] for x in rs])) + ", mem " + f1(mx([x[9]["system mem %"] for x in rs])) +
                         (f", api fail {sum(1 for x in rs if x[1] != '200')}" if any(x[1] != "200" for x in rs) else ""))
        etab2.append((hms(c[0]), hms(c[1]), ", ".join(sorted(c[2])), cells))
    for n in sorted(edge):
        for k in ("load1", "dpdk max %", "other max %", "system mem %", "datapath pool max %"):
            vin = [x[9][k] for x in edge[n] if inside(x[0])]
            vout = [x[9][k] for x in edge[n] if not inside(x[0])]
            etab3.append((n, k, f1(av(vin)), f1(av(vout)), f1(mx(vin)), f1(mx(vout)), len([v for v in vin if v is not None])))
    etext.append(f"Edge nodes are read from NSX every {EI:g} s; the outage windows below are widened by one edge interval on both sides. CPU 'dpdk' = datapath cores, 'other' = the remaining cores. 'api fail' = NSX did not return the Edge status in 4 s.")
    L.append("## NSX Edge nodes")
    L.append("")
    L.append(etext[0])
    L.append("")
    L.append("| edge | size | samples | api failures | api p95 s | not ready | link/tunnel not up | load1 avg / max | dpdk cpu max % | other cpu max % | system mem max % | datapath pool max % |")
    L.append("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for r in etab1:
        L.append("| " + " | ".join(str(v) if not isinstance(v, float) else f"{v:.2f}" for v in r) + " |")
    L.append("")
    L.append("Edge values inside the outage windows (any target down) against the rest of the run:")
    L.append("")
    L.append("| edge | metric | avg inside | avg outside | max inside | max outside | samples inside |")
    L.append("|---|---|---|---|---|---|---|")
    for r in etab3:
        L.append("| " + " | ".join(str(v) for v in r) + " |")
    L.append("")
    L.append("Edge values around each outage (max of the samples in the window):")
    L.append("")
    L.append("| from | to | targets | " + " | ".join(sorted(edge)) + " |")
    L.append("|---|---|---|" + "---|" * len(edge))
    for r in etab2:
        L.append(f"| {r[0]} | {r[1]} | {r[2]} | " + " | ".join(r[3]) + " |")
    L.append("")
# ---- NSX alarms raised during the run (alarms.json, read from NSX every 30 s) against the outages
import json
atab = []     # (onset, resolved, severity, type, node, reason, matching outage targets)
atext = []
try:
    with open(os.path.join(d, "alarms.json")) as f:
        al = json.load(f)
except (OSError, ValueError):
    al = None
if al is not None:
    TOL = 60.0   # NSX stamps alarms with a coarse clock (30 s granularity) and raises them a little after the event
    cl2 = outage_clusters()
    mine = sorted((a for a in al if a.get("t") and all_start - TOL <= a["t"] / 1000.0 <= all_end + TOL), key=lambda a: a["t"])
    hit_cl = set()
    for a in mine:
        t = a["t"] / 1000.0
        near = [i for i, c in enumerate(cl2) if c[0] - TOL <= t <= c[1] + TOL]
        hit_cl.update(near)
        tg = sorted(set().union(*[cl2[i][2] for i in near])) if near else []
        atab.append((hms(t), hms(a["r"] / 1000.0) if a.get("r") else "-", a.get("severity", ""), a.get("type", ""), a.get("node", ""), a.get("reason", ""), ", ".join(tg) or "none"))
    atext.append(f"{len(mine)} NSX alarm(s) were raised during the run. An alarm is matched to an outage when its onset is within {TOL:.0f} s of it. "
                 f"{sum(1 for r in atab if r[6] != 'none')} of {len(mine)} alarms have an outage near them; {len(hit_cl)} of {len(cl2)} outage clusters have an alarm near them. "
                 "Alarms are not raised for every short stall, so an outage without one is not proof of a different cause.")
    L.append("## NSX alarms during the run")
    L.append("")
    L.append(atext[0])
    L.append("")
    if atab:
        L.append("| onset | resolved | severity | alarm | node | reason | outages near it |")
        L.append("|---|---|---|---|---|---|---|")
        for r in atab:
            L.append("| " + " | ".join(r) + " |")
    else:
        L.append("None.")
    L.append("")
L.append("Skipped ticks: the previous call of that target was still running (hung until its 5 s timeout), so no new call was made; not counted as samples or failures. A failed sample then stands for the whole 5 s it lasted.")
L.append("")
L.append("Raw samples: samples.csv (ts|target|http_code|seconds|ok). Code 000 = timeout or connection refused (5 s limit).")
text = "\n".join(L) + "\n"
open(os.path.join(d, "report.md"), "w").write(text)

# ---- HTML: same numbers, plus a timeline per target (red = outage, orange band = several targets down at once)
import html as H
span = max(all_end - all_start, 1.0)
W = 900.0
def x(t):
    return 4 + (t - all_start) / span * W
def cls(a):
    return "good" if a >= 99.9 else ("warn" if a >= 98 else "bad")
h = []
h.append("<!doctype html><html><head><meta charset='utf-8'><title>API availability report</title><style>"
         "body{font:14px/1.4 system-ui,sans-serif;margin:24px;color:#222}h1{font-size:22px}h2{font-size:17px;margin-top:28px}"
         "table{border-collapse:collapse}th,td{border:1px solid #ccc;padding:3px 9px;text-align:right}th{background:#f2f2f2}"
         "td:first-child,th:first-child{text-align:left}.good{background:#d8f3dc}.warn{background:#fff3bf}.bad{background:#ffc9c9}"
         ".tl{font:12px monospace}.muted{color:#666}</style></head><body>")
h.append("<h1>API availability report</h1>")
h.append(f"<p>Window {hms(all_start)} - {hms(all_end)} ({(all_end-all_start)/60:.1f} min). An outage is a run of consecutive failed samples (one successful sample ends it); its duration is first to last failure plus one interval ({IV:g} s). Generated {datetime.datetime.now().strftime('%H:%M:%S')}.</p>")
h.append("<h2>How it was tested</h2><ul>"
         f"<li>From <b>{H.escape(meta.get('host', '?'))}</b>, deployment <b>{H.escape(meta.get('deployment', '?'))}</b>, started {H.escape(meta.get('started', '?'))}, planned duration {H.escape(meta.get('duration', '?'))} s.</li>"
         f"<li>One call per target every <b>{H.escape(ivl)} s</b>, all targets in parallel. A new call is made only when the previous call of the same target has finished (no cascade); a tick skipped for that reason is counted as <i>skipped ticks</i>, not as a sample.</li>"
         "<li>Every call: TLS certificate not verified, 3 s to connect, 5 s in total. Failed = no answer in time, or a status other than the expected one. A login is repeated only when the API answers 401/403 (419 for Avi) and is recorded as its own <i>-login</i> target.</li></ul>")
h.append("<table><tr><th>target</th><th style='text-align:left'>request</th><th style='text-align:left'>authentication</th><th style='text-align:left'>ok when</th></tr>")
for n in sorted(tdesc):
    h.append(f"<tr><td>{H.escape(n)}</td><td style='text-align:left'>{H.escape(tdesc[n][0])}</td><td style='text-align:left'>{H.escape(tdesc[n][1])}</td><td style='text-align:left'>{H.escape(tdesc[n][2])}</td></tr>")
h.append("</table>")
h.append("<h2>Timeline</h2><svg class='tl' width='%d' height='%d'>" % (W + 170, 22 * len(summary) + 24))
for w in wins:
    h.append(f"<rect x='{x(w[0]):.1f}' y='0' width='{max(x(w[1]+1)-x(w[0]),2):.1f}' height='{22*len(summary)}' fill='#ffd8a8' opacity='0.7'/>")
for i, r in enumerate(sorted(summary, key=lambda r: r[0])):
    y = 22 * i
    h.append(f"<text x='{W+12:.0f}' y='{y+14}'>{H.escape(r[0])} {r[3]:.1f}%</text>")
    h.append(f"<rect x='4' y='{y+3}' width='{W:.0f}' height='14' fill='#d8f3dc' stroke='#9c9' stroke-width='0.5'/>")
    for o in outages:
        if o[0] == r[0]:
            h.append(f"<rect x='{x(o[1]):.1f}' y='{y+3}' width='{max(x(o[2]+IV)-x(o[1]),2):.1f}' height='14' fill='#e03131'><title>{H.escape(r[0])} {hms(o[1])}-{hms(o[2])} ({o[2]-o[1]+1:.0f} s)</title></rect>")
h.append(f"<text x='4' y='{22*len(summary)+16}'>{hms(all_start)}</text><text x='{W-30:.0f}' y='{22*len(summary)+16}'>{hms(all_end)}</text></svg>")
h.append("<h2>Per target (worst availability first)</h2><table><tr><th>target</th><th>samples</th><th>failed</th><th>skipped ticks</th><th>availability %</th><th>outages</th><th>longest outage (s)</th><th>p50 s</th><th>p95 s</th><th>max s</th></tr>")
for r in sorted(summary, key=lambda r: (r[3], -r[4])):
    h.append(f"<tr><td>{H.escape(r[0])}</td><td>{r[1]}</td><td>{r[2]}</td><td>{skipped[r[0]]}</td><td class='{cls(r[3])}'>{r[3]:.2f}</td><td>{r[4]}</td><td>{r[5]:.0f}</td><td>{r[6]:.2f}</td><td>{r[7]:.2f}</td><td>{r[8]:.2f}</td></tr>")
h.append("</table><h2>Outages (chronological)</h2>")
if outages:
    h.append("<table><tr><th>target</th><th>from</th><th>to</th><th>duration (s)</th><th>failed samples</th><th>codes</th></tr>")
    for o in sorted(outages, key=lambda o: o[1]):
        codes = ", ".join(f"{k} x{v}" for k, v in o[4].most_common())
        h.append(f"<tr><td>{H.escape(o[0])}</td><td>{hms(o[1])}</td><td>{hms(o[2])}</td><td>{o[2]-o[1]+IV:.0f}</td><td>{o[3]}</td><td>{H.escape(codes)}</td></tr>")
    h.append("</table>")
else:
    h.append("<p>None - every sample of every target was ok.</p>")
h.append("<h2>Shared outages (2+ targets down at once)</h2>")
if wins:
    h.append("<table><tr><th>from</th><th>to</th><th>duration (s)</th><th>targets</th></tr>")
    for w in wins:
        h.append(f"<tr><td>{hms(w[0])}</td><td>{hms(w[1])}</td><td>{w[1]-w[0]+1}</td><td style='text-align:left'>{H.escape(', '.join(sorted(w[2])))}</td></tr>")
    h.append("</table>")
else:
    h.append("<p>None - no two targets were down at the same time.</p>")
if edge:
    h.append("<h2>NSX Edge nodes</h2><p>" + H.escape(etext[0]) + "</p>")
    h.append("<table><tr><th>edge</th><th>size</th><th>samples</th><th>api failures</th><th>api p95 s</th><th>not ready</th><th>link/tunnel not up</th><th>load1 avg / max</th><th>dpdk cpu max %</th><th>other cpu max %</th><th>system mem max %</th><th>datapath pool max %</th></tr>")
    for r in etab1:
        h.append("<tr>" + "".join(f"<td>{H.escape(f'{v:.2f}' if isinstance(v, float) else str(v))}</td>" for v in r) + "</tr>")
    h.append("</table><h3>Inside the outage windows (any target down) against the rest of the run</h3><table><tr><th>edge</th><th>metric</th><th>avg inside</th><th>avg outside</th><th>max inside</th><th>max outside</th><th>samples inside</th></tr>")
    for r in etab3:
        h.append("<tr>" + "".join(f"<td>{H.escape(str(v))}</td>" for v in r) + "</tr>")
    h.append("</table><h3>Around each outage (max of the Edge samples in the window)</h3><table><tr><th>from</th><th>to</th><th>targets</th>" + "".join(f"<th>{H.escape(n)}</th>" for n in sorted(edge)) + "</tr>")
    for r in etab2:
        h.append(f"<tr><td>{r[0]}</td><td>{r[1]}</td><td style='text-align:left'>{H.escape(r[2])}</td>" + "".join(f"<td style='text-align:left'>{H.escape(c)}</td>" for c in r[3]) + "</tr>")
    h.append("</table>")
if al is not None:
    h.append("<h2>NSX alarms during the run</h2><p>" + H.escape(atext[0]) + "</p>")
    if atab:
        h.append("<table><tr><th>onset</th><th>resolved</th><th>severity</th><th>alarm</th><th>node</th><th>reason</th><th>outages near it</th></tr>")
        for r in atab:
            h.append("<tr>" + "".join(f"<td style='text-align:left'>{H.escape(str(v))}</td>" for v in r) + "</tr>")
        h.append("</table>")
    else:
        h.append("<p>None.</p>")
h.append("<p class='muted'>Code 000:N = no HTTP answer, N is curl's exit code (28 timeout, 7 refused, 6 DNS, 35/60 TLS). A skipped tick means the previous call of that target was still running, so no new call was made. "
         "Raw data: <a href='samples.csv'>samples.csv</a>, <a href='errors.log'>errors.log</a> (kubectl error texts), <a href='skipped.csv'>skipped.csv</a>, <a href='monitor.log'>monitor.log</a>, <a href='report.md'>report.md</a>, <a href='edge.csv'>edge.csv</a> (NSX Edge node stats), <a href='alarms.json'>alarms.json</a> (NSX alarms).</p></body></html>")
open(os.path.join(d, "report.html"), "w").write("\n".join(h))
print(text)
PYEOF
}

# publish <dir>: copy the report and the raw files to nginx's root (needs sudo: /var/www/html is root's) and print the link. The link
# uses the address the gw reaches the outside through (the same one gw-accounts.sh puts in the WireGuard endpoint).
publish() {
  local d="$1" run web ip
  run=$(basename "${d}"); web="/var/www/html/api-monitor/${run}"
  [ -d /var/www/html ] || return 1
  sudo mkdir -p "${web}" || return 1
  for f in report.html report.md samples.csv skipped.csv monitor.log meta.txt targets.tsv errors.log edge.csv edge.tsv alarms.json; do
    [ -f "${d}/${f}" ] && sudo cp "${d}/${f}" "${web}/"
  done
  sudo chmod -R a+rX /var/www/html/api-monitor
  ip=$(ip -4 route get 8.8.8.8 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -1)
  echo "http://${ip:-$(hostname -f)}/api-monitor/${run}/report.html"
}

if [ -n "${report_only}" ]; then
  make_report "${report_only}"
  rc=$?
  echo "html report: $(publish "${report_only}")"
  exit ${rc}
fi

source /home/ubuntu/bash/variables.sh
source "${script_dir}/functions.sh"

[ -z "${out}" ] && out="/home/ubuntu/api-monitor/$(date +%Y%m%d-%H%M%S)"
mkdir -p "${out}" || exit 1
samples="${out}/samples.csv"
mlog="${out}/monitor.log"
: > "${samples}"
: > "${out}/skipped.csv"
mlog() { echo "$(date '+%H:%M:%S') $*" | tee -a "${mlog}"; }

end_ts=$(( $(date +%s) + duration ))
CURL=(curl -sk -m 5 --connect-timeout 3)

# --- derived addresses and credentials -------------------------------------------------------------------------------
vc_host="${basename_sddc}-vc01.${domain}"
vc_user="administrator@$(jq -r '.sddc.vcenter.ssoDomain // "vsphere.local"' "${jsonFile}")"
nsx_host="${ip_nsx_vip}"
avi_host="$(echo "${ips_avi:-[]}" | jq -r '.[0] // empty')"
vcfa_host="${fqdn_vcfa:-${basename_sddc}-auto-vip.${domain}}"
vcfa_ver="9.1.0"
first_org="$(echo "${vcf_a_organizations:-[]}" | jq -r '.[0].name // empty')"
org_pw=""
[ -n "${first_org}" ] && org_pw="VMware1!$(echo -n "${gw_accounts_secret}${first_org}" | sha256sum | cut -c1-4)VMware1!"
sub="${avi_subdomain:-}"
# Avi DNS virtual service address: variables.sh of the sddc gw defines ip_avi_dns, the vApp's does not (only its cloud-init template does),
# so it is derived the same way - the first address of the Avi VIP pool in nsx_segments_overlay.
[ -z "${ip_avi_dns:-}" ] && ip_avi_dns=$(echo "${nsx_segments_overlay:-[]}" | jq -r '[.[] | select(has("avi_ipam_vip"))][0].avi_ipam_vip.pool // empty' 2>/dev/null | cut -d- -f1)
vcd_host=$(jq -r '.vcd.host // empty' "${jsonFile}" 2>/dev/null)

# --- probe plumbing --------------------------------------------------------------------------------------------------
# Targets run in parallel with each other, one background loop per target. Within a target a call is started every interval ONLY
# when the previous call of that same target has finished: a hanging API (5 s timeout) is never hit again while it is still being
# asked, so the monitor cannot pile up requests on a struggling service (the cascade). A tick skipped for that reason is not a
# sample and not a failure; it is counted in skipped.csv and shown in the report (the call that hung already counted as one).
# Calls cannot share shell variables with the loop, so sessions (tokens, cookies, the Supervisor endpoint) live in files under
# ${out}/.state, written by the call that needed to log in.
mkdir -p "${out}/.state"
st_get() { cat "${out}/.state/${1}" 2>/dev/null; }                               # st_get <key>
st_set() { printf '%s' "$2" > "${out}/.state/${1}.${BASHPID}" && mv -f "${out}/.state/${1}.${BASHPID}" "${out}/.state/${1}"; }   # st_set <key> <value>
st_clear() { rm -f "${out}/.state/${1}"; }
# rec <target> <code> <seconds> <ok regex>: one sample line (also sets ${last_code}). One short append is atomic, so all calls share the file.
rec() {
  local ok=0
  last_code="$2"
  [[ "$2" =~ ^($4)$ ]] && ok=1
  printf '%s|%s|%s|%s|%s\n' "$(date +%s.%N | cut -c1-14)" "$1" "$2" "$3" "${ok}" >> "${samples}"
  [ "${ok}" == "1" ]
}
# hit <target> <ok regex> <curl args...>: one timed call; leaves the response body in ${body_file}; returns 0 when ok.
hit() {
  local t="$1" okre="$2" r rc; shift 2
  r=$("${CURL[@]}" -o "${body_file}" -w '%{http_code} %{time_total}' "$@" 2>/dev/null)
  rc=$?
  [ -z "${r}" ] && r="000 5.000"
  # no HTTP answer: keep curl's exit code in the code column (000:28 timeout, 000:7 refused, 000:6 DNS, 000:35/60 TLS), it says why
  [ "${r% *}" == "000" ] && [ "${rc}" -ne 0 ] && r="000:${rc} ${r#* }"
  rec "${t}" "${r% *}" "${r#* }" "${okre}"
}
secs_since() { awk -v a="$1" -v b="$(date +%s.%N)" 'BEGIN{printf "%.3f", b-a}'; }
# one tick: run the target's function in a background subshell with its own body file
fire() { # function
  (
    body_file="${out}/.body.$$.${BASHPID}"
    "$1"
    rm -f "${body_file}"
  ) &
  fired_pid=$!
}
# every target has a loop that fires one call per interval, on the clock, unless its previous call is still running
loop() { # name function
  local name="$1" fn="$2" t0 t1 rem prev=""
  while [ "$(date +%s)" -lt "${end_ts}" ]; do
    t0=$(date +%s%N)
    if [ -n "${prev}" ] && kill -0 "${prev}" 2>/dev/null; then
      printf '%s|%s\n' "$(date +%s.%N | cut -c1-14)" "${name}" >> "${out}/skipped.csv"
    else
      fire "${fn}"
      prev="${fired_pid}"
    fi
    t1=$(date +%s%N)
    rem=$(( interval * 1000000000 - (t1 - t0) ))
    [ "${rem}" -gt 0 ] && sleep "$(awk -v r="${rem}" 'BEGIN{printf "%.3f", r/1e9}')"
  done
  wait   # calls still in flight (5 s at most) finish and are recorded before the report
}

# --- one function per target -----------------------------------------------------------------------------------------
p_vcenter() {
  local tok; tok=$(st_get vcenter_token)
  if [ -z "${tok}" ]; then
    hit vcenter-login '200|201' -X POST -u "${vc_user}:${generic_password}" "https://${vc_host}/api/session"
    tok=$(tr -d '"' < "${body_file}" 2>/dev/null)
    [ "${#tok}" -eq 32 ] || return
    st_set vcenter_token "${tok}"
  fi
  hit vcenter '200' -H "vmware-api-session-id: ${tok}" "https://${vc_host}/api/appliance/system/version"
  [[ "${last_code}" =~ ^(401|403)$ ]] && st_clear vcenter_token
}
p_nsx() {
  hit nsx '200' -u "admin:${generic_password}" "https://${nsx_host}/api/v1/cluster/status"
}
p_avi() {
  # temp names use ${BASHPID} taken HERE: inside $( ) or ( ) it would be the subshell's own pid and the file would not be found
  local csrf ver jar="${out}/.state/avi.cookies" tmpjar="${out}/.state/avi.cookies.${BASHPID}"
  csrf=$(st_get avi_csrf); ver=$(st_get avi_ver); [ -z "${ver}" ] && ver="${avi_version:-}"
  if [ -z "${csrf}" ]; then
    if [ -z "${ver}" ]; then
      ver=$("${CURL[@]}" "https://${avi_host}/api/initial-data" 2>/dev/null | jq -r '.version.Version // empty')
      [ -n "${ver}" ] && st_set avi_ver "${ver}"
    fi
    local t0l; t0l=$(date +%s.%N)
    rm -f "${tmpjar}"
    "${CURL[@]}" -X POST -H 'Content-Type: application/json' -c "${tmpjar}" \
      -d "{\"username\":\"admin\",\"password\":\"${generic_password}\"}" "https://${avi_host}/login" > /dev/null 2>&1
    csrf=$(awk '$6=="csrftoken"{print $7}' "${tmpjar}" 2>/dev/null)
    if [ -z "${csrf}" ]; then rm -f "${tmpjar}"; rec avi-login 000 "$(secs_since "${t0l}")" 'x'; return; fi
    mv -f "${tmpjar}" "${jar}"; st_set avi_csrf "${csrf}"
  fi
  hit avi '200' -b "${jar}" -H "X-CSRFToken: ${csrf}" -H "X-Avi-Tenant: admin" -H "X-Avi-Version: ${ver:-22.1.4}" \
    -H "Referer: https://${avi_host}" "https://${avi_host}/api/cluster/runtime"
  [[ "${last_code}" =~ ^(401|403|419)$ ]] && st_clear avi_csrf
}
# provider login (token in the response header); prints the token. Records one sample as <target>.
vcfa_login_as() { # target user@org password
  local r t0l tok
  t0l=$(date +%s.%N)
  r=$("${CURL[@]}" -m 10 -i -X POST "https://${vcfa_host}/cloudapi/1.0.0/sessions$([ "$2" == "admin@system" ] && echo /provider)" \
    -H "Accept: application/json;version=${vcfa_ver}" -H "Content-Type: application/json;version=${vcfa_ver}" \
    -H "Authorization: Basic $(printf '%s' "$2:$3" | base64 -w0)" 2>/dev/null)
  tok=$(printf '%s' "${r}" | grep -i '^x-vmware-vcloud-access-token:' | awk '{print $2}' | tr -d '\r')
  rec "$1" "$([ -n "${tok}" ] && echo 200 || echo "$(printf '%s' "${r}" | head -1 | awk '{print $2}')")" "$(secs_since "${t0l}")" '200'
  printf '%s' "${tok}"
}
p_vcfa_system() {
  local tok; tok=$(st_get vcfa_system_token)
  if [ -z "${tok}" ]; then
    tok=$(vcfa_login_as vcfa-system-login "admin@system" "${generic_password}")
    [ -z "${tok}" ] && return
    st_set vcfa_system_token "${tok}"
  fi
  hit vcfa-system '200' -H "Accept: application/json;version=${vcfa_ver}" -H "Authorization: Bearer ${tok}" \
    "https://${vcfa_host}/cloudapi/1.0.0/orgs?pageSize=1"
  [ "${last_code}" == "401" ] && st_clear vcfa_system_token
}
p_vcfa_org() {
  local tok; tok=$(st_get vcfa_org_token)
  if [ -z "${tok}" ]; then
    tok=$(vcfa_login_as vcfa-org-login "${first_org}@${first_org}" "${org_pw}")
    [ -z "${tok}" ] && return
    st_set vcfa_org_token "${tok}"
  fi
  hit vcfa-org '200' -H "Accept: application/json;version=${vcfa_ver}" -H "Authorization: Bearer ${tok}" \
    "https://${vcfa_host}/cloudapi/1.0.0/sessions/current"
  [ "${last_code}" == "401" ] && st_clear vcfa_org_token
}
# org portal's Kubernetes-style API (what the VKS/namespace automation uses): provider token -> org-scoped OIDC token -> CCI call
p_vcfa_org_cci() {
  local tok ptok client uuid H=(-H "Accept: application/json;version=${vcfa_ver}")
  tok=$(st_get cci_token)
  if [ -z "${tok}" ]; then
    ptok=$(vcfa_login_as vcfa-cci-login "admin@system" "${generic_password}")
    [ -z "${ptok}" ] && { rec vcfa-org-cci 000 5.000 'x'; return; }
    client=$("${CURL[@]}" "${H[@]}" -H "Authorization: Bearer ${ptok}" "https://${vcfa_host}/cloudapi/1.0.0/openIdProvider/relyingParties" \
      | jq -r '[.values[] | select(.clientName == "automation-relying-party")][0].clientId // [.values[] | select(.isPublic == true)][0].clientId')
    uuid=$("${CURL[@]}" "${H[@]}" -H "Authorization: Bearer ${ptok}" "https://${vcfa_host}/cloudapi/1.0.0/orgs?filter=name==${first_org}" \
      | jq -r '.values[0].id // empty'); uuid="${uuid##*:}"
    tok=$("${CURL[@]}" -m 10 -X POST "https://${vcfa_host}/oidc/oauth2/token" "${H[@]}" -H "x-vmware-vcloud-tenant-context: ${uuid}" \
      --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" --data-urlencode "scope=openid profile email phone groups vcd_idp" \
      --data-urlencode "assertion=${ptok}" --data-urlencode "client_id=${client}" | jq -r '.access_token // empty')
    [ -z "${tok}" ] && { rec vcfa-org-cci 000 5.000 'x'; return; }
    st_set cci_token "${tok}"
  fi
  hit vcfa-org-cci '200' -H "Authorization: Bearer ${tok}" -H "Accept: application/json" \
    "https://${vcfa_host}/cci/kubernetes/apis/infrastructure.cci.vmware.com/v1alpha3/namespaces/default-project/supervisornamespaces"
  [[ "${last_code}" =~ ^(401|403)$ ]] && st_clear cci_token
}
p_vcfa_ui() { hit vcfa-ui '200|30[0-9]|401|403' "https://${vcfa_host}/"; }
# Supervisor API endpoint, read once from vCenter (namespace-management) and kept in the state; prints it, empty when not found
sup_endpoint() {
  local ep tok cid; ep=$(st_get sup_ep)
  if [ -z "${ep}" ]; then
    tok=$("${CURL[@]}" -X POST -u "${vc_user}:${generic_password}" "https://${vc_host}/api/session" | tr -d '"')
    cid=$("${CURL[@]}" -H "vmware-api-session-id: ${tok}" "https://${vc_host}/api/vcenter/namespace-management/clusters" | jq -r '.[0].cluster // empty')
    [ -n "${cid}" ] && ep=$("${CURL[@]}" -H "vmware-api-session-id: ${tok}" "https://${vc_host}/api/vcenter/namespace-management/clusters/${cid}" | jq -r '.api_server_cluster_endpoint // empty')
    [ -n "${ep}" ] && { st_set sup_ep "${ep}"; mlog "supervisor endpoint ${ep}" >&2; }
  fi
  printf '%s' "${ep}"
}
p_supervisor() {
  local ep; ep=$(sup_endpoint)
  [ -z "${ep}" ] && { rec supervisor 000 5.000 'x'; return; }
  # anonymous readiness of the Supervisor's Kubernetes API (401/403 = answered but anonymous access is off: still reachable)
  hit supervisor '200|401|403' "https://${ep}:6443/readyz"
}
# kubectl get nodes with a given kubeconfig, recorded as <target>: code 200 = exit 0 and every node Ready; NotReady:<n>; 401 =
# Unauthorized/Forbidden (the session is dropped so the next call logs in again); 000:<reason> = no answer. The error text goes to errors.log.
kube_nodes() { # target kubeconfig
  local t="$1" kc="$2" t0l outp rc code nr
  t0l=$(date +%s.%N)
  outp=$(KUBECONFIG="${kc}" timeout 8 kubectl --request-timeout=5s get nodes --no-headers 2>&1)
  rc=$?
  if [ "${rc}" -eq 0 ]; then
    nr=$(printf '%s\n' "${outp}" | awk '$2 != "Ready" {n++} END{print n+0}')
    [ "${nr}" -eq 0 ] && code=200 || code="NotReady:${nr}"
  elif grep -qiE 'unauthorized|forbidden|must be logged in' <<< "${outp}"; then code=401
  elif grep -qiE 'timeout|deadline|timed out' <<< "${outp}" || [ "${rc}" -eq 124 ]; then code="000:timeout"
  elif grep -qi 'refused' <<< "${outp}"; then code="000:refused"
  else code="000:error"; fi
  [ "${code}" != 200 ] && printf '%s|%s|%s\n' "$(date +%T)" "${t}" "$(printf '%s' "${outp}" | tr '\n' ' ' | cut -c1-200)" >> "${out}/errors.log"
  rec "${t}" "${code}" "$(secs_since "${t0l}")" '200'
  [ "${code}" == 401 ] && return 1
  return 0
}
p_k8s_supervisor() {
  local ep kc="${out}/.state/sup.kubeconfig" tok tmpkc="${out}/.state/sup.kubeconfig.${BASHPID}"
  ep=$(sup_endpoint)
  [ -z "${ep}" ] && { rec k8s-supervisor 000 5.000 'x'; return; }
  if [ ! -s "${kc}" ]; then
    hit k8s-supervisor-login '200' -m 8 -X POST -u "${vc_user}:${generic_password}" "https://${ep}/wcp/login"
    tok=$(jq -r '.session_id // empty' "${body_file}" 2>/dev/null)
    [ -z "${tok}" ] && return
    ( umask 077; printf 'apiVersion: v1\nkind: Config\nclusters:\n- name: sup\n  cluster: {server: "https://%s:6443", insecure-skip-tls-verify: true}\nusers:\n- name: u\n  user: {token: "%s"}\ncontexts:\n- name: c\n  context: {cluster: sup, user: u}\ncurrent-context: c\n' "${ep}" "${tok}" > "${tmpkc}" ) && mv -f "${tmpkc}" "${kc}"
  fi
  kube_nodes k8s-supervisor "${kc}" || rm -f "${kc}"
}
p_k8s_vks() { kube_nodes k8s-vks "${out}/.state/vks.kubeconfig"; }
p_installer() { hit installer '200|30[0-9]|401|403' "https://${ip_vcf_installer}/"; }
p_vault() { hit vault '200|429' "https://127.0.0.1:8200/v1/sys/health"; }
p_harbor() { hit harbor '200' "https://harbor.${sub}.${domain}/api/v2.0/health"; }
p_git() { hit git '200' "https://${git_fqdn_prefix}.${sub}.${domain}/api/healthz"; }
p_vcd() { hit vcd '200' "https://${vcd_host}/api/versions"; }
dns_probe() { # target server name
  local t0l r
  t0l=$(date +%s.%N)
  r=$(dig +time=2 +tries=1 +short "@${2}" "${3}" 2>/dev/null)
  rec "$1" "$([ -n "${r}" ] && echo 200 || echo 000)" "$(secs_since "${t0l}")" '200'
}
p_dns_gw() { dns_probe dns-gw 127.0.0.1 "${vc_host}"; }
p_dns_avi() { dns_probe dns-avi "${ip_avi_dns}" "harbor.${sub}.${domain}"; }

# --- NSX Edge nodes: one extra collector (not a target) --------------------------------------------------------------
# edge.tsv: name|id|form factor|cpu cores|dpdk cores (once); edge.csv: ts|node|api code|api s|deployment state|status|mgmt|control|
# tunnel|pnic|load1|dpdk avg %|dpdk max %|other avg %|other max %|system mem %|datapath mem %|datapath heap %|datapath pool max %
edge_jq='def r: if . == null then "" else ((. * 100 | round) / 100) end;
  .node_status.system_status as $s | [(.status // ""), (.mgmt_connection_status // ""), (.control_connection_status.status // ""),
  (.tunnel_status.status // ""), (.pnic_status.status // ""), ($s.load_average[0] | r),
  ($s.cpu_usage.avg_cpu_core_usage_dpdk | r), ($s.cpu_usage.highest_cpu_core_usage_dpdk | r),
  ($s.cpu_usage.avg_cpu_core_usage_non_dpdk | r), ($s.cpu_usage.highest_cpu_core_usage_non_dpdk | r),
  ($s.edge_mem_usage.system_mem_usage | r), ($s.edge_mem_usage.datapath_total_usage | r),
  ($s.edge_mem_usage.datapath_mem_usage_details.datapath_heap_usage | r),
  ($s.edge_mem_usage.datapath_mem_usage_details.highest_datapath_mem_pool_usage | r)] | map(tostring) | join("|")'
nsx_get() { curl -sk -m 4 --connect-timeout 3 -u "admin:${generic_password}" "$@"; }   # nsx_get [-o file -w fmt] <url>
edge_one() { # node-id name
  local id="$1" name="$2" f r code t fields st
  f=$(mktemp "${out}/.state/edge.XXXXXX") || return
  r=$(nsx_get -o "${f}" -w '%{http_code} %{time_total}' "https://${nsx_host}/api/v1/transport-nodes/${id}/status" 2>/dev/null)
  [ -z "${r}" ] && r="000 4.000"
  code="${r% *}"; t="${r#* }"; fields=""
  [ "${code}" == "200" ] && fields=$(jq -r "${edge_jq}" "${f}" 2>/dev/null)
  st=$(nsx_get "https://${nsx_host}/api/v1/transport-nodes/${id}/state" 2>/dev/null | jq -r '.node_deployment_state.state // ""' 2>/dev/null)
  rm -f "${f}"
  printf '%s|%s|%s|%s|%s|%s\n' "$(date +%s.%N | cut -c1-14)" "${name}" "${code}" "${t}" "${st}" "${fields:-|||||||||||||}" >> "${out}/edge.csv"
}
edge_loop() {
  local t0 t1 rem id name
  while [ "$(date +%s)" -lt "${end_ts}" ]; do
    t0=$(date +%s%N)
    while IFS=$'\t' read -r name id _; do edge_one "${id}" "${name}" & done < "${out}/edge.tsv"
    wait   # one cycle at a time: a slow NSX answer delays the next cycle instead of piling up calls
    t1=$(date +%s%N)
    rem=$(( edge_interval * 1000000000 - (t1 - t0) ))
    [ "${rem}" -gt 0 ] && sleep "$(awk -v r="${rem}" 'BEGIN{printf "%.3f", r/1e9}')"
  done
}
# NSX alarms (history included): the whole list is re-read every 30 s into alarms.json (only the fields the report needs), and once more
# at the end, so alarms raised and resolved between two reads are still there. An alarm's onset is its _create_time.
alarm_fetch() {
  local f
  f=$(mktemp "${out}/.state/alarms.XXXXXX") || return
  if [ "$(curl -sk -m 20 --connect-timeout 3 -u "admin:${generic_password}" -o "${f}" -w '%{http_code}' "https://${nsx_host}/api/v1/alarms?page_size=1000" 2>/dev/null)" == "200" ] \
     && jq -c '[.results[]? | {t: (._create_time // .last_reported_time), r: (.resolved_time // 0), status: .status, severity: .severity, feature: .feature_name, type: .event_type, node: (.node_display_name // .entity_id // ""), reason: (.runtime_data // "")}]' "${f}" > "${f}.json" 2>/dev/null; then
    mv -f "${f}.json" "${out}/alarms.json"
  fi
  rm -f "${f}" "${f}.json"
}
alarm_loop() {
  while [ "$(date +%s)" -lt "${end_ts}" ]; do
    alarm_fetch
    sleep 30
  done
  alarm_fetch
}
edge_start() { # fills edge.tsv, returns 1 when NSX has no Edge node to read
  local list id name ff st
  : > "${out}/edge.tsv"; : > "${out}/edge.csv"
  list=$(nsx_get "https://${nsx_host}/api/v1/transport-nodes?node_types=EdgeNode" 2>/dev/null | jq -r '.results[]? | [.display_name, .node_id, (.node_deployment_info.deployment_config.form_factor // "")] | @tsv' 2>/dev/null)
  [ -z "${list}" ] && return 1
  while IFS=$'\t' read -r name id ff; do
    st=$(nsx_get "https://${nsx_host}/api/v1/transport-nodes/${id}/status" 2>/dev/null | jq -r '.node_status.system_status | [.cpu_cores, .dpdk_cpu_cores] | map(tostring) | join("|")' 2>/dev/null)
    printf '%s\t%s\t%s\t%s\n' "${name}" "${id}" "${ff}" "${st}" >> "${out}/edge.tsv"
  done <<< "${list}"
}

# --- start the loops (skip targets without an address) ---------------------------------------------------------------
pids=()
start() { # name function address-to-test [request] [auth] [ok meaning]   (skipped when the address is empty)
  if [ -z "$3" ] && [ $# -ge 3 ]; then mlog "skipped ${1}: address not known"; return; fi
  [ -n "$4" ] && printf '%s\t%s\t%s\t%s\n' "$1" "$4" "$5" "$6" >> "${out}/targets.tsv"
  loop "$1" "$2" &
  pids+=($!)
}
: > "${out}/targets.tsv"
{
  echo "started=$(date '+%Y-%m-%d %H:%M:%S')"
  echo "duration=${duration}"
  echo "interval=${interval}"
  echo "edge_interval=${edge_interval}"
  echo "host=$(hostname -f 2>/dev/null || hostname) ($(ip -4 route get 8.8.8.8 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -1))"
  echo "deployment=${deployment_kind} ${basename_sddc}.${domain}"
} > "${out}/meta.txt"
mlog "api-monitor: ${duration}s, every ${interval}s, output ${out}"
# VKS cluster of the first org: its admin kubeconfig is the one vcfa_tenant_bootstrap.sh hands to the org (client certificate, so no
# login and no kubectl context of the gw is touched). Copied once into the state (mode 600, deleted when the run ends).
vks_kc=""; vks_server=""
if command -v kubectl >/dev/null 2>&1 && [ -n "${first_org}" ]; then
  org_kc_src="$(org_home_dir "${first_org}")/.kube/config"
  if sudo -n test -s "${org_kc_src}" 2>/dev/null; then
    ( umask 077; sudo -n cat "${org_kc_src}" > "${out}/.state/vks.kubeconfig" )
    vks_kc="${out}/.state/vks.kubeconfig"
    vks_server=$(kubectl --kubeconfig "${vks_kc}" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)
  else
    mlog "skipped k8s-vks: no kubeconfig at ${org_kc_src}"
  fi
else
  mlog "skipped k8s-supervisor and k8s-vks: kubectl not installed"
fi
cleanup_secrets() { rm -f "${out}"/.state/*kubeconfig* "${out}"/.state/avi.cookies* ; }
start vcenter      p_vcenter       "${vc_host}" "GET https://${vc_host}/api/appliance/system/version" "session id from POST /api/session as ${vc_user} (new login only on 401/403, logged as vcenter-login)" "200"
start nsx          p_nsx           "${nsx_host}" "GET https://${nsx_host}/api/v1/cluster/status (NSX Manager VIP)" "basic auth, admin" "200"
start avi          p_avi           "${avi_host}" "GET https://${avi_host}/api/cluster/runtime (first controller, tenant admin)" "POST /login as admin, csrf cookie (new login only on 401/403/419, logged as avi-login)" "200"
start vcfa-system  p_vcfa_system   "${vcfa_host}" "GET https://${vcfa_host}/cloudapi/1.0.0/orgs?pageSize=1 (provider portal)" "bearer token from POST /cloudapi/1.0.0/sessions/provider as admin@system (logged as vcfa-system-login)" "200"
start vcfa-org     p_vcfa_org      "${first_org}" "GET https://${vcfa_host}/cloudapi/1.0.0/sessions/current (org portal, first org: ${first_org})" "bearer token from POST /cloudapi/1.0.0/sessions as ${first_org}@${first_org} (logged as vcfa-org-login)" "200"
start vcfa-org-cci p_vcfa_org_cci  "${first_org}" "GET https://${vcfa_host}/cci/kubernetes/apis/infrastructure.cci.vmware.com/v1alpha3/namespaces/default-project/supervisornamespaces (org ${first_org})" "org-scoped OIDC token: provider token exchanged at /oidc/oauth2/token (logged as vcfa-cci-login)" "200"
start vcfa-ui      p_vcfa_ui       "${vcfa_host}" "GET https://${vcfa_host}/ (web front end only)" "none" "200, 3xx, 401 or 403 (it answers)"
start supervisor   p_supervisor    "${vc_host}" "GET https://<Supervisor endpoint>:6443/readyz (endpoint read once from vCenter: api/vcenter/namespace-management/clusters, see monitor.log)" "anonymous" "200, 401 or 403 (the Kubernetes API answers)"
[ -n "$(command -v kubectl)" ] && start k8s-supervisor p_k8s_supervisor "${vc_host}" "kubectl get nodes against the Supervisor Kubernetes API (https://<Supervisor endpoint>:6443, kubectl --request-timeout=5s)" "vSphere session token from POST https://<Supervisor endpoint>/wcp/login as ${vc_user}, written to a private kubeconfig (new login only on Unauthorized/Forbidden, logged as k8s-supervisor-login); the gw's own kubectl contexts are not touched" "kubectl exits 0 and every node is Ready (code NotReady:<n> otherwise)"
start k8s-vks      p_k8s_vks       "${vks_kc}" "kubectl get nodes against the VKS cluster of ${first_org} (${vks_server}, kubectl --request-timeout=5s)" "admin client-certificate kubeconfig of ${first_org} (the one vcfa_tenant_bootstrap.sh copies to $(org_home_dir "${first_org}")/.kube/config)" "kubectl exits 0 and every node is Ready (code NotReady:<n> otherwise)"
start installer    p_installer     "${ip_vcf_installer}" "GET https://${ip_vcf_installer}/ (VCF Installer)" "none" "200, 3xx, 401 or 403 (it answers)"
[ -x "$(command -v vault)" ] || [ -n "$(ss -ltn 2>/dev/null | grep ':8200 ')" ] && start vault p_vault "x" "GET https://127.0.0.1:8200/v1/sys/health (Vault on the gw)" "none" "200 or 429 (active or standby, unsealed)"
start harbor       p_harbor        "${sub}" "GET https://harbor.${sub}.${domain}/api/v2.0/health (through Avi/AKO, name resolved by the gw)" "none" "200"
start git          p_git           "${git_fqdn_prefix}${sub}" "GET https://${git_fqdn_prefix}.${sub}.${domain}/api/healthz (Gitea on the shared k8s cluster, through Avi/AKO)" "none" "200"
start dns-gw       p_dns_gw        "x" "dig @127.0.0.1 ${vc_host} (the gw's own bind9; 2 s, 1 try)" "none" "a non-empty answer"
start dns-avi      p_dns_avi       "${ip_avi_dns}" "dig @${ip_avi_dns} harbor.${sub}.${domain} (Avi DNS virtual service; 2 s, 1 try)" "none" "a non-empty answer"
[ "${deployment_kind}" == "vApp" ] && start vcd p_vcd "${vcd_host}" "GET https://${vcd_host}/api/versions (VCD hosting the vApp)" "none" "200"
n=0
for ip in $(echo "${ips_esxi:-[]}" | jq -r '.[]'); do
  n=$((n+1))
  eval "p_esxi${n}() { hit esxi-${n} '200|30[0-9]' 'https://${ip}/'; }"
  start "esxi-${n}" "p_esxi${n}" "${ip}" "GET https://${ip}/ (ESXi host ${n}$(echo "${names_esxi:-[]}" | jq -r ".[$((n-1))] // empty | if . != \"\" then \": \" + . else \"\" end"))" "none" "200 or 3xx"
done
mlog "started ${#pids[@]} probes"
if [ -n "${nsx_host}" ] && edge_start; then
  edge_loop &
  pids+=($!)
  mlog "NSX Edge stats: $(cut -f1 "${out}/edge.tsv" | paste -sd, -) every ${edge_interval} s (edge.csv)"
else
  mlog "skipped NSX Edge stats: no Edge transport node found"
fi
if [ -n "${nsx_host}" ]; then
  alarm_loop &
  pids+=($!)
  mlog "NSX alarms read every 30 s (alarms.json)"
fi
# the report is rebuilt and published every 60 s, so it can be watched while the test runs
live_report() {
  while [ "$(date +%s)" -lt "${end_ts}" ]; do
    sleep 60
    make_report "${out}" > /dev/null 2>&1 && publish "${out}" > /dev/null 2>&1
  done
}
live_report > /dev/null 2>&1 &
live_pid=$!
echo '<p>api-monitor started, the first report is written within a minute (reload then).</p>' > "${out}/report.html"
link=$(publish "${out}" 2>/dev/null); [ -n "${link}" ] && mlog "html report (refreshed every 60 s): ${link}"

stop_all() { kill "${pids[@]}" "${live_pid}" 2>/dev/null; wait 2>/dev/null; }
trap 'mlog "interrupted, writing the report"; stop_all; cleanup_secrets; make_report "${out}" > /dev/null; mlog "report: ${out}/report.md"; link=$(publish "${out}") && mlog "html report: ${link}"; exit 0' INT TERM
wait "${pids[@]}"
kill "${live_pid}" 2>/dev/null
cleanup_secrets
make_report "${out}"
mlog "report: ${out}/report.md"
link=$(publish "${out}") && mlog "html report: ${link}"
