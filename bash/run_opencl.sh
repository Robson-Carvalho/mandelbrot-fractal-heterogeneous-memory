#!/usr/bin/env bash
# ==============================================================================
# Experimentos da versão OpenCL (kernel ingênuo) do Mandelbrot.
#
# Uso:
#   bash/run_opencl.sh                 # todos os experimentos
#   bash/run_opencl.sh local size      # só alguns
#   bash/run_opencl.sh --quick         # teste rápido (imagem pequena, poucas execuções)
#
# Experimentos:
#   baseline  config padrão (local 16x16), RUNS execuções, com /usr/bin/time -v
#   local     varre o tamanho do work-group (32..512 work-items, várias formas X x Y)
#   size      varre o tamanho da imagem (escala N) com o local fixo -> curva de escala
#   monitor   roda com MAX_ITER alto para o nvidia-smi dmon conseguir amostrar a GPU
#
# Variáveis de ambiente (opcionais):
#   WIDTH HEIGHT MAX_ITER     problema base           (24576 18432 1500)
#   RUNS                      execuções por config    (3)
#   LOCAL_X LOCAL_Y           local usado em baseline/size/monitor (16 16)
#   LOCAL_SHAPES              formas do experimento "local", ex: "32x8 16x16"
#   SIZE_DIVISORS             divisores de WIDTH/HEIGHT no "size" (64 32 16 8 4 2 1)
#   MONITOR_MAX_ITER          MAX_ITER do "monitor"   (12000)
#   VERSION                   rotulo da versao do kernel: naive, coalesced, ... (naive)
#                             Troque ao testar uma otimizacao: os resultados nunca se misturam.
#   CODE_DIR                  diretorio do codigo OpenCL (opencl_code | opencl_code_optimized)
#                             O codigo usado e copiado para <saida>/code/ junto dos resultados.
#
# Saída: results/<hostname>/opencl/<VERSION>_<AAAAMMDD-HHMMSS>/   (uma pasta por execucao)
#   raw.csv      uma linha por execução
#   summary.csv  média e desvio padrão por configuração
#   summary.md   tabelas legíveis
#   logs/        saída bruta (CHAVE: valor) e /usr/bin/time -v de cada execução
#   clinfo.txt lscpu.txt nvidia-smi*.txt dmon_*.txt meta.txt
# ==============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"   # o host lê opencl_code/mandelbrot_kernel.cl relativo à raiz

# ---------------------------------------------------------------- argumentos --
QUICK=0
EXPERIMENTS=()
for a in "$@"; do
    case "$a" in
        --quick|-q) QUICK=1 ;;
        baseline|local|size|monitor) EXPERIMENTS+=("$a") ;;
        all) EXPERIMENTS=(baseline local size monitor) ;;
        -h|--help) sed -n '2,36p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "Argumento desconhecido: $a (use --help)"; exit 1 ;;
    esac
done
[ ${#EXPERIMENTS[@]} -eq 0 ] && EXPERIMENTS=(baseline local size monitor)

# ------------------------------------------------------------------ config ----
if [ "$QUICK" -eq 1 ]; then
    WIDTH=${WIDTH:-1024}; HEIGHT=${HEIGHT:-768}; MAX_ITER=${MAX_ITER:-200}
    RUNS=${RUNS:-2}; MONITOR_MAX_ITER=${MONITOR_MAX_ITER:-2000}
else
    WIDTH=${WIDTH:-24576}; HEIGHT=${HEIGHT:-18432}; MAX_ITER=${MAX_ITER:-1500}
    RUNS=${RUNS:-3}; MONITOR_MAX_ITER=${MONITOR_MAX_ITER:-12000}
fi
LOCAL_X=${LOCAL_X:-16}
LOCAL_Y=${LOCAL_Y:-16}
LOCAL_SHAPES=${LOCAL_SHAPES:-"32x1 16x2 8x4  64x1 32x2 16x4 8x8  128x1 32x4 16x8  256x1 64x4 32x8 16x16  512x1 64x8 32x16"}
SIZE_DIVISORS=${SIZE_DIVISORS:-"64 32 16 8 4 2 1"}

HOST_NAME=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)
VERSION=${VERSION:-naive}
case "$VERSION" in
    *[!A-Za-z0-9._-]*|"") echo "ERRO: VERSION invalida: '$VERSION' (use letras, numeros, . _ -)"; exit 1 ;;
esac
CODE_DIR=${CODE_DIR:-opencl_code}
CODE_DIR=${CODE_DIR%/}
[ -f "$CODE_DIR/mandelbrot_kernel.cl" ] || { echo "ERRO: $CODE_DIR/mandelbrot_kernel.cl nao existe (CODE_DIR=$CODE_DIR)"; exit 1; }
STAMP=$(date +%Y%m%d-%H%M%S)
OUT_DIR="results/$HOST_NAME/opencl/${VERSION}_${STAMP}"
LOG_DIR="$OUT_DIR/logs"
RAW_CSV="$OUT_DIR/raw.csv"
if [ "$CODE_DIR" = "opencl_code" ]; then BINARY="./mandelbrot_opencl"
else BINARY="./mandelbrot_opencl_$(basename "$CODE_DIR")"; fi

command -v /usr/bin/time >/dev/null 2>&1 || { echo "ERRO: /usr/bin/time nao encontrado (apt install time)"; exit 1; }
command -v python3       >/dev/null 2>&1 || { echo "ERRO: python3 nao encontrado"; exit 1; }

mkdir -p "$LOG_DIR"

# ------------------------------------------------------------------ build -----
echo "=========================================================="
echo "  MANDELBROT OPENCL (ingênuo) - EXPERIMENTOS  [$HOST_NAME]"
echo "=========================================================="
echo ">>> Compilando (make opencl)..."
make opencl OPENCL_DIR="$CODE_DIR" OPENCL_TARGET="${BINARY#./}" || { echo "ERRO: falha na compilacao"; exit 1; }

# ----------------------------------------------------------------- ambiente ---
mkdir -p "$OUT_DIR/code"
cp "$CODE_DIR"/mandelbrot_kernel.cl "$CODE_DIR"/mandelbrot_host.c "$OUT_DIR/code/" 2>/dev/null
echo ">>> Coletando informacoes do ambiente em $OUT_DIR"
lscpu > "$OUT_DIR/lscpu.txt" 2>&1
if command -v clinfo >/dev/null 2>&1; then clinfo > "$OUT_DIR/clinfo.txt" 2>&1
else echo "(aviso) clinfo nao encontrado"; fi
HAS_SMI=0
if command -v nvidia-smi >/dev/null 2>&1; then
    HAS_SMI=1
    nvidia-smi    > "$OUT_DIR/nvidia-smi.txt"   2>&1
    nvidia-smi -q > "$OUT_DIR/nvidia-smi-q.txt" 2>&1
else echo "(aviso) nvidia-smi nao encontrado"; fi

{
    echo "date: $(date -Is)"
    echo "host: $HOST_NAME"
    echo "version: $VERSION"
    echo "code_dir: $CODE_DIR"
    echo "git_commit: $(git rev-parse --short HEAD 2>/dev/null || echo n/a)"
    echo "git_dirty: $(git status --porcelain 2>/dev/null | wc -l) arquivo(s) modificados"
    echo "gcc: $(gcc --version | head -n1)"
    echo "experiments: ${EXPERIMENTS[*]}"
    echo "quick: $QUICK"
    echo "width: $WIDTH"; echo "height: $HEIGHT"; echo "max_iter: $MAX_ITER"
    echo "runs: $RUNS"; echo "local_default: ${LOCAL_X}x${LOCAL_Y}"
    echo "local_shapes: $LOCAL_SHAPES"
    echo "size_divisors: $SIZE_DIVISORS"
    echo "monitor_max_iter: $MONITOR_MAX_ITER"
} > "$OUT_DIR/meta.txt"

# --------------------------------------------------------------------- CSV ----
COLS="experiment,label,run,width,height,max_iter,local_x,local_y,wg_items,status,\
t_setup_s,t_kernel_s,t_kernel_wall_s,t_read_dtoh_s,t_total_s,t_total_minus_kernel_s,\
total_iterations,bandwidth_gbs,bandwidth_pct_peak,gflops,gflops_pct_peak,\
wall_s,user_s,sys_s,max_rss_kb"
echo "$COLS" | tr -d '\\\n ' > "$RAW_CSV"; echo >> "$RAW_CSV"

# kv <chave> <arquivo>: valor de uma linha "CHAVE: valor"
kv() { grep -m1 "^$1:" "$2" | sed 's/^[^:]*: *//'; }

# wall clock do /usr/bin/time (h:mm:ss ou m:ss) -> segundos
wall_to_s() {
    awk -F': ' '/Elapsed \(wall clock\)/{t=$NF} END{
        n=split(t,a,":");
        if(n==3) printf "%.3f", a[1]*3600+a[2]*60+a[3];
        else if(n==2) printf "%.3f", a[1]*60+a[2];
        else printf "%.3f", t }' "$1"
}

# run_one <exp> <label> <w> <h> <iter> <lx> <ly> <run>
run_one() {
    local exp=$1 label=$2 w=$3 h=$4 iter=$5 lx=$6 ly=$7 run=$8
    local base="$LOG_DIR/${exp}_${label}_run${run}"
    local log="$base.log" tlog="$base.time"

    /usr/bin/time -v "$BINARY" "$w" "$h" "$iter" "$lx" "$ly" none > "$log" 2> "$tlog"
    local rc=$?

    if [ $rc -ne 0 ] || ! grep -q '^T_TOTAL_S:' "$log"; then
        local msg; msg=$(head -n1 "$log" | tr ',' ';')
        printf '    [%s %s run %s] FALHOU (rc=%s): %s\n' "$exp" "$label" "$run" "$rc" "$msg"
        echo "$exp,$label,$run,$w,$h,$iter,$lx,$ly,$((lx*ly)),FAILED,,,,,,,,,,,,,,," >> "$RAW_CSV"
        return
    fi

    local wall user sys rss
    wall=$(wall_to_s "$tlog")
    user=$(awk -F': ' '/User time/{print $2}' "$tlog")
    sys=$(awk -F': ' '/System time/{print $2}' "$tlog")
    rss=$(awk -F': ' '/Maximum resident set size/{print $2}' "$tlog")

    echo "$exp,$label,$run,$w,$h,$iter,$lx,$ly,$(kv WORK_GROUP_ITEMS "$log"),OK,\
$(kv T_SETUP_S "$log"),$(kv T_KERNEL_S "$log"),$(kv T_KERNEL_WALL_S "$log"),$(kv T_READ_DTOH_S "$log"),\
$(kv T_TOTAL_S "$log"),$(kv T_TOTAL_MINUS_KERNEL_S "$log"),$(kv TOTAL_ITERATIONS "$log"),\
$(kv BANDWIDTH_GBS "$log"),$(kv BANDWIDTH_PCT_PEAK "$log"),$(kv GFLOPS "$log"),$(kv GFLOPS_PCT_PEAK "$log"),\
$wall,$user,$sys,$rss" >> "$RAW_CSV"

    printf '    [%s %s run %s] kernel=%ss total=%ss GFLOPS=%s wall=%ss rss=%sKB\n' \
        "$exp" "$label" "$run" "$(kv T_KERNEL_S "$log")" "$(kv T_TOTAL_S "$log")" \
        "$(printf '%.1f' "$(kv GFLOPS "$log")")" "$wall" "$rss"
}

# run_cfg <exp> <label> <w> <h> <iter> <lx> <ly> [runs]
run_cfg() {
    local exp=$1 label=$2 w=$3 h=$4 iter=$5 lx=$6 ly=$7 n=${8:-$RUNS}
    echo ">>> [$exp] $label  (${w}x${h}, iter=$iter, local ${lx}x${ly}, $n execucoes)"
    for r in $(seq 1 "$n"); do run_one "$exp" "$label" "$w" "$h" "$iter" "$lx" "$ly" "$r"; done
}

# ------------------------------------------------------------- experimentos ---
exp_baseline() {
    run_cfg baseline "${LOCAL_X}x${LOCAL_Y}" "$WIDTH" "$HEIGHT" "$MAX_ITER" "$LOCAL_X" "$LOCAL_Y"
}

exp_local() {
    for shape in $LOCAL_SHAPES; do
        run_cfg local "$shape" "$WIDTH" "$HEIGHT" "$MAX_ITER" "${shape%x*}" "${shape#*x}"
    done
}

exp_size() {
    for d in $SIZE_DIVISORS; do
        local w=$((WIDTH / d)) h=$((HEIGHT / d))
        [ "$w" -lt 1 ] && w=1; [ "$h" -lt 1 ] && h=1
        run_cfg size "${w}x${h}" "$w" "$h" "$MAX_ITER" "$LOCAL_X" "$LOCAL_Y"
    done
}

exp_monitor() {
    if [ "$HAS_SMI" -ne 1 ]; then
        echo ">>> [monitor] pulado: nvidia-smi indisponivel"; return
    fi
    local dmon="$OUT_DIR/dmon_${HOST_NAME}.txt" fast="$OUT_DIR/gpu_samples_${HOST_NAME}.csv"
    echo ">>> [monitor] iniciando nvidia-smi dmon (1 s) e amostragem rapida (200 ms)"
    # dmon: pwr/temp, utilizacao, clocks, memoria (-s pucvmet), com data/hora
    nvidia-smi dmon -s pucvmet -d 1 -o DT > "$dmon" 2>&1 &
    local pid1=$!
    nvidia-smi --query-gpu=timestamp,utilization.gpu,utilization.memory,clocks.sm,clocks.mem,power.draw,temperature.gpu,memory.used \
        --format=csv -lms 200 > "$fast" 2>&1 &
    local pid2=$!
    sleep 2   # amostras em repouso antes da carga
    run_cfg monitor "iter${MONITOR_MAX_ITER}" "$WIDTH" "$HEIGHT" "$MONITOR_MAX_ITER" "$LOCAL_X" "$LOCAL_Y" 2
    sleep 2
    kill "$pid1" "$pid2" 2>/dev/null; wait "$pid1" "$pid2" 2>/dev/null
    echo "    dmon:    $dmon"
    echo "    amostras: $fast"
}

for e in "${EXPERIMENTS[@]}"; do
    case "$e" in
        baseline) exp_baseline ;;
        local)    exp_local ;;
        size)     exp_size ;;
        monitor)  exp_monitor ;;
    esac
done

# -------------------------------------------------------------------- resumo --
echo ">>> Agregando resultados..."
python3 -I "$SCRIPT_DIR/summarize_opencl.py" "$RAW_CSV" "$OUT_DIR/summary.csv" "$OUT_DIR/summary.md"
echo "=========================================================="
echo "Concluido. Resultados em: $OUT_DIR"
echo "=========================================================="
