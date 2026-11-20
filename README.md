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

