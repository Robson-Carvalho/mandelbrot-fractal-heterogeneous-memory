import argparse
import statistics
import sys

def parse_args():
    parser = argparse.ArgumentParser(description="Gera relatório de benchmark do Mandelbrot Serial.")
    parser.add_argument("--width", type=int, required=True, help="Largura da imagem em pixels")
    parser.add_argument("--height", type=int, required=True, help="Altura da imagem em pixels")
    parser.add_argument("--min-x", type=float, required=True, help="Mínimo X no plano complexo")
    parser.add_argument("--max-x", type=float, required=True, help="Máximo X no plano complexo")
    parser.add_argument("--min-y", type=float, required=True, help="Mínimo Y no plano complexo")
    parser.add_argument("--max-y", type=float, required=True, help="Máximo Y no plano complexo")
    parser.add_argument("--max-iter", type=int, required=True, help="Número máximo de iterações")
    parser.add_argument("--output-img", type=str, default="/dev/null", help="Destino da imagem")
    parser.add_argument("--compiler", type=str, required=True, help="Versão do compilador")
    parser.add_argument("--compile-cmd", type=str, required=True, help="Linha de compilação")
    parser.add_argument("--cflags", type=str, default="-O2", help="Flags de compilação")
    parser.add_argument("--lscpu-file", type=str, default="results/lscpu.txt", help="Caminho do arquivo lscpu")
    parser.add_argument("--total-iters", type=int, required=True, help="Total de iterações somadas")
    parser.add_argument("--internal-times", type=float, nargs="+", required=True, help="Tempos internos (clock_gettime) em segundos")
    parser.add_argument("--wall-times", type=float, nargs="+", required=True, help="Tempos wall-clock em segundos")
    parser.add_argument("--user-times", type=float, nargs="+", required=True, help="Tempos de usuário em segundos")
    parser.add_argument("--sys-times", type=float, nargs="+", required=True, help="Tempos de sistema em segundos")
    parser.add_argument("--max-rss", type=float, nargs="+", required=True, help="Maximum Resident Set Size em KB")
    parser.add_argument("--report-file", type=str, default="results/serial_benchmark_report.txt", help="Arquivo de saída do relatório")
    return parser.parse_args()

def main():
    args = parse_args()

    # Flops por iteração Mandelbrot: ~8 operações de ponto flutuante no loop interno
    flops_per_iter = 8
    total_flops = args.total_iters * flops_per_iter

    avg_int = statistics.mean(args.internal_times)
    std_int = statistics.stdev(args.internal_times) if len(args.internal_times) > 1 else 0.0

    avg_wall = statistics.mean(args.wall_times)
    avg_user = statistics.mean(args.user_times)
    avg_sys  = statistics.mean(args.sys_times)
    avg_rss  = statistics.mean(args.max_rss)

    gflops = (total_flops / (avg_int * 1e9)) if avg_int > 0 else 0.0

    report = f"""================================================================================
RELATÓRIO DE EXECUÇÃO SERIAL - CONJUNTO DE MANDELBROT (HPC)
================================================================================

1. PARÂMETROS CONGELADOS DO PROBLEMA:
   - Resolução:                   {args.width} x {args.height} ({args.width * args.height:,} pixels)
   - Região do plano complexo:    [{args.min_x}, {args.max_x}] x [{args.min_y}, {args.max_y}]
   - Max iterações por pixel:     {args.max_iter}
   - Saída de imagem:             {args.output_img}

2. INFORMAÇÕES DE AMBIENTE E COMPILAÇÃO:
   - Compilador:                  {args.compiler}
   - Linha de compilação:         {args.compile_cmd}
   - Flags:                       {args.cflags}
   - lscpu:                       Salvo em {args.lscpu_file}

3. CONTAGEM GLOBAL E ESTIMATIVA DE FLOPS:
   - Total de iterações somadas:  {args.total_iters:,}
   - Operações por iteração:      {flops_per_iter} FLOP/iteração
   - Total estimado de FLOPs:     {total_flops:,} FLOPs
   - Desempenho Serial:           {gflops:.4f} GFLOPS

4. RESULTADOS DAS {len(args.internal_times)} EXECUÇÕES:
--------------------------------------------------------------------------------
Execução | clock_gettime (s) | Wall-clock (s) | User time (s) | System (s) | Max RSS (KB)
--------------------------------------------------------------------------------
"""
    for idx in range(len(args.internal_times)):
        report += (
            f"{idx+1:8d} | {args.internal_times[idx]:17.6f} | "
            f"{args.wall_times[idx]:14.3f} | {args.user_times[idx]:13.2f} | "
            f"{args.sys_times[idx]:10.2f} | {args.max_rss[idx]:12.0f}\n"
        )

    report += f"""--------------------------------------------------------------------------------
MÉDIA    | {avg_int:17.6f} | {avg_wall:14.3f} | {avg_user:13.2f} | {avg_sys:10.2f} | {avg_rss:12.0f}
DESV.PAD | {std_int:17.6f} |
================================================================================
"""

    print(report)

    with open(args.report_file, "w") as f:
        f.write(report)

if __name__ == "__main__":
    main()

