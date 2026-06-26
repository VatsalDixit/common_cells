#!/usr/bin/env python3
"""
Generate the evaluation figures for the WRRA / QoS+WRRA report.

Two data sources:
  * a few single-config numbers are embedded below (topological cascade, etc.);
  * the swept results come from `results.csv`, which you produce on the sim machine:

      cd build/vsim
      bash ../../test/simulate-wrra.sh        # runs all sweeps AND builds results.csv itself
                                              # (it appends every run's CSV lines internally)

  The script already leaves a COMPLETE build/vsim/results.csv. Do NOT re-grep vsim.log into it --
  vsim.log is overwritten each run and holds only the LAST run, so `grep vsim.log > results.csv`
  would clobber the accumulated file down to a single line.

  Just copy build/vsim/results.csv next to this script and run:  python plot_arbiters.py

Figures with swept data (fig1 finer, fig5 cloud, fig6 aging) appear only if results.csv is found.
Outputs PNGs next to this file (doc/plots/).
"""
import os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

OUT = os.path.dirname(os.path.abspath(__file__))
CSV = os.path.join(OUT, "results.csv")

def save(fig, name):
    path = os.path.join(OUT, name)
    fig.tight_layout()
    fig.savefig(path, dpi=150)
    plt.close(fig)
    print("wrote", path)

def load_csv():
    """Return {kind: [ {k:v, ...}, ... ]} from results.csv (tolerant of a leading '# ')."""
    rows = {}
    if not os.path.exists(CSV):
        return rows
    for line in open(CSV):
        if "CSV," not in line:
            continue
        line = line[line.index("CSV,"):].strip()
        parts = line.split(",")
        kind = parts[1]
        rec = {}
        for kv in parts[2:]:
            if "=" not in kv:
                continue
            k, v = kv.split("=", 1)
            try:
                rec[k] = float(v) if ("." in v or "e" in v.lower()) else int(v)
            except ValueError:
                rec[k] = v
        rows.setdefault(kind, []).append(rec)
    return rows

DATA = load_csv()

# =====================================================================================
# Fig 1 - Latency vs congestion  (prefers swept CSV; falls back to the 4 embedded points)
# =====================================================================================
comp = sorted(DATA.get("compare", []), key=lambda r: r["numin"])
if comp:
    N        = [r["numin"]     for r in comp]
    rra_mean = [r["rra_mean"]  for r in comp]; rra_max = [r["rra_max"]  for r in comp]
    wrra_mean= [r["wrra_mean"] for r in comp]; wrra_max= [r["wrra_max"] for r in comp]
    qos_mean = [r["qos_mean"]  for r in comp]; qos_max = [r["qos_max"]  for r in comp]
    src_note = "(swept)"
else:
    N        = [4, 8, 16, 32]
    rra_mean = [1, 1, 10, 11];   rra_max = [1, 4, 10, 23]
    wrra_mean= [4, 8, 40, 104];  wrra_max= [7, 11, 40, 104]
    qos_mean = [0, 0, 0, 0];     qos_max = [1, 1, 1, 1]
    src_note = "(4 points)"

fig, (axm, axx) = plt.subplots(1, 2, figsize=(11, 4.2))
for ax, (a, b, c), ttl in [
    (axm, (rra_mean, wrra_mean, qos_mean), "mean latency"),
    (axx, (rra_max,  wrra_max,  qos_max),  "max (tail) latency"),
]:
    ax.plot(N, a, "o-", label="RRA (fair RR)",   color="tab:orange")
    ax.plot(N, b, "s-", label="WRRA (weighted)", color="tab:red")
    ax.plot(N, c, "^-", label="QoS+WRRA",         color="tab:green")
    if 5 in N:                                   # anchor: same source count as the cascade
        ax.axvline(5, ls=":", color="0.5", lw=1.2)
        ax.text(5, ax.get_ylim()[1], " N=5 (cascade\n source count)", color="0.4",
                fontsize=7, va="top", ha="left")
    ax.set_xlabel("number of competing flows  (NumInp)")
    ax.set_ylabel("urgent-flow latency  [cycles]")
    ax.set_title(ttl)
    ax.grid(True, alpha=0.3)
    ax.legend()
fig.suptitle(f"Latency of a latency-critical flow vs. congestion {src_note} "
             "- QoS+WRRA stays flat; RRA grows; WRRA worst", fontsize=11)
save(fig, "fig1_latency_vs_congestion.png")

# =====================================================================================
# Fig 2 - Topological unfairness: before vs after  (cc_wrr_arbiter_cascade_tb, embedded)
# =====================================================================================
src    = ["r0", "r1", "r2", "r3", "r4"]
before = [1/12, 1/12, 1/12, 1/4, 1/2]
after  = [0.2, 0.2, 0.2, 0.2, 0.2]
x = range(len(src)); w = 0.38
fig, ax = plt.subplots(figsize=(8.2, 4.8))
ax.bar([i - w/2 for i in x], before, w, label="unit weights (unfair)", color="tab:red")
ax.bar([i + w/2 for i in x], after,  w, label="source-count weights (fair)", color="tab:green")
ax.axhline(0.2, ls="--", color="gray", lw=1, label="ideal fair share (1/5)")
ax.set_xticks(list(x)); ax.set_xticklabels(src)
ax.set_ylim(0, 0.62)
ax.set_xlabel("source (r0 = farthest from destination)")
ax.set_ylabel("end-to-end bandwidth share")
ax.set_title("Topological unfairness in a NoC cascade, cured by weighted arbitration")
ax.grid(True, axis="y", alpha=0.3); ax.legend(loc="upper left")

# The weights live on the arbiter *ports* (not the sources): every source injects with local
# weight 1; fairness comes from weighting each through-port by the #sources it aggregates.
cfg = ("weight configuration (per arbiter port)\n"
       "unit (red):  every port = 1   -> plain RR per hop\n"
       "source-count (green):\n"
       "   A0 (3-in): r0, r1, r2 = 1, 1, 1\n"
       "   A1 (2-in): through = 3,  r3 = 1\n"
       "   A2 (2-in): through = 4,  r4 = 1\n"
       "through weight = # sources it aggregates")
ax.text(0.020, 0.74, cfg, transform=ax.transAxes, ha="left", va="top",
        family="monospace", fontsize=8,
        bbox=dict(boxstyle="round", facecolor="#f4f4f4", edgecolor="gray", alpha=0.95))
save(fig, "fig2_topological_before_after.png")

# =====================================================================================
# Fig 3 - Weighted bandwidth proportionality, simple bars  (cc_wrr_arbiter_tb, embedded)
# (the always-available version; fig5 is the richer swept cloud when results.csv exists)
# =====================================================================================
weights  = [1, 2, 3, 4]
total    = sum(weights)
measured = [0.100, 0.200, 0.300, 0.400]
ideal    = [wt/total for wt in weights]
x = range(len(weights)); w = 0.38
fig, ax = plt.subplots(figsize=(7, 4.2))
ax.bar([i - w/2 for i in x], measured, w, label="measured", color="tab:blue")
ax.bar([i + w/2 for i in x], ideal,    w, label="ideal  $w_i/\\Sigma w_j$", color="tab:cyan")
ax.set_xticks(list(x))
ax.set_xticklabels([f"input {i}\n(w={wt})" for i, wt in enumerate(weights)])
ax.set_ylabel("bandwidth share")
ax.set_title("WRRA delivers bandwidth proportional to weight")
ax.grid(True, axis="y", alpha=0.3); ax.legend()
save(fig, "fig3_weight_proportionality.png")

# =====================================================================================
# Fig 4 - QoS+WRRA two-tier shares  (cc_qos_wrr_arbiter_tb at nominal interval, embedded)
# =====================================================================================
# Shown at AgingInterval=4 so the low tier is clearly visible (at the nominal 64 it is ~0.8%);
# the full share-vs-interval tradeoff is fig6. Reconstructed from the aging sweep: high tier =
# 0.833 split 3:1, low tier = 0.167 split evenly.
labels = ["in0\nQoS2 w1", "in1\nQoS2 w3", "in2\nQoS0 w1", "in3\nQoS0 w1"]
share  = [0.2083, 0.6250, 0.0835, 0.0835]
colors = ["tab:green", "tab:green", "tab:orange", "tab:orange"]
fig, ax = plt.subplots(figsize=(7, 4.4))
bars = ax.bar(labels, share, color=colors)
ax.set_ylim(0, 0.72)
ax.set_ylabel("bandwidth share")
ax.set_title("QoS+WRRA (AgingInterval=4): weighted 3:1 split in the high tier;\n"
             "low tier keeps a bounded, non-zero share (aging)")
for b, s in zip(bars, share):
    ax.text(b.get_x()+b.get_width()/2, s+0.012, f"{s:.3f}", ha="center", fontsize=9)
ax.grid(True, axis="y", alpha=0.3)
# tier labels (placed in clear space)
ax.text(0.5, 0.685, "high QoS tier (3:1 by weight)", ha="center", va="center",
        color="tab:green", fontsize=9)
ax.text(2.5, 0.20, "low QoS tier\n(served via aging)", ha="center", va="center",
        color="tab:orange", fontsize=9)
save(fig, "fig4_qos_two_tier_shares.png")

# =====================================================================================
# Fig 5 - Weighted-bandwidth proportionality CLOUD  (CSV: wrrprop)
# =====================================================================================
prop = DATA.get("wrrprop", [])
if prop:
    cmap = {0: "tab:blue", 1: "tab:purple", 2: "tab:brown"}
    fig, ax = plt.subplots(figsize=(5.6, 5.4))
    seen = set()
    for r in prop:
        m = int(r["mode"])
        lbl = None
        if m not in seen:
            lbl = {0: "w=i+1", 1: "w=(i%3)+1", 2: "w=1<<(i%4)"}.get(m, f"mode {m}")
            seen.add(m)
        ax.scatter(r["ideal"], r["meas"], s=28, color=cmap.get(m, "k"), alpha=0.8, label=lbl)
    lim = max(max(r["ideal"] for r in prop), max(r["meas"] for r in prop)) * 1.05
    ax.plot([0, lim], [0, lim], "k--", lw=1, label="ideal (measured = $w_i/\\Sigma w_j$)")
    ax.set_xlim(0, lim); ax.set_ylim(0, lim)
    ax.set_xlabel("ideal share  $w_i/\\Sigma w_j$")
    ax.set_ylabel("measured share")
    ax.set_title("WRRA bandwidth is proportional to weight\n(every input, all weight patterns, all NumInp)")
    ax.grid(True, alpha=0.3); ax.legend(loc="upper left")
    save(fig, "fig5_weight_proportionality_cloud.png")
else:
    print("skip fig5 (no 'wrrprop' rows in results.csv)")

# =====================================================================================
# Fig 6 - Aging-tuning curve  (CSV: aging)  low-tier share & max-wait vs AgingInterval
# =====================================================================================
ag = sorted({r["interval"]: r for r in DATA.get("aging", [])}.values(),
            key=lambda r: r["interval"])  # dedup repeated intervals (nominal + swept)
if ag:
    iv   = [r["interval"]    for r in ag]
    losh = [r["lo_share"]    for r in ag]
    lomw = [r["lo_maxwait"]  for r in ag]
    # Two simple single-axis panels (clearer than one dual-axis plot).
    fig, (axl, axr) = plt.subplots(1, 2, figsize=(10.5, 4.2))
    axl.plot(iv, [s*100 for s in losh], "o-", color="tab:orange")
    axl.set_ylabel("low-tier bandwidth share  [%]")
    axl.set_title("smaller interval  ->  low tier gets MORE bandwidth")
    axr.plot(iv, lomw, "s-", color="tab:blue")
    axr.set_ylabel("low-tier worst-case wait  [cycles]")
    axr.set_title("smaller interval  ->  low tier waits LESS")
    for ax in (axl, axr):
        ax.set_xscale("log", base=2)
        ax.set_xticks(iv); ax.set_xticklabels([str(v) for v in iv])
        ax.set_xlabel("AgingInterval  (grants before priority climbs)")
        ax.grid(True, alpha=0.3)
    fig.suptitle("Aging knob: how AgingInterval trades low-tier service vs. QoS dominance",
                 fontsize=12)
    save(fig, "fig6_aging_tuning_curve.png")
else:
    print("skip fig6 (no 'aging' rows in results.csv)")

# =====================================================================================
# Fig 7 / 7b - Three QoS tiers across 4 inputs  (CSV: qos3, by scenario)
# =====================================================================================
def plot_qos3(rows, fname, title, note):
    rows = sorted(rows, key=lambda r: r["in"])
    labels = [f"in{int(r['in'])}\nQoS{int(r['qos'])} w{int(r['w'])}" for r in rows]
    shares = [r["share"] for r in rows]
    qoss = sorted({int(r["qos"]) for r in rows}, reverse=True)
    palette = ["tab:green", "tab:orange", "tab:red", "tab:purple"]
    qcolor = {q: palette[i] for i, q in enumerate(qoss)}
    colors = [qcolor[int(r["qos"])] for r in rows]
    fig, ax = plt.subplots(figsize=(7.6, 4.6))
    bars = ax.bar(labels, shares, color=colors)
    ax.set_ylim(0, 1.0)
    ax.set_ylabel("bandwidth share")
    ax.set_title(title)
    for b, s in zip(bars, shares):
        ax.text(b.get_x()+b.get_width()/2, s + 0.015, f"{s:.3f}", ha="center", fontsize=9)
    ax.grid(True, axis="y", alpha=0.3)
    if note:
        ax.text(0.97, 0.95, note, transform=ax.transAxes, ha="right", va="top", fontsize=8,
                bbox=dict(boxstyle="round", facecolor="#fff3e0", edgecolor="gray", alpha=0.95))
    save(fig, fname)

q3 = DATA.get("qos3", [])
scen0 = [r for r in q3 if int(r.get("scen", 0)) == 0]
scen1 = [r for r in q3 if int(r.get("scen", 0)) == 1]
if scen0:
    plot_qos3(scen0, "fig7_qos_three_tiers.png",
              "QoS+WRRA, three QoS tiers (4 inputs): bandwidth ordered by QoS",
              ("note: in1 (w3) ~ in2 (w1) - equal despite 3:1 weights.\n"
               "An input promoted by aging is served ~1 flit then demoted\n"
               "(the grant resets its age), so within-tier weights apply only\n"
               "in an input's *native* top tier, not when aged up from below."))
else:
    print("skip fig7 (no scenario-0 'qos3' rows)")
if scen1:
    plot_qos3(scen1, "fig7b_qos_three_tiers_weighted_top.png",
              "QoS+WRRA, three QoS tiers: weighted pair in the NATIVE top tier",
              ("in0 (w3) : in1 (w1) = 3:1 - the within-tier weights DO apply here,\n"
               "because the weighted pair is the native top tier (always co-eligible),\n"
               "unlike fig7 where the pair only reached the top by aging."))
else:
    print("skip fig7b (no scenario-1 'qos3' rows)")

# =====================================================================================
# Fig 8 - QoS bandwidth share THROUGH the 5-source cascade  (CSV: qoscasc)
# The cascade analog of fig4: QoS tiers applied to r0..r4, shares measured at the destination.
# =====================================================================================
qc = sorted(DATA.get("qoscasc", []), key=lambda r: r["src"])
if qc:
    labels = [f"r{int(r['src'])}\nQoS{int(r['qos'])} w{int(r['w'])}" for r in qc]
    shares = [r["share"] for r in qc]
    # high tier (QoS>0) green, low tier (QoS0) orange
    colors = ["tab:green" if int(r["qos"]) > 0 else "tab:orange" for r in qc]
    fig, ax = plt.subplots(figsize=(8.0, 4.6))
    bars = ax.bar(labels, shares, color=colors)
    ax.set_ylim(0, max(shares) * 1.25 if shares else 1.0)
    ax.set_ylabel("end-to-end bandwidth share (at destination)")
    ax.set_title("QoS+WRRA through the 5-source cascade: priority survives 3 hops\n"
                 "(high tier r0-r2 dominates; weighted split r0:r1=3:1 at the A0 merge; "
                 "low tier kept alive by aging)")
    for b, s in zip(bars, shares):
        ax.text(b.get_x()+b.get_width()/2, s + max(shares)*0.02, f"{s:.3f}",
                ha="center", fontsize=9)
    ax.grid(True, axis="y", alpha=0.3)
    # annotate the farthest-source point: r0 is 3 hops away yet leads on QoS
    ax.text(0.97, 0.95,
            "r0 is FARTHEST (3 hops) yet leads -\nQoS overrides the topological distance.\n"
            "Compare fig2, where unit weights starved r0.",
            transform=ax.transAxes, ha="right", va="top", fontsize=8,
            bbox=dict(boxstyle="round", facecolor="#e8f5e9", edgecolor="gray", alpha=0.95))
    save(fig, "fig8_qos_cascade_share.png")
else:
    print("skip fig8 (no 'qoscasc' rows in results.csv)")

print("done.")
