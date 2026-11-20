// Valida a saida do OpenCL contra o codigo serial, pixel a pixel.
//
// Usa a funcao mandelbrot() REAL de serial_c_code/image_generator.c (compilada com
// -Dmain=serial_main_unused, ver Makefile), entao a referencia e exatamente o serial.
//
// Uso: ./utils/validate <width> <height> <max_iter> <iters.bin>
//   iters.bin: matriz de iteracoes (ushort, linha a linha) gerada por
//              ./mandelbrot_opencl W H ITER LX LY arquivo.bin
//
// A saida do kernel sao contagens de iteracao (inteiros), entao a tolerancia e 0:
// qualquer diferenca de iteracao e divergencia. Retorna 0 se tudo igual, 1 se houver diferenca.

#include <stdio.h>
#include <stdlib.h>

// definida em serial_c_code/image_generator.c
int mandelbrot(int px, int py, int width, int height,
               float minX, float maxX, float minY, float maxY, int max_iter);

#define MIN_X (-2.0f)
#define MAX_X ( 1.0f)
#define MIN_Y (-1.5f)
#define MAX_Y ( 1.5f)

int main(int argc, char **argv)
{
   if (argc != 5) {
      fprintf(stderr, "Uso: %s <width> <height> <max_iter> <iters.bin>\n", argv[0]);
      return 2;
   }
   int width = atoi(argv[1]), height = atoi(argv[2]), max_iter = atoi(argv[3]);
   size_t n = (size_t)width * height;

   unsigned short *gpu = (unsigned short *)malloc(n * sizeof(unsigned short));
   if (!gpu) { fprintf(stderr, "sem memoria\n"); return 2; }

   FILE *fp = fopen(argv[4], "rb");
   if (!fp) { perror("abrindo arquivo"); return 2; }
   size_t got = fread(gpu, sizeof(unsigned short), n, fp);
   fclose(fp);
   if (got != n) {
      fprintf(stderr, "arquivo com %zu valores, esperado %zu\n", got, n);
      return 2;
   }

   size_t mismatches = 0, first_x = 0, first_y = 0;
   int first_gpu = 0, first_cpu = 0, max_diff = 0;
   unsigned long long sum_gpu = 0, sum_cpu = 0;

   for (int py = 0; py < height; py++) {
      for (int px = 0; px < width; px++) {
         int ref = mandelbrot(px, py, width, height, MIN_X, MAX_X, MIN_Y, MAX_Y, max_iter);
         int out = gpu[(size_t)py * width + px];
         sum_cpu += (unsigned)ref;
         sum_gpu += (unsigned)out;
         if (ref != out) {
            int d = abs(ref - out);
            if (d > max_diff) max_diff = d;
            if (mismatches == 0) { first_x = px; first_y = py; first_gpu = out; first_cpu = ref; }
            mismatches++;
         }
      }
   }

   printf("VALIDATE_SIZE: %dx%d\n", width, height);
   printf("VALIDATE_MAX_ITER: %d\n", max_iter);
   printf("VALIDATE_PIXELS: %zu\n", n);
   printf("VALIDATE_SUM_SERIAL: %llu\n", sum_cpu);
   printf("VALIDATE_SUM_OPENCL: %llu\n", sum_gpu);
   printf("VALIDATE_MISMATCHES: %zu\n", mismatches);
   printf("VALIDATE_MAX_DIFF: %d\n", max_diff);
   if (mismatches) {
      printf("VALIDATE_FIRST_MISMATCH: px=%zu py=%zu serial=%d opencl=%d\n",
             first_x, first_y, first_cpu, first_gpu);
   }
   printf("VALIDATE_RESULT: %s\n", mismatches ? "FAIL" : "OK");

   free(gpu);
   return mismatches ? 1 : 0;
}
