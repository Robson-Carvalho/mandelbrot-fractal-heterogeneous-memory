CC ?= gcc
CFLAGS = -O2
LIBS = -lm

SRC_DIR = serial_c_code
SRCS = $(SRC_DIR)/image_generator.c $(SRC_DIR)/mandelbrot.c $(SRC_DIR)/complex.c
HDRS = $(SRC_DIR)/mandelbrot.h $(SRC_DIR)/complex.h
TARGET = serial

.PHONY: all build run test clean help

all: build

build: $(TARGET)

$(TARGET): $(SRCS) $(HDRS)
	$(CC) $(CFLAGS) $(SRCS) $(LIBS) -o $(TARGET)

run: build
	./run_serial.sh

test: build
	./run_serial.sh --quick

clean:
	rm -f $(TARGET)
	rm -f results/*.log

help:
	@echo "Alvos disponíveis no Makefile:"
	@echo "  make build  - Compila o código serial com gcc -O2"
	@echo "  make run    - Executa o benchmark completo (3x ~200s) e gera relatório e lscpu"
	@echo "  make test   - Executa teste rápido (3 execuções curtas de ~0.1s para teste)"
	@echo "  make clean  - Limpa o executável serial e logs temporários"

