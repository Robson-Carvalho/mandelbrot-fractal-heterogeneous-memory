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

# 2. Utilitários (OpenCL Inspector)
UTILS_DIR     = utils
UTILS_SRCS    = $(UTILS_DIR)/plataform.c
UTILS_TARGET  = $(UTILS_DIR)/plataform

# ==============================================================================
# Alvos e Regras do Make
# ==============================================================================
.PHONY: all build utils plataform run test clean help

# Alvo padrão
all: build utils

# --- Módulos Principais ---
build: $(SERIAL_TARGET)

utils: $(UTILS_TARGET)

# Compila o utilitário (se necessário) e EXECUTA imediatamente
plataform: $(UTILS_TARGET)
	./$(UTILS_TARGET)

# --- Compilação dos Binários ---
$(SERIAL_TARGET): $(SERIAL_SRCS) $(SERIAL_HDRS)
	$(CC) $(CFLAGS) $(SERIAL_SRCS) $(LIBS_MATH) -o $@

$(UTILS_TARGET): $(UTILS_SRCS)
	$(CC) $(CFLAGS) $(INCLUDES) $< -o $@ $(LIBS_OPENCL)

# --- Execução e Testes ---
run: build
	./run_serial.sh

test: build
	./run_serial.sh --quick

# --- Limpeza ---
clean:
	rm -f $(SERIAL_TARGET)
	rm -f $(UTILS_TARGET)
	rm -f results/*.log

# --- Ajuda ---
help:
	@echo "======================================================================"
	@echo "                     MAKEFILE - MANDELBROT HPC                        "
	@echo "======================================================================"
	@echo "Alvos Disponíveis:"
	@echo "  make build      - Compila apenas o código C serial ($(SERIAL_TARGET))"
	@echo "  make plataform  - Compila E EXECUTA o inspetor OpenCL ($(UTILS_TARGET))"
	@echo "  make utils      - Compila apenas o inspetor OpenCL (sem rodar)"
	@echo "  make all        - Compila o código serial e os utilitários"
	@echo "  make run        - Executa o benchmark serial completo (run_serial.sh)"
	@echo "  make test       - Executa o benchmark rápido de validação (--quick)"
	@echo "  make clean      - Remove executáveis e logs temporários"
	@echo "  make help       - Exibe esta mensagem de ajuda"
	@echo "======================================================================"