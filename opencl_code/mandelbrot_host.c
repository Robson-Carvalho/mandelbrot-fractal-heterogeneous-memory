#define CL_TARGET_OPENCL_VERSION 120

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <errno.h>
#include <sys/stat.h>
#include <CL/cl.h>
#include "err_code.h"

#define DEFAULT_WIDTH     24576
#define DEFAULT_HEIGHT    18432
#define DEFAULT_MAX_ITER  1500
#define DEFAULT_LOCAL     16
#define DEFAULT_OUTPUT    "opencl_images/mandelbrot_opencl.pgm"

#define MIN_X (-2.0f)
#define MAX_X ( 1.0f)
#define MIN_Y (-1.5f)
#define MAX_Y ( 1.5f)

#define KERNEL_FILE "opencl_code/mandelbrot_kernel.cl"

static double wtime(void)
{
   struct timespec t;
   clock_gettime(CLOCK_MONOTONIC, &t);
   return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}

// Arredonda x para cima até o próximo múltiplo de m
static size_t round_up(size_t x, size_t m)
{
   return ((x + m - 1) / m) * m;
}

// Lê o arquivo do kernel para uma string
static char *load_kernel(const char *path)
{
   FILE *fp = fopen(path, "r");
   if (!fp) return NULL;

   fseek(fp, 0L, SEEK_END);
   long size = ftell(fp);
   rewind(fp);

   char *buf = (char *)malloc(size + 1);
   size_t n = fread(buf, 1, size, fp);
   buf[n] = '\0';
   fclose(fp);
   return buf;
}

// Garante que os diretorios pais de path existam
static int ensure_parent_dir(const char *path)
{
   size_t len = strlen(path);
   char *tmp = (char *)malloc(len + 1);
   if (!tmp) return -1;
   memcpy(tmp, path, len + 1);

   for (char *p = tmp + 1; *p; p++) {
      if (*p == '/') {
         *p = '\0';
         if (mkdir(tmp, 0755) != 0 && errno != EEXIST) {
            free(tmp);
            return -1;
         }
         *p = '/';
      }
   }
   free(tmp);
   return 0;
}

// Salva a matriz de iteracoes em PGM (P5) usando tabela de lookup para os tons de cinza
static int save_pgm(const char *path, const cl_ushort *iters,
                    int width, int height, int max_iter)
{
   if (ensure_parent_dir(path) != 0) {
      perror("Erro ao criar diretorio de saida");
      return -1;
   }

   FILE *fp = fopen(path, "wb");
   if (!fp) {
      perror("Erro ao abrir arquivo PGM");
      return -1;
   }

   unsigned char *lut = (unsigned char *)malloc((size_t)(max_iter + 1));
   size_t row_bytes = (size_t)width;
   unsigned char *row_buf = (unsigned char *)malloc(row_bytes);
   if (!lut || !row_buf) {
      printf("Erro: falha ao alocar buffers para gerar a imagem.\n");
      free(lut);
      free(row_buf);
      fclose(fp);
      return -1;
   }

   for (int i = 0; i < max_iter; i++) {
      lut[i] = (unsigned char)(sinf(0.1f * i) * 127.5f + 127.5f);
   }
   lut[max_iter] = 0;

   fprintf(fp, "P5\n%d %d\n255\n", width, height);

   for (int py = 0; py < height; py++) {
      const cl_ushort *row_iters = iters + (size_t)py * width;
      for (int px = 0; px < width; px++) {
         row_buf[px] = lut[row_iters[px]];
      }
      if (fwrite(row_buf, 1, row_bytes, fp) != row_bytes) {
         perror("Erro ao escrever arquivo PGM");
         free(lut);
         free(row_buf);
         fclose(fp);
         return -1;
      }
   }

   free(lut);
   free(row_buf);
   fclose(fp);
   return 0;
}

int main(int argc, char **argv)
{
   cl_int err;

   int width    = DEFAULT_WIDTH;
   int height   = DEFAULT_HEIGHT;
   int max_iter = DEFAULT_MAX_ITER;
   size_t local[2] = { DEFAULT_LOCAL, DEFAULT_LOCAL };
   const char *output_file = DEFAULT_OUTPUT;

   if (argc >= 4) {
      width    = atoi(argv[1]);
      height   = atoi(argv[2]);
      max_iter = atoi(argv[3]);
   }
   if (argc >= 6) {
      local[0] = (size_t)atoi(argv[4]);
      local[1] = (size_t)atoi(argv[5]);
   }
   if (argc >= 7) {
      output_file = argv[6];
   }
   if (width <= 0 || height <= 0 || max_iter <= 0 || max_iter > 65535 ||
       local[0] == 0 || local[1] == 0) {
      printf("Erro: parametros invalidos (max_iter deve estar em 1..65535).\n");
      return EXIT_FAILURE;
   }

   cl_platform_id platforms[16];
   cl_uint num_platforms = 0;
   err = clGetPlatformIDs(16, platforms, &num_platforms);
   checkError(err, "clGetPlatformIDs");

   cl_device_id device;
   int found = 0;
   for (cl_uint i = 0; i < num_platforms && !found; i++) {
      found = (clGetDeviceIDs(platforms[i], CL_DEVICE_TYPE_GPU, 1, &device, NULL) == CL_SUCCESS);
   }
   if (!found) {
      printf("Erro: nenhuma GPU OpenCL encontrada.\n");
      return EXIT_FAILURE;
   }

   char name[256];
   clGetDeviceInfo(device, CL_DEVICE_NAME, sizeof(name), name, NULL);
   printf("Dispositivo : %s\n", name);

   // ---- Contexto e fila de comandos ----
   cl_context context = clCreateContext(0, 1, &device, NULL, NULL, &err);
   checkError(err, "clCreateContext");

   cl_command_queue queue = clCreateCommandQueue(context, device, 0, &err);
   checkError(err, "clCreateCommandQueue");

   // ---- Carrega, compila e cria o kernel ----
   char *source = load_kernel(KERNEL_FILE);
   if (!source) {
      printf("Erro: nao foi possivel ler %s (rode a partir da raiz do projeto).\n", KERNEL_FILE);
      return EXIT_FAILURE;
   }

   cl_program program = clCreateProgramWithSource(context, 1, (const char **)&source, NULL, &err);
   checkError(err, "clCreateProgramWithSource");

   err = clBuildProgram(program, 1, &device, "-cl-fp32-correctly-rounded-divide-sqrt", NULL, NULL);
   if (err != CL_SUCCESS) {
      char log[8192];
      clGetProgramBuildInfo(program, device, CL_PROGRAM_BUILD_LOG, sizeof(log), log, NULL);
      printf("Erro ao compilar o kernel:\n%s\n", log);
      return EXIT_FAILURE;
   }

   cl_kernel kernel = clCreateKernel(program, "mandelbrot", &err);
   checkError(err, "clCreateKernel");

   // ---- NDRange: o global precisa ser MULTIPLO do local ----
   size_t max_wg;
   clGetKernelWorkGroupInfo(kernel, device, CL_KERNEL_WORK_GROUP_SIZE, sizeof(max_wg), &max_wg, NULL);
   if (local[0] * local[1] > max_wg) {
      printf("Erro: local %zux%zu = %zu work-items, maximo deste kernel = %zu.\n",
             local[0], local[1], local[0] * local[1], max_wg);
      return EXIT_FAILURE;
   }

   size_t global[2] = { round_up(width,  local[0]),
                        round_up(height, local[1]) };

   printf("Imagem      : %d x %d (%zu pixels), max_iter = %d\n",
          width, height, (size_t)width * height, max_iter);
   printf("Local size  : %zu x %zu\n", local[0], local[1]);
   printf("Global size : %zu x %zu\n", global[0], global[1]);

   size_t mem_size = (size_t)width * height * sizeof(cl_ushort);

   cl_ulong max_alloc;
   clGetDeviceInfo(device, CL_DEVICE_MAX_MEM_ALLOC_SIZE, sizeof(max_alloc), &max_alloc, NULL);
   if (mem_size > max_alloc) {
      printf("Erro: buffer de %zu bytes excede o maximo do device (%lu bytes).\n",
             mem_size, (unsigned long)max_alloc);
      return EXIT_FAILURE;
   }

   cl_mem d_iters = clCreateBuffer(context, CL_MEM_WRITE_ONLY, mem_size, NULL, &err);
   checkError(err, "clCreateBuffer");

   // ---- Argumentos do kernel ----
   float minX = MIN_X, maxX = MAX_X, minY = MIN_Y, maxY = MAX_Y;
   err  = clSetKernelArg(kernel, 0, sizeof(cl_mem), &d_iters);
   err |= clSetKernelArg(kernel, 1, sizeof(int),    &width);
   err |= clSetKernelArg(kernel, 2, sizeof(int),    &height);
   err |= clSetKernelArg(kernel, 3, sizeof(float),  &minX);
   err |= clSetKernelArg(kernel, 4, sizeof(float),  &maxX);
   err |= clSetKernelArg(kernel, 5, sizeof(float),  &minY);
   err |= clSetKernelArg(kernel, 6, sizeof(float),  &maxY);
   err |= clSetKernelArg(kernel, 7, sizeof(int),    &max_iter);
   checkError(err, "clSetKernelArg");

   err = clEnqueueNDRangeKernel(queue, kernel, 2, NULL, global, local, 0, NULL, NULL);
   checkError(err, "clEnqueueNDRangeKernel (aquecimento)");
   clFinish(queue);

   // ---- Execucao medida ----
   double t0 = wtime();
   err = clEnqueueNDRangeKernel(queue, kernel, 2, NULL, global, local, 0, NULL, NULL);
   checkError(err, "clEnqueueNDRangeKernel");
   clFinish(queue);
   double t1 = wtime();


   cl_ushort *h_iters = (cl_ushort *)malloc(mem_size);
   if (!h_iters) {
      printf("Erro: falha ao alocar memoria no host.\n");
      return EXIT_FAILURE;
   }

   err = clEnqueueReadBuffer(queue, d_iters, CL_TRUE, 0, mem_size, h_iters, 0, NULL, NULL);
   checkError(err, "clEnqueueReadBuffer");

   unsigned long long total = 0;
   size_t n_pixels = (size_t)width * height;
   for (size_t i = 0; i < n_pixels; i++) total += h_iters[i];

   double time_kernel = t1 - t0;
   printf("\nTempo do kernel      : %.6f s\n", time_kernel);
   printf("Total de iteracoes   : %llu\n", total);
   printf("Desempenho           : %.2f GFLOPS (8 FLOP/iteracao)\n",
          (double)total * 8.0 / time_kernel / 1e9);

   double t_img0 = wtime();
   if (save_pgm(output_file, h_iters, width, height, max_iter) != 0) {
      free(h_iters);
      free(source);
      clReleaseMemObject(d_iters);
      clReleaseKernel(kernel);
      clReleaseProgram(program);
      clReleaseCommandQueue(queue);
      clReleaseContext(context);
      return EXIT_FAILURE;
   }
   double t_img1 = wtime();
   printf("Imagem salva em      : %s (%.6f s)\n", output_file, t_img1 - t_img0);

   // ---- Cleanup ----
   free(h_iters);
   free(source);
   clReleaseMemObject(d_iters);
   clReleaseKernel(kernel);
   clReleaseProgram(program);
   clReleaseCommandQueue(queue);
   clReleaseContext(context);

   return EXIT_SUCCESS;
}
