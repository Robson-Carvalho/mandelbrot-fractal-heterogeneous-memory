# ==============================================================================
# Configurações do Compilador e Flags
# ==============================================================================
CC          ?= gcc
CFLAGS      = -O2 -Wall -Wextra
INCLUDES    = -I/usr/include
LIBS_MATH   = -lm
LIBS_OPENCL = -lOpenCL

# ==============================================================================
# Diretórios e Arquivos
# ==============================================================================
# 1. Projeto Serial (C Mandelbrot)
SERIAL_DIR    = serial_c_code
SERIAL_SRCS   = $(SERIAL_DIR)/image_generator.c \
                $(SERIAL_DIR)/mandelbrot.c \
                $(SERIAL_DIR)/complex.c
SERIAL_HDRS   = $(SERIAL_DIR)/mandelbrot.h \
                $(SERIAL_DIR)/complex.h
SERIAL_TARGET = serial

# 2. Projeto OpenCL (Mandelbrot paralelo)
# OPENCL_DIR escolhe a versao do codigo: opencl_code (ingenua) ou opencl_code_optimized.
# OPENCL_TARGET e o nome do binario (um por versao, para nao sobrescrever).
OPENCL_DIR    ?= opencl_code
OPENCL_SRCS   = $(OPENCL_DIR)/mandelbrot_host.c
OPENCL_HDRS   = $(OPENCL_DIR)/err_code.h
OPENCL_KERNEL = $(OPENCL_DIR)/mandelbrot_kernel.cl
OPENCL_TARGET ?= mandelbrot_opencl

# 3. Utilitários (OpenCL Inspector)
UTILS_DIR     = utils
UTILS_SRCS    = $(UTILS_DIR)/plataform.c
UTILS_TARGET  = $(UTILS_DIR)/plataform

# 4. Validador (compara a saida do OpenCL com o serial, pixel a pixel)
VALIDATE_SRC    = $(UTILS_DIR)/validate.c
VALIDATE_TARGET = $(UTILS_DIR)/validate

# ==============================================================================
# Alvos e Regras do Make
# ==============================================================================
.PHONY: all build opencl utils plataform run test run-opencl test-opencl clean help \
        experiments validate-build validate check-remote remote-sync remote-run remote-pull remote-all

# Alvo padrão
all: build opencl utils

# --- Módulos Principais ---
build: $(SERIAL_TARGET)

opencl: $(OPENCL_TARGET)

# Compila o utilitário (se necessário) e EXECUTA imediatamente
plataform: $(UTILS_TARGET)
	./$(UTILS_TARGET)

# --- Compilação dos Binários ---
$(SERIAL_TARGET): $(SERIAL_SRCS) $(SERIAL_HDRS)
	$(CC) $(CFLAGS) $(SERIAL_SRCS) $(LIBS_MATH) -o $@

$(OPENCL_TARGET): $(OPENCL_SRCS) $(OPENCL_HDRS) $(OPENCL_KERNEL)
	$(CC) $(CFLAGS) $(INCLUDES) -DKERNEL_FILE='"$(OPENCL_KERNEL)"' $(OPENCL_SRCS) -o $@ $(LIBS_OPENCL) $(LIBS_MATH)

# O serial e compilado sem o main (-Dmain=...) para reaproveitar mandelbrot() como referencia
$(VALIDATE_TARGET): $(VALIDATE_SRC) $(SERIAL_SRCS) $(SERIAL_HDRS)
	$(CC) $(CFLAGS) -Dmain=serial_main_unused -c $(SERIAL_DIR)/image_generator.c -o $(UTILS_DIR)/image_generator_nomain.o
	$(CC) $(CFLAGS) $(VALIDATE_SRC) $(UTILS_DIR)/image_generator_nomain.o \
	      $(SERIAL_DIR)/mandelbrot.c $(SERIAL_DIR)/complex.c $(LIBS_MATH) -o $@

validate-build: $(VALIDATE_TARGET)

$(UTILS_TARGET): $(UTILS_SRCS)
	$(CC) $(CFLAGS) $(INCLUDES) $< -o $@ $(LIBS_OPENCL)

# --- Execução e Testes ---
run: build
	./bash/run_serial.sh

test: build
	./bash/run_serial.sh --quick

# Argumentos opcionais: make run-opencl ARGS="24576 18432 1500 16 8 opencl_images/out.pgm"
#                              (width height max_iter local_x local_y [output])
ARGS ?=

run-opencl: opencl
	./$(OPENCL_TARGET) $(ARGS)

test-opencl: opencl
	./$(OPENCL_TARGET) 1000 1000 200

# ==============================================================================
# Experimentos (local e remoto - colmeia4/TITAN)
# ==============================================================================
# Local:   make experiments [VERSION=naive] [RUN_ARGS="local size"]
# Remoto:  make remote-all REMOTE_USER=grupoX
#          (sincroniza codigo -> roda la -> traz so os resultados, sem imagens)
#
# Resultados: results/<host>/opencl/<VERSION>_<data-hora>/  (nunca sobrescreve)
# A senha NAO fica no repositorio: o ssh pergunta uma vez (conexao reaproveitada
# por 15 min via ControlMaster). Para nao digitar: ssh-copy-id -p PORTA user@host
VERSION     ?= naive
RUN_ARGS    ?=
REMOTE_USER ?=
REMOTE_HOST ?= lacad.uefs.br
REMOTE_PORT ?= 8104
REMOTE_DIR  ?= mandelbrot-fractal-heterogeneous-memory
# script executado no remoto (ex.: REMOTE_SCRIPT=bash/run_serial.sh)
REMOTE_SCRIPT ?= bash/run_opencl.sh
CODE_DIR    ?= opencl_code
# o remoto nao recebe o .git: o commit/estado local segue junto, para constar no meta.txt
GIT_COMMIT  ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo n/a)
GIT_DIRTY   ?= $(shell git status --porcelain 2>/dev/null | wc -l)

REMOTE      = $(REMOTE_USER)@$(REMOTE_HOST)
SSH_CMD     = ssh -p $(REMOTE_PORT) -o ControlMaster=auto -o ControlPersist=15m \
              -o ControlPath=$(HOME)/.ssh/cm-mandelbrot-%C
RSYNC       = rsync -az --info=stats1 -e "$(SSH_CMD)"
# nunca enviar: historico git, resultados, imagens, binarios compilados
PUSH_EXCL   = --exclude=.git --exclude=results/ --exclude=opencl_images/ \
              --exclude='*.pgm' --exclude='*.ppm' --exclude=.local \
              --exclude=/serial --exclude='mandelbrot_opencl*' --exclude=utils/plataform \
              --exclude=utils/validate --exclude='utils/*.o'
# nunca trazer imagens
PULL_EXCL   = --exclude='*.pgm' --exclude='*.ppm'

# Valida o OpenCL contra o serial: make validate [W=1000 H=1000 ITER=200 LX=16 LY=16]
W ?= 1000
H ?= 1000
ITER ?= 200
LX ?= 16
LY ?= 16
validate: opencl $(VALIDATE_TARGET)
	./$(OPENCL_TARGET) $(W) $(H) $(ITER) $(LX) $(LY) results/.validate.bin > /dev/null
	./$(VALIDATE_TARGET) $(W) $(H) $(ITER) results/.validate.bin; rc=$$?; rm -f results/.validate.bin; exit $$rc

experiments:
	VERSION=$(VERSION) CODE_DIR=$(CODE_DIR) bash/run_opencl.sh $(RUN_ARGS)

check-remote:
	@test -n "$(REMOTE_USER)" || { echo "Defina o usuario: make <alvo> REMOTE_USER=grupoX"; exit 1; }
	@mkdir -p $(HOME)/.ssh

# Envia o codigo para o remoto (sem results, imagens e binarios; nao apaga nada la)
remote-sync: check-remote
	$(RSYNC) $(PUSH_EXCL) --rsync-path="mkdir -p $(REMOTE_DIR) && rsync" ./ $(REMOTE):$(REMOTE_DIR)/

# Roda no remoto o mesmo comando do local (envia o codigo antes)
remote-run: remote-sync
	$(SSH_CMD) $(REMOTE) "cd $(REMOTE_DIR) && GIT_COMMIT=$(GIT_COMMIT) GIT_DIRTY=$(GIT_DIRTY) VERSION=$(VERSION) CODE_DIR=$(CODE_DIR) $(REMOTE_SCRIPT) $(RUN_ARGS)"

# Traz results/ do remoto (sem imagens). Pastas tem data-hora: nada e sobrescrito.
remote-pull: check-remote
	mkdir -p results
	$(RSYNC) $(PULL_EXCL) $(REMOTE):$(REMOTE_DIR)/results/ results/

remote-all: remote-run remote-pull

# --- Limpeza ---
clean:
	rm -f $(SERIAL_TARGET)
	rm -f mandelbrot_opencl mandelbrot_opencl_*
	rm -f $(UTILS_TARGET) $(VALIDATE_TARGET) $(UTILS_DIR)/image_generator_nomain.o
	rm -f results/*.log

# --- Ajuda ---
help:
	@echo "======================================================================"
	@echo "                     MAKEFILE - MANDELBROT HPC                        "
	@echo "======================================================================"
	@echo "Alvos Disponíveis:"
	@echo "  make build      - Compila apenas o código C serial ($(SERIAL_TARGET))"
	@echo "  make opencl     - Compila o Mandelbrot OpenCL ($(OPENCL_TARGET))"
	@echo "  make plataform  - Compila E EXECUTA o inspetor OpenCL ($(UTILS_TARGET))"
	@echo "  make utils      - Compila apenas o inspetor OpenCL (sem rodar)"
	@echo "  make all        - Compila o código serial e os utilitários"
	@echo "  make run        - Executa o benchmark serial completo (run_serial.sh)"
	@echo "  make test       - Executa o benchmark rápido de validação (--quick)"
	@echo "  make run-opencl - Executa o Mandelbrot OpenCL (use ARGS=\"w h iter lx ly\")"
	@echo "  make test-opencl- Executa o OpenCL em tamanho reduzido (1000x1000, 200 iter)"
	@echo "  make experiments  - Roda bash/run_opencl.sh local (VERSION=naive RUN_ARGS=\"local size\")"
	@echo "  make remote-sync  - Envia o codigo ao remoto (REMOTE_USER=grupoX)"
	@echo "  make remote-run   - remote-sync + roda os experimentos la"
	@echo "  make remote-pull  - Traz results/ do remoto (sem imagens)"
	@echo "  make remote-all   - remote-run + remote-pull"
	@echo "  make clean      - Remove executáveis e logs temporários"
	@echo "  make help       - Exibe esta mensagem de ajuda"
	@echo "======================================================================"