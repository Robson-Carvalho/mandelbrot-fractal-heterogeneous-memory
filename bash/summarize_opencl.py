#!/usr/bin/env python3
"""Agrega os resultados de uma execução do run_opencl.sh.

Uso: summarize_opencl.py raw.csv summary.csv summary.md

Lê, na mesma pasta de raw.csv:
  raw.csv          uma linha por execução OpenCL
  serial_sizes.csv serial por tamanho (opcional)      -> tabela de crossover
  validation.txt   saída do utils/validate (opcional) -> resultado da validação
  logs/probe.log   sondagem do kernel (opcional)      -> registradores e dados do device

Gera: summary.csv (média/desvio por configuração), summary.md (tabelas),
      occupancy.csv e crossover.csv quando há dados.
"""
import csv
import math
import os
import statistics as st
import sys
from collections import OrderedDict

METRICS = [
    "t_setup_s", "t_kernel_s", "t_kernel_wall_s", "t_read_dtoh_s", "t_total_s",
    "t_total_minus_kernel_s", "bandwidth_gbs", "bandwidth_pct_peak",
    "gflops", "gflops_pct_peak", "wall_s", "user_s", "sys_s", "max_rss_kb",
    "t_setup_platform_s", "t_setup_context_s", "t_setup_build_s", "t_setup_buffers_s",
]
FIXED = ["width", "height", "max_iter", "local_x", "local_y", "wg_items", "total_iterations"]

# Limites por compute capability (NVIDIA): (max threads/SM, max blocos/SM, max warps/SM,
# registradores/SM, unidade de alocação de registradores por warp).
# Fonte: CUDA Programming Guide, tabela de capacidades por compute capability.
CC_LIMITS = {
    (7, 0): (2048, 32, 64, 65536, 256),
    (7, 5): (1024, 16, 32, 65536, 256),
    (8, 0): (2048, 32, 64, 65536, 256),
    (8, 6): (1536, 16, 48, 65536, 256),
    (8, 7): (1536, 16, 48, 65536, 256),
    (8, 9): (1536, 24, 48, 65536, 256),
    (9, 0): (2048, 32, 64, 65536, 256),
}


def mean_std(vals):
    if not vals:
        return float("nan"), float("nan")
    return st.mean(vals), (st.stdev(vals) if len(vals) > 1 else 0.0)


def kv_file(path):
    out = {}
    if not os.path.exists(path):
        return out
    with open(path) as f:
        for line in f:
            if ": " in line:
                k, v = line.split(": ", 1)
                out[k.strip()] = v.strip()
    return out


def fnum(v, d=3):
    return "-" if v != v else f"{v:.{d}f}"


def occupancy(regs, wg, warp, lim, regs_per_block):
    """Ocupação teórica de um SM (modelo da planilha de ocupação da NVIDIA).
    Considera limite de threads, de blocos, de registradores. O kernel não usa memória local
    (KERNEL_LOCAL_MEM_SIZE_BYTES ~ 0), então esse limite não restringe."""
    max_threads, max_blocks, max_warps, regs_sm, alloc = lim
    wpb = math.ceil(wg / warp)                              # warps por bloco
    by_warps = max_warps // wpb
    regs_warp = math.ceil(regs * warp / alloc) * alloc      # registradores alocados por warp
    by_regs = regs_sm // (regs_warp * wpb) if regs_warp else max_blocks
    blocks = min(by_warps, by_regs, max_blocks)
    limiter = min([("warps/SM", by_warps), ("registradores", by_regs), ("blocos/SM", max_blocks)],
                  key=lambda x: x[1])[0]
    active_warps = blocks * wpb
    return blocks, active_warps, active_warps / max_warps, limiter


def main(raw, out_csv, out_md):
    base = os.path.dirname(os.path.abspath(raw))
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
        b = ok[0] if ok else rs[0]
        for k in FIXED:
            out[k] = b.get(k, "")
        for m in METRICS:
            vals = [float(r[m]) for r in ok if r.get(m, "") != ""]
            out[m + "_mean"], out[m + "_std"] = mean_std(vals)
        rows.append(out)

    with open(out_csv, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=header)
        w.writeheader()
        for r in rows:
            w.writerow({k: (f"{v:.6f}" if isinstance(v, float) else v) for k, v in r.items()})

    def fmt(r, m, d=3):
        v, s = r[m + "_mean"], r[m + "_std"]
        return "-" if v != v else f"{v:.{d}f} ± {s:.{d}f}"

    L = []

    # ------------------------------------------------------------ validação --
    vfile = os.path.join(base, "validation.txt")
    if os.path.exists(vfile):
        txt = open(vfile).read()
        n_ok = txt.count("VALIDATE_RESULT: OK")
        n_fail = txt.count("VALIDATE_RESULT: FAIL")
        L += ["## validação (OpenCL x serial, pixel a pixel)", "",
              f"- casos idênticos ao serial: **{n_ok}**; divergentes: **{n_fail}**",
              "- detalhes em `validation.txt`", ""]

    # ----------------------------------------------------- tabelas por exp. --
    exps = list(OrderedDict.fromkeys(r["experiment"] for r in rows))
    for exp in exps:
        sub = [r for r in rows if r["experiment"] == exp]
        L += [f"## {exp}", ""]
        L += ["| config | local | wg | ok/falhou | T_kernel (s) | T_total (s) | DtoH (s) "
              "| BW (GB/s) | BW %pico | GFLOPS | GFLOPS %pico | wall (s) | RSS (KB) |",
              "|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
        best = min((r for r in sub if r["runs_ok"]), key=lambda r: r["t_kernel_s_mean"], default=None)
        for r in sub:
            if not r["runs_ok"]:
                L.append(f"| {r['label']} | {r['local_x']}x{r['local_y']} | {r['wg_items']} "
                         f"| 0/{r['runs_failed']} | FALHOU | | | | | | | | |")
                continue
            mark = " **(menor T_kernel)**" if (exp == "local" and r is best) else ""
            L.append(
                f"| {r['label']}{mark} | {r['local_x']}x{r['local_y']} | {r['wg_items']} "
                f"| {r['runs_ok']}/{r['runs_failed']} | {fmt(r,'t_kernel_s',4)} | {fmt(r,'t_total_s')} "
                f"| {fmt(r,'t_read_dtoh_s')} | {fmt(r,'bandwidth_gbs')} | {fmt(r,'bandwidth_pct_peak',4)} "
                f"| {fmt(r,'gflops',1)} | {fmt(r,'gflops_pct_peak',2)} | {fmt(r,'wall_s')} "
                f"| {r['max_rss_kb_mean']:.0f} |")
        L.append("")

    # ------------------------------------------------------ quebra do setup --
    bl = [r for r in rows if r["experiment"] == "baseline" and r["runs_ok"]]
    if bl and bl[0]["t_setup_platform_s_mean"] == bl[0]["t_setup_platform_s_mean"]:
        r = bl[0]
        L += ["## setup (baseline): onde vai o tempo antes do kernel", "",
              "| etapa | tempo (s) |", "|---|---|",
              f"| clGetPlatformIDs/clGetDeviceIDs (init do driver) | {fmt(r,'t_setup_platform_s',4)} |",
              f"| info do device + contexto + fila | {fmt(r,'t_setup_context_s',4)} |",
              f"| compilação do kernel (clBuildProgram) | {fmt(r,'t_setup_build_s',4)} |",
              f"| buffers (device + malloc no host) | {fmt(r,'t_setup_buffers_s',4)} |",
              f"| **T_setup total** | {fmt(r,'t_setup_s',4)} |", ""]

    # ------------------------------------------------------------- ocupação --
    probe = kv_file(os.path.join(base, "logs", "probe.log"))
    local_rows = [r for r in rows if r["experiment"] == "local"]
    try:
        regs = int(probe.get("KERNEL_REGISTERS", "-1"))
        cc = (int(probe["NV_COMPUTE_CAPABILITY_MAJOR"]), int(probe["NV_COMPUTE_CAPABILITY_MINOR"]))
        warp = int(probe["NV_WARP_SIZE"])
        regs_block = int(probe["NV_REGISTERS_PER_BLOCK"])
        sms = int(probe["MAX_COMPUTE_UNITS"])
    except (KeyError, ValueError):
        regs, cc, warp, regs_block, sms = -1, (-1, -1), 0, 0, 0
    if local_rows and regs > 0 and cc in CC_LIMITS:
        lim = CC_LIMITS[cc]
        L += ["## ocupação teórica por work-group (modelo NVIDIA)", "",
              f"- device: {probe.get('DEVICE_NAME','?')} | compute capability {cc[0]}.{cc[1]} | {sms} SMs | warp {warp}",
              f"- limites por SM: {lim[0]} threads, {lim[1]} blocos, {lim[2]} warps, {lim[3]} registradores",
              f"- kernel: **{regs} registradores/thread**, memória local {probe.get('KERNEL_LOCAL_MEM_SIZE_BYTES','?')} B, "
              f"spill {probe.get('KERNEL_PRIVATE_MEM_SIZE_BYTES','?')} B",
              f"- CL_KERNEL_WORK_GROUP_SIZE reportado: {probe.get('KERNEL_WORK_GROUP_SIZE','?')} "
              f"(limite do device: {probe.get('MAX_WORK_GROUP_SIZE','?')})", "",
              "| local | wg | warps/bloco | blocos/SM | warps ativos/SM | ocupação | limitante | T_kernel (s) |",
              "|---|---|---|---|---|---|---|---|"]
        occ_rows = []
        for r in local_rows:
            wg = int(r["wg_items"])
            blocks, aw, occ, limiter = occupancy(regs, wg, warp, lim, regs_block)
            tk = fmt(r, "t_kernel_s", 4) if r["runs_ok"] else "FALHOU"
            L.append(f"| {r['label']} | {wg} | {math.ceil(wg / warp)} | {blocks} | {aw} "
                     f"| {100 * occ:.1f}% | {limiter} | {tk} |")
            occ_rows.append([r["label"], wg, blocks, aw, f"{occ:.4f}", limiter,
                             f"{r['t_kernel_s_mean']:.6f}" if r["runs_ok"] else ""])
        L.append("")
        with open(os.path.join(base, "occupancy.csv"), "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["local", "wg_items", "blocks_per_sm", "active_warps", "occupancy", "limiter", "t_kernel_s_mean"])
            w.writerows(occ_rows)
    elif local_rows:
        L += ["## ocupação teórica", "",
              "- não calculada: registradores por thread indisponíveis (device não NVIDIA ou probe.log ausente).", ""]

    # ------------------------------------------------------------ crossover --
    sfile = os.path.join(base, "serial_sizes.csv")
    size_rows = {r["label"]: r for r in rows if r["experiment"] == "size" and r["runs_ok"]}
    if os.path.exists(sfile) and size_rows:
        ser = OrderedDict()
        with open(sfile, newline="") as f:
            for r in csv.DictReader(f):
                if r["time_s"]:
                    ser.setdefault((int(r["width"]), int(r["height"])), []).append(float(r["time_s"]))
        L += ["## crossover CPU (serial) x GPU (OpenCL)", "",
              "T_serial = tempo interno do serial (sem gerar imagem); T_total GPU inclui setup e DtoH; "
              "T_kernel GPU é só o kernel.", "",
              "| tamanho | pixels | T_serial (s) | T_total GPU (s) | T_kernel GPU (s) | speedup total | speedup kernel | mais rápido |",
              "|---|---|---|---|---|---|---|---|"]
        cross_rows, wins = [], []
        for (w_, h_), ts in sorted(ser.items(), key=lambda kv: kv[0][0] * kv[0][1]):
            key = f"{w_}x{h_}"
            g = size_rows.get(key)
            if not g:
                continue
            tser = st.mean(ts)
            ttot, tker = g["t_total_s_mean"], g["t_kernel_s_mean"]
            su_t, su_k = tser / ttot, tser / tker
            win = "GPU" if su_t > 1 else "CPU"
            wins.append((w_ * h_, key, win))
            L.append(f"| {key} | {w_ * h_:,} | {tser:.4f} | {ttot:.4f} | {tker:.5f} | {su_t:.2f}× | {su_k:.1f}× | {win} |")
            cross_rows.append([key, w_ * h_, f"{tser:.6f}", f"{ttot:.6f}", f"{tker:.6f}", f"{su_t:.4f}", f"{su_k:.4f}", win])
        # menor tamanho a partir do qual a GPU vence em todos os tamanhos maiores
        cross = None
        for i in range(len(wins)):
            if all(x[2] == "GPU" for x in wins[i:]):
                cross = wins[i]
                break
        L.append("")
        if cross:
            L.append(f"- **crossover (T_total)**: a GPU passa a ser mais rápida a partir de **{cross[1]}** ({cross[0]:,} pixels).")
            if cross is not wins[0]:
                L.append(f"- abaixo disso a CPU vence (overhead fixo de setup + transferência da GPU).")
            else:
                L.append("- a GPU já vence no menor tamanho medido; para achar o crossover, reduza ainda mais o tamanho.")
        else:
            L.append("- a GPU não vence em todos os tamanhos maiores medidos; aumente o tamanho para achar o crossover.")
        L.append("")
        with open(os.path.join(base, "crossover.csv"), "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["size", "pixels", "t_serial_s", "t_total_gpu_s", "t_kernel_gpu_s",
                        "speedup_total", "speedup_kernel", "faster"])
            w.writerows(cross_rows)

    with open(out_md, "w") as f:
        f.write("\n".join(L))
    print("\n".join(L))


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
