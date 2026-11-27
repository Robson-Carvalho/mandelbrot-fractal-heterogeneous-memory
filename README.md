# Mandelbrot Fractal - Heterogeneous Memory (OpenCL & GPU)

Implementação e análise de desempenho do fractal de Mandelbrot comparando a linha de base em C Serial contra a paralelização massiva em GPU utilizando a API OpenCL.

---

## Pré-requisitos

Para compilar e rodar os experimentos, certifique-se de ter instalado:
- Compilador C: `gcc`
- Headers e loader OpenCL: `opencl-headers`, `ocl-icd-opencl-dev` (ou driver proprietário NVIDIA/AMD/Intel)
- Utilitários: `time` (`/usr/bin/time`), `make`, `python3`
- (Opcional para GPU NVIDIA): `clinfo`, `nvidia-smi`

No Ubuntu/Debian:
```bash
sudo apt update
sudo apt install build-essential opencl-headers ocl-icd-opencl-dev time python3 clinfo
```

---

## Como Rodar os Experimentos

### 1. Teste Rápido de Validação (Smoke Test)
Antes de executar a bateria completa (que processa imagens de 24k × 18k e pode levar vários minutos), execute o modo rápido para garantir que o compilador, o validador e a GPU estão funcionando corretamente:

```bash
./bash/run_opencl.sh --quick
```
> **O que ele faz:** roda um problema reduzido (1024×768, 200 iterações), valida pixel a pixel contra o serial e confere se a extração de métricas está OK.

---

### 2. Bateria Completa Local
Para rodar toda a suíte de experimentos exigida pelo trabalho na sua máquina local:

```bash
./bash/run_opencl.sh
```
ou pelo `Makefile`:
```bash
make experiments
```

O script executa de forma 100% automatizada:
1. **Compilação**: Constrói os binários `serial`, `mandelbrot_opencl` e `utils/validate`.
2. **Ambiente**: Coleta e registra as saídas de `lscpu`, `clinfo` e `nvidia-smi`.
3. **Sondagem (Probe)**: Identifica registradores por thread e limites de hardware do dispositivo.
4. **Experimentos**:
   - `validate`: Valida a corretude da GPU contra o serial em múltiplos casos de teste.
   - `baseline`: Executa o problema base (24576×18432, 1500 iterações, local 16×16) com 3 repetições e coleta `/usr/bin/time -v`.
   - `local`: Varre work-groups de 32 a 512 work-items (várias geometrias: 32x1, 16x2, 8x4, 8x8, 16x8, 16x16, 32x16, etc.).
   - `size`: Escala a resolução da imagem para avaliar a taxa de processamento.
   - `serial_size`: Executa o serial nos mesmos tamanhos para calcular o **ponto de crossover CPU vs GPU**.
   - `monitor`: Dispara `nvidia-smi dmon` em segundo plano para capturar clocks, temperatura, uso de GPU e consumo de energia.
5. **Agregação Automática**: Chama o `bash/summarize_opencl.py` e gera tabelas resumidas em CSV e Markdown.

---

## Versões do Código OpenCL

Cada versão fica em uma pasta própria. Quem escolhe a versão é a variável `CODE_DIR` (e `VERSION` é só o rótulo da pasta de resultados).

| Versão | Pasta (`CODE_DIR`) | O que muda |
|---|---|---|
| naive | `opencl_code` | Kernel ingênuo: 1 pixel por work-item, saída `ushort` (2 bytes/pixel) |
| warp | `opencl_code_optimized_warp` | Remapeia os work-items para cada warp cobrir um bloco 8x4 de pixels vizinhos (menos divergência) |
| memory_constant | `opencl_code_optimized_memory_constant` | Warp + LUT de cores em `__constant` e saída `uchar` (1 byte/pixel): metade da escrita na VRAM e do buffer lido via PCIe |

> **Importante:** passe sempre `VERSION` e `CODE_DIR` juntos. Se esquecer o `CODE_DIR`, o script usa o código `naive` com o rótulo que você der.

---

## Rodando Cada Versão

### Local

```bash
# naive
make experiments VERSION=naive CODE_DIR=opencl_code
# warp
make experiments VERSION=warp CODE_DIR=opencl_code_optimized_warp
# memory_constant
make experiments VERSION=memory_constant CODE_DIR=opencl_code_optimized_memory_constant
# serial (relatório em results/<host>/serial/<data-hora>/)
make run
```

Para um teste rápido de qualquer versão, acrescente `RUN_ARGS="--quick"`.

### Mudando o problema (ex.: 3000 iterações)

O problema base é 24576 × 18432 com 1500 iterações. Para alterar, passe `WIDTH`, `HEIGHT`, `MAX_ITER` e/ou `RUNS` na linha de comando. Use um rótulo diferente em `VERSION` para não misturar com as outras execuções:

```bash
make experiments VERSION=warp3k CODE_DIR=opencl_code_optimized_warp MAX_ITER=3000
make run MAX_ITER=3000        # serial
```

### Remoto (colmeia / TITAN RTX)

Um único comando sincroniza o código, roda lá e traz os resultados (sem imagens):

```bash
make remote-all REMOTE_USER=grupoX VERSION=memory_constant CODE_DIR=opencl_code_optimized_memory_constant
# serial no remoto
make remote-all REMOTE_USER=grupoX REMOTE_SCRIPT=bash/run_serial.sh
# com 3000 iterações
make remote-all REMOTE_USER=grupoX VERSION=warp3k CODE_DIR=opencl_code_optimized_warp MAX_ITER=3000
```

- O ssh pede a senha uma vez (conexão reaproveitada por 15 min). Para não digitar: `ssh-copy-id -p 8104 grupoX@lacad.uefs.br`.
- `WIDTH`, `HEIGHT`, `MAX_ITER` e `RUNS` são repassados ao remoto apenas quando passados na linha de comando.
- As etapas também podem ser rodadas separadas: `make remote-sync`, `make remote-run`, `make remote-pull`.
- A bateria completa é longa (o serial em 24576×18432 leva ~3,5 min por execução com 1500 iterações e cerca do dobro com 3000). Se a conexão cair, os resultados ficam no remoto: `make remote-pull REMOTE_USER=grupoX`.
- Não rode duas baterias ao mesmo tempo na mesma máquina: elas disputam CPU/GPU e distorcem os tempos.

---

## Onde Encontrar os Resultados

Os resultados de cada execução são salvos em um diretório com data e hora para nunca sobrescrever dados anteriores:

```
results/<HOSTNAME>/opencl/<VERSAO>_<DATA-HORA>/
├── raw.csv             # Todas as execuções individuais (uma linha por run)
├── summary.csv         # Média e desvio padrão agrupados por configuração
├── summary.md          # Tabelas formatadas em Markdown prontas para o relatório
├── occupancy.csv       # Ocupação teórica calculada por work-group
├── crossover.csv       # Tabela de crossover e speedups CPU vs GPU
├── validation.txt      # Relatório pixel a pixel da validação
├── lscpu.txt           # Dados da CPU
├── clinfo.txt          # Dados do OpenCL / Device
├── nvidia-smi.txt      # Dados da GPU
├── dmon_<HOST>.txt     # Amostragens do nvidia-smi dmon (clocks/energia)
└── logs/               # Logs brutos (stdout e /usr/bin/time -v) de cada run
```

---

## Outros Comandos Úteis

### Regenerar Resumo sem Rodar a GPU Novamente
Se você já possui o `raw.csv` gerado e deseja apenas recalcular as médias ou formatar o Markdown:
```bash
python3 bash/summarize_opencl.py \
  results/<HOST>/opencl/<PASTA>/raw.csv \
  results/<HOST>/opencl/<PASTA>/summary.csv \
  results/<HOST>/opencl/<PASTA>/summary.md
```

### Rodar Execuções Avulsas
- **Serial**:
  ```bash
  make build
  ./serial 1000 1000 -2.0 1.0 -1.5 1.5 200 /dev/null
  ```
- **OpenCL Avulso** (sem salvar imagem):
  ```bash
  make opencl
  ./mandelbrot_opencl 24576 18432 1500 16 16 none
  ```
- **OpenCL gerando imagem PGM**:
  ```bash
  ./mandelbrot_opencl 1000 1000 200 16 16 opencl_images/saida.pgm
  ```
- **Outra versão do código** (compila com outro binário, sem sobrescrever o naive):
  ```bash
  make run-opencl OPENCL_DIR=opencl_code_optimized_memory_constant \
       OPENCL_TARGET=mandelbrot_opencl_memory_constant \
       ARGS="24576 18432 1500 16 8 opencl_images/out.pgm"
  ```
  O mesmo vale para `make test-opencl` e `make validate` (use o mesmo `OPENCL_TARGET`).
  Na versão memory_constant o arquivo `.bin` é de 8 bits (tons de cinza); o validador detecta o formato pelo tamanho do arquivo.
- **Validador de corretude pontual**:
  ```bash
  make validate W=1000 H=1000 ITER=200 LX=16 LY=16
  ```
- **Inspecionar plataformas OpenCL disponíveis**:
  ```bash
  make plataform
  ```
- **Limpar binários compilados**:
  ```bash
  make clean
  ```

