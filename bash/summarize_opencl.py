#!/usr/bin/env python3
"""Agrega raw.csv (uma linha por execução) em média/desvio por (experimento, label).

Uso: summarize_opencl.py raw.csv summary.csv summary.md
"""
import csv
import statistics as st
import sys
from collections import OrderedDict

METRICS = [
    "t_setup_s", "t_kernel_s", "t_kernel_wall_s", "t_read_dtoh_s", "t_total_s",
    "t_total_minus_kernel_s", "bandwidth_gbs", "bandwidth_pct_peak",
    "gflops", "gflops_pct_peak", "wall_s", "user_s", "sys_s", "max_rss_kb",
]
FIXED = ["width", "height", "max_iter", "local_x", "local_y", "wg_items", "total_iterations"]


def mean_std(vals):
    if not vals:
        return float("nan"), float("nan")
    return st.mean(vals), (st.stdev(vals) if len(vals) > 1 else 0.0)


def main(raw, out_csv, out_md):
    groups = OrderedDict()
    with open(raw, newline="") as f:
        for row in csv.DictReader(f):
            groups.setdefault((row["experiment"], row["label"]), []).append(row)

    header = ["experiment", "label"] + FIXED + ["runs_ok", "runs_failed"]
    for m in METRICS:
        header += [m + "_mean", m + "_std"]

    rows = []
    for (exp, label), rs in groups.items():
        ok = [r for r in rs if r["status"] == "OK"]
        out = {"experiment": exp, "label": label,
               "runs_ok": len(ok), "runs_failed": len(rs) - len(ok)}
        base = ok[0] if ok else rs[0]
        for k in FIXED:
            out[k] = base.get(k, "")
        for m in METRICS:
            mu, sd = mean_std([float(r[m]) for r in ok if r[m] != ""])
            out[m + "_mean"], out[m + "_std"] = mu, sd
        rows.append(out)

    with open(out_csv, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=header)
        w.writeheader()
        for r in rows:
            w.writerow({k: (f"{v:.6f}" if isinstance(v, float) else v) for k, v in r.items()})

    # ------------------------------------------------------------ markdown --
    def fmt(r, m, d=3):
        v, s = r[m + "_mean"], r[m + "_std"]
        return "-" if v != v else f"{v:.{d}f} ± {s:.{d}f}"

    lines = []
    exps = list(OrderedDict.fromkeys(r["experiment"] for r in rows))
    for exp in exps:
        sub = [r for r in rows if r["experiment"] == exp]
        lines += [f"## {exp}", ""]
        lines += ["| config | local | wg | ok/falhou | T_kernel (s) | T_total (s) | DtoH (s) "
                  "| BW (GB/s) | BW %pico | GFLOPS | GFLOPS %pico | wall (s) | RSS (KB) |",
                  "|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
        best = min((r for r in sub if r["runs_ok"]), key=lambda r: r["t_kernel_s_mean"], default=None)
        for r in sub:
            if not r["runs_ok"]:
                lines.append(f"| {r['label']} | {r['local_x']}x{r['local_y']} | {r['wg_items']} "
                             f"| 0/{r['runs_failed']} | FALHOU | | | | | | | | |")
                continue
            mark = " **(melhor)**" if (exp == "local" and r is best) else ""
            lines.append(
                f"| {r['label']}{mark} | {r['local_x']}x{r['local_y']} | {r['wg_items']} "
                f"| {r['runs_ok']}/{r['runs_failed']} | {fmt(r,'t_kernel_s',4)} | {fmt(r,'t_total_s')} "
                f"| {fmt(r,'t_read_dtoh_s')} | {fmt(r,'bandwidth_gbs')} | {fmt(r,'bandwidth_pct_peak',4)} "
                f"| {fmt(r,'gflops',1)} | {fmt(r,'gflops_pct_peak',2)} | {fmt(r,'wall_s')} "
                f"| {r['max_rss_kb_mean']:.0f} |")
        lines.append("")

    with open(out_md, "w") as f:
        f.write("\n".join(lines))
    print("\n".join(lines))


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
