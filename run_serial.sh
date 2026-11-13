#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

HOST_NAME=$(hostname -s 2>/dev/null || hostname 2>/dev/null || uname -n 2>/dev/null || printf 'unknown')
RESULTS_DIR="results"
HOST_RESULTS_DIR="$RESULTS_DIR/$HOST_NAME"
mkdir -p "$HOST_RESULTS_DIR"

DEFAULT_WIDTH=24576
DEFAULT_HEIGHT=18432
DEFAULT_MIN_X="-2.0"
DEFAULT_MAX_X="1.0"
DEFAULT_MIN_Y="-1.5"
DEFAULT_MAX_Y="1.5"
DEFAULT_MAX_ITER=1500
DEFAULT_OUTPUT_IMG="$HOST_RESULTS_DIR/mandelbrot_serial.ppm"
DEFAULT_RUNS=3
OUTPUT_IMG="$DEFAULT_OUTPUT_IMG"

if [ "$1" == "--quick" ] || [ "$1" == "-q" ]; then
    echo ">>> [AVISO] Executando em modo rápido de teste (--quick)..."
    WIDTH=1000
    HEIGHT=1000
    MAX_ITER=200
    OUTPUT_IMG="/dev/null"
    RUNS=3
else
    WIDTH=${WIDTH:-$DEFAULT_WIDTH}
    HEIGHT=${HEIGHT:-$DEFAULT_HEIGHT}
    MIN_X=${MIN_X:-$DEFAULT_MIN_X}
    MAX_X=${MAX_X:-$DEFAULT_MAX_X}
    MIN_Y=${MIN_Y:-$DEFAULT_MIN_Y}
    MAX_Y=${MAX_Y:-$DEFAULT_MAX_Y}
    MAX_ITER=${MAX_ITER:-$DEFAULT_MAX_ITER}
    OUTPUT_IMG=${OUTPUT_IMG:-$DEFAULT_OUTPUT_IMG}
    RUNS=${RUNS:-$DEFAULT_RUNS}
fi

MIN_X=${MIN_X:-$DEFAULT_MIN_X}
MAX_X=${MAX_X:-$DEFAULT_MAX_X}
MIN_Y=${MIN_Y:-$DEFAULT_MIN_Y}
MAX_Y=${MAX_Y:-$DEFAULT_MAX_Y}

CC="gcc"
CFLAGS="-O2"
SRC_FILES="serial_c_code/image_generator.c serial_c_code/mandelbrot.c serial_c_code/complex.c"
LIBS="-lm"
BINARY="./serial"
COMPILE_CMD="$CC $CFLAGS $SRC_FILES $LIBS -o $BINARY"

echo "=========================================================="
echo "    MANDELBROT BENCHMARK SERIAL - HPC"
echo "=========================================================="
echo "Compilando: $COMPILE_CMD"
$COMPILE_CMD

# Salvar lscpu
LSCPU_FILE="$HOST_RESULTS_DIR/lscpu.txt"
lscpu > "$LSCPU_FILE"
CLINFO_FILE="$HOST_RESULTS_DIR/clinfo.txt"
clinfo > "$CLINFO_FILE"
NVIDIASMI_FILE="$HOST_RESULTS_DIR/nvidia-smi.txt"
nvidia-smi -q > "$NVIDIASMI_FILE"
echo "lscpu salvo em: $LSCPU_FILE"

GCC_VERSION_STR=$($CC --version | head -n 1)
REPORT_FILE="$HOST_RESULTS_DIR/serial_benchmark_report.txt"

echo "----------------------------------------------------------"
echo "Parâmetros Congelados:"
echo "  Resolução:           ${WIDTH} x ${HEIGHT}"
echo "  Região Complexa:     [$MIN_X, $MAX_X] x [$MIN_Y, $MAX_Y]"
echo "  Max Iterações:       $MAX_ITER"
echo "  Compilador / Flags:  $GCC_VERSION_STR"
echo "  Linha de compilação: $COMPILE_CMD"
echo "  Número de Execuções: $RUNS"
echo "----------------------------------------------------------"

# Arrays para métricas
declare -a INTERNAL_TIMES
declare -a WALL_TIMES
declare -a USER_TIMES
declare -a SYS_TIMES
declare -a MAX_RSS

TOTAL_ITERS=""

for i in $(seq 1 $RUNS); do
    echo ">>> Iniciando Execução $i de $RUNS..."
    RUN_LOG="$HOST_RESULTS_DIR/run_${i}.log"
    TIME_LOG="$HOST_RESULTS_DIR/run_${i}_time.log"

    # Executa usando /usr/bin/time -v
    /usr/bin/time -v $BINARY "$WIDTH" "$HEIGHT" "$MIN_X" "$MAX_X" "$MIN_Y" "$MAX_Y" "$MAX_ITER" "$OUTPUT_IMG" > "$RUN_LOG" 2> "$TIME_LOG"

    # Extrai métricas
    INT_TIME=$(grep "Tempo de processamento (clock_gettime):" "$RUN_LOG" | awk '{print $5}')
    TOTAL_ITERS=$(grep "Total de iteracoes somadas:" "$RUN_LOG" | awk '{print $5}')

    USER_T=$(grep "User time (seconds):" "$TIME_LOG" | awk '{print $4}')
    SYS_T=$(grep "System time (seconds):" "$TIME_LOG" | awk '{print $4}')
    WALL_T_RAW=$(grep "Elapsed (wall clock) time" "$TIME_LOG" | awk '{print $8}')
    RSS_KB=$(grep "Maximum resident set size" "$TIME_LOG" | awk '{print $6}')

    # Converter wall clock time para segundos numéricos
    WALL_SEC=$(python3 -c "
t = '$WALL_T_RAW'
parts = [float(x) for x in t.split(':')]
if len(parts) == 2:
    print(f'{parts[0]*60 + parts[1]:.3f}')
elif len(parts) == 3:
    print(f'{parts[0]*3600 + parts[1]*60 + parts[2]:.3f}')
else:
    print(f'{float(t):.3f}')
")

    INTERNAL_TIMES+=("$INT_TIME")
    WALL_TIMES+=("$WALL_SEC")
    USER_TIMES+=("$USER_T")
    SYS_TIMES+=("$SYS_T")
    MAX_RSS+=("$RSS_KB")

    echo "    [Run $i] clock_gettime: ${INT_TIME}s | Wall: ${WALL_SEC}s (${WALL_T_RAW}) | User: ${USER_T}s | Sys: ${SYS_T}s | Max RSS: ${RSS_KB} KB"
done

# ---------------------------------------------------------
# 3. Estatísticas e GFLOPS (via generate_report.py)
# ---------------------------------------------------------
python3 "$SCRIPT_DIR/generate_report.py" \
    --width="$WIDTH" \
    --height="$HEIGHT" \
    --min-x="$MIN_X" \
    --max-x="$MAX_X" \
    --min-y="$MIN_Y" \
    --max-y="$MAX_Y" \
    --max-iter="$MAX_ITER" \
    --output-img="$OUTPUT_IMG" \
    --compiler="$GCC_VERSION_STR" \
    --compile-cmd="$COMPILE_CMD" \
    --cflags="$CFLAGS" \
    --lscpu-file="$LSCPU_FILE" \
    --total-iters="$TOTAL_ITERS" \
    --internal-times "${INTERNAL_TIMES[@]}" \
    --wall-times "${WALL_TIMES[@]}" \
    --user-times "${USER_TIMES[@]}" \
    --sys-times "${SYS_TIMES[@]}" \
    --max-rss "${MAX_RSS[@]}" \
    --report-file="$REPORT_FILE"

# Limpar logs intermediários de cada rodada
rm -f "$HOST_RESULTS_DIR"/run_*.log

echo "Relatório gerado com sucesso em: $REPORT_FILE"
