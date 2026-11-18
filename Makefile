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
OPENCL_DIR    = opencl_code
OPENCL_SRCS   = $(OPENCL_DIR)/mandelbrot_host.c
OPENCL_HDRS   = $(OPENCL_DIR)/err_code.h
OPENCL_KERNEL = $(OPENCL_DIR)/mandelbrot_kernel.cl
OPENCL_TARGET = mandelbrot_opencl

# 3. Utilitários (OpenCL Inspector)
UTILS_DIR     = utils
UTILS_SRCS    = $(UTILS_DIR)/plataform.c
UTILS_TARGET  = $(UTILS_DIR)/plataform

# ==============================================================================
# Alvos e Regras do Make
# ==============================================================================
.PHONY: all build opencl utils plataform run test run-opencl test-opencl clean help

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
	$(CC) $(CFLAGS) $(INCLUDES) $(OPENCL_SRCS) -o $@ $(LIBS_OPENCL)

$(UTILS_TARGET): $(UTILS_SRCS)
	$(CC) $(CFLAGS) $(INCLUDES) $< -o $@ $(LIBS_OPENCL)

# --- Execução e Testes ---
run: build
	./run_serial.sh

test: build
	./run_serial.sh --quick

# Argumentos opcionais: make run-opencl ARGS="24576 18432 1500 16 8"
#                              (width height max_iter local_x local_y)
ARGS ?=

run-opencl: opencl
	./$(OPENCL_TARGET) $(ARGS)

test-opencl: opencl
	./$(OPENCL_TARGET) 1000 1000 200

# --- Limpeza ---
clean:
	rm -f $(SERIAL_TARGET)
	rm -f $(OPENCL_TARGET)
	rm -f $(UTILS_TARGET)
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
	@echo "  make clean      - Remove executáveis e logs temporários"
	@echo "  make help       - Exibe esta mensagem de ajuda"
	@echo "======================================================================"