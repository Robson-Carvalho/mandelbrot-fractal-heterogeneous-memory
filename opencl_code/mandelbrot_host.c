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

// Saida padronizada "CHAVE: valor" (facil de dar grep/awk)
#define KV_STR(k, v)   printf("%s: %s\n", k, v)
#define KV_INT(k, v)   printf("%s: %lld\n", k, (long long)(v))
#define KV_ULL(k, v)   printf("%s: %llu\n", k, (unsigned long long)(v))
#define KV_DBL(k, v)   printf("%s: %.6f\n", k, (double)(v))

#define PEAK_BW_GBS     672.0    // TITAN RTX
#define PEAK_GFLOPS     16300.0  // FP32 TITAN RTX
#define FLOP_PER_ITER   8.0

#define MIN_X (-2.0f)
#define MAX_X ( 1.0f)
#define MIN_Y (-1.5f)
#define MAX_Y ( 1.5f)

// O Makefile passa -DKERNEL_FILE=... conforme o diretorio de codigo (OPENCL_DIR)
#ifndef KERNEL_FILE
#define KERNEL_FILE "opencl_code/mandelbrot_kernel.cl"
#endif

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

// Duracao (ns) de um evento OpenCL: END - START
static double event_ns(cl_event ev, const char *msg)
{
   cl_ulong t0 = 0, t1 = 0;
   cl_int err;
   err = clGetEventProfilingInfo(ev, CL_PROFILING_COMMAND_START, sizeof(t0), &t0, NULL);
   checkError(err, msg);
   err = clGetEventProfilingInfo(ev, CL_PROFILING_COMMAND_END, sizeof(t1), &t1, NULL);
   checkError(err, msg);
   return (double)(t1 - t0);
}

int main(int argc, char **argv)
{
   cl_int err;

   int width    = DEFAULT_WIDTH;
   int height   = DEFAULT_HEIGHT;
   int max_iter = DEFAULT_MAX_ITER;
   size_t local[2] = { DEFAULT_LOCAL, DEFAULT_LOCAL };
   const char *output_file = DEFAULT_OUTPUT;

   // Uso: ./mandelbrot_opencl [width height max_iter [local_x local_y [saida.pgm | none]]]
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
   int save_image = (strcmp(output_file, "none") != 0 && strcmp(output_file, "-") != 0);

   if (width <= 0 || height <= 0 || max_iter <= 0 || max_iter > 65535 ||
       local[0] == 0 || local[1] == 0) {
      printf("Erro: parametros invalidos (max_iter deve estar em 1..65535).\n");
      return EXIT_FAILURE;
   }

   // ================= T_total comeca aqui (setup incluido) =================
   double t_start = wtime();

   cl_platform_id platforms[16];
   cl_uint num_platforms = 0;
   err = clGetPlatformIDs(16, platforms, &num_platforms);
   checkError(err, "clGetPlatformIDs");

   cl_platform_id platform = NULL;
   cl_device_id device;
   int found = 0;
   for (cl_uint i = 0; i < num_platforms && !found; i++) {
      if (clGetDeviceIDs(platforms[i], CL_DEVICE_TYPE_GPU, 1, &device, NULL) == CL_SUCCESS) {
         platform = platforms[i];
         found = 1;
      }
   }
   if (!found) {
      printf("Erro: nenhuma GPU OpenCL encontrada.\n");
      return EXIT_FAILURE;
   }

   // ---- Informacoes do dispositivo ----
   char dev_name[256], plat_name[256], dev_ver[256];
   cl_uint compute_units = 0;
   size_t max_wg_dev = 0;
   size_t max_item_sizes[3] = {0, 0, 0};
   cl_ulong local_mem = 0, global_mem = 0, max_alloc = 0;

   err = clGetPlatformInfo(platform, CL_PLATFORM_NAME, sizeof(plat_name), plat_name, NULL);
   checkError(err, "clGetPlatformInfo(CL_PLATFORM_NAME)");
   err = clGetDeviceInfo(device, CL_DEVICE_NAME, sizeof(dev_name), dev_name, NULL);
   checkError(err, "clGetDeviceInfo(CL_DEVICE_NAME)");
   err = clGetDeviceInfo(device, CL_DEVICE_VERSION, sizeof(dev_ver), dev_ver, NULL);
   checkError(err, "clGetDeviceInfo(CL_DEVICE_VERSION)");
   err = clGetDeviceInfo(device, CL_DEVICE_MAX_COMPUTE_UNITS, sizeof(compute_units), &compute_units, NULL);
   checkError(err, "clGetDeviceInfo(CL_DEVICE_MAX_COMPUTE_UNITS)");
   err = clGetDeviceInfo(device, CL_DEVICE_MAX_WORK_GROUP_SIZE, sizeof(max_wg_dev), &max_wg_dev, NULL);
   checkError(err, "clGetDeviceInfo(CL_DEVICE_MAX_WORK_GROUP_SIZE)");
   err = clGetDeviceInfo(device, CL_DEVICE_MAX_WORK_ITEM_SIZES, sizeof(max_item_sizes), max_item_sizes, NULL);
   checkError(err, "clGetDeviceInfo(CL_DEVICE_MAX_WORK_ITEM_SIZES)");
   err = clGetDeviceInfo(device, CL_DEVICE_LOCAL_MEM_SIZE, sizeof(local_mem), &local_mem, NULL);
   checkError(err, "clGetDeviceInfo(CL_DEVICE_LOCAL_MEM_SIZE)");
   err = clGetDeviceInfo(device, CL_DEVICE_GLOBAL_MEM_SIZE, sizeof(global_mem), &global_mem, NULL);
   checkError(err, "clGetDeviceInfo(CL_DEVICE_GLOBAL_MEM_SIZE)");
   err = clGetDeviceInfo(device, CL_DEVICE_MAX_MEM_ALLOC_SIZE, sizeof(max_alloc), &max_alloc, NULL);
   checkError(err, "clGetDeviceInfo(CL_DEVICE_MAX_MEM_ALLOC_SIZE)");

   // ---- Contexto e fila de comandos (com profiling) ----
   cl_context context = clCreateContext(0, 1, &device, NULL, NULL, &err);
   checkError(err, "clCreateContext");

   cl_command_queue queue = clCreateCommandQueue(context, device, CL_QUEUE_PROFILING_ENABLE, &err);
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
   }
   checkError(err, "clBuildProgram");

   cl_kernel kernel = clCreateKernel(program, "mandelbrot", &err);
   checkError(err, "clCreateKernel");

   // ---- Limites do kernel ----
   size_t k_max_wg = 0, k_pref_mult = 0;
   cl_ulong k_local_mem = 0, k_private_mem = 0;
   err = clGetKernelWorkGroupInfo(kernel, device, CL_KERNEL_WORK_GROUP_SIZE, sizeof(k_max_wg), &k_max_wg, NULL);
   checkError(err, "clGetKernelWorkGroupInfo(CL_KERNEL_WORK_GROUP_SIZE)");
   err = clGetKernelWorkGroupInfo(kernel, device, CL_KERNEL_PREFERRED_WORK_GROUP_SIZE_MULTIPLE, sizeof(k_pref_mult), &k_pref_mult, NULL);
   checkError(err, "clGetKernelWorkGroupInfo(CL_KERNEL_PREFERRED_WORK_GROUP_SIZE_MULTIPLE)");
   err = clGetKernelWorkGroupInfo(kernel, device, CL_KERNEL_LOCAL_MEM_SIZE, sizeof(k_local_mem), &k_local_mem, NULL);
   checkError(err, "clGetKernelWorkGroupInfo(CL_KERNEL_LOCAL_MEM_SIZE)");
   err = clGetKernelWorkGroupInfo(kernel, device, CL_KERNEL_PRIVATE_MEM_SIZE, sizeof(k_private_mem), &k_private_mem, NULL);
   checkError(err, "clGetKernelWorkGroupInfo(CL_KERNEL_PRIVATE_MEM_SIZE)");

   size_t wg_items = local[0] * local[1];
   if (wg_items > k_max_wg) {
      printf("Erro: local %zux%zu = %zu work-items, maximo deste kernel = %zu.\n",
             local[0], local[1], wg_items, k_max_wg);
      return EXIT_FAILURE;
   }

   // ---- NDRange: o global precisa ser MULTIPLO do local ----
   size_t global[2] = { round_up(width,  local[0]),
                        round_up(height, local[1]) };

   size_t n_pixels = (size_t)width * height;
   size_t mem_size = n_pixels * sizeof(cl_ushort);
   if (mem_size > max_alloc) {
      printf("Erro: buffer de %zu bytes excede o maximo do device (%lu bytes).\n",
             mem_size, (unsigned long)max_alloc);
      return EXIT_FAILURE;
   }

   cl_mem d_iters = clCreateBuffer(context, CL_MEM_WRITE_ONLY, mem_size, NULL, &err);
   checkError(err, "clCreateBuffer");

   cl_ushort *h_iters = (cl_ushort *)malloc(mem_size);
   if (!h_iters) {
      printf("Erro: falha ao alocar memoria no host.\n");
      return EXIT_FAILURE;
   }

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

   double t_setup_end = wtime();

   // ---- Aquecimento (NAO entra no T_total) ----
   double t_warm0 = wtime();
   err = clEnqueueNDRangeKernel(queue, kernel, 2, NULL, global, local, 0, NULL, NULL);
   checkError(err, "clEnqueueNDRangeKernel (aquecimento)");
   err = clFinish(queue);
   checkError(err, "clFinish (aquecimento)");
   double t_warm = wtime() - t_warm0;

   // ---- Execucao medida: kernel ----
   cl_event ev_kernel;
   double t_k0 = wtime();
   err = clEnqueueNDRangeKernel(queue, kernel, 2, NULL, global, local, 0, NULL, &ev_kernel);
   checkError(err, "clEnqueueNDRangeKernel");
   err = clFinish(queue);
   checkError(err, "clFinish");
   double t_kernel_wall = wtime() - t_k0;

   // ---- Transferencia device -> host ----
   cl_event ev_read;
   double t_r0 = wtime();
   err = clEnqueueReadBuffer(queue, d_iters, CL_TRUE, 0, mem_size, h_iters, 0, NULL, &ev_read);
   checkError(err, "clEnqueueReadBuffer");
   double t_read_wall = wtime() - t_r0;

   // ================= fim do T_total (sem aquecimento, sem PGM) =================
   double t_end = wtime();

   double t_total  = (t_end - t_start) - t_warm;
   double t_setup  = t_setup_end - t_start;
   double kernel_ns = event_ns(ev_kernel, "clGetEventProfilingInfo(kernel)");
   double read_ns   = event_ns(ev_read,   "clGetEventProfilingInfo(read)");
   double kernel_s  = kernel_ns / 1e9;

   unsigned long long total_iters = 0;
   for (size_t i = 0; i < n_pixels; i++) total_iters += h_iters[i];

   // ---- Metricas ----
   double bytes_written = (double)mem_size;  // 1 ushort por pixel
   double bytes_read    = 0.0;               // kernel nao le nada da memoria global
   double bw_gbs        = (bytes_read + bytes_written) / kernel_ns;  // bytes/ns == GB/s
   double gflops        = (double)total_iters * FLOP_PER_ITER / kernel_ns; // flop/ns == GFLOPS

   // ---- Saida CHAVE: valor ----
   KV_STR("PLATFORM_NAME", plat_name);
   KV_STR("DEVICE_NAME", dev_name);
   KV_STR("DEVICE_OPENCL_VERSION", dev_ver);
   KV_INT("MAX_COMPUTE_UNITS", compute_units);
   KV_INT("MAX_WORK_GROUP_SIZE", max_wg_dev);
   printf("MAX_WORK_ITEM_SIZES: %zu %zu %zu\n", max_item_sizes[0], max_item_sizes[1], max_item_sizes[2]);
   KV_ULL("LOCAL_MEM_SIZE_BYTES", local_mem);
   KV_ULL("GLOBAL_MEM_SIZE_BYTES", global_mem);
   KV_ULL("MAX_MEM_ALLOC_SIZE_BYTES", max_alloc);
   KV_INT("KERNEL_WORK_GROUP_SIZE", k_max_wg);
   KV_INT("KERNEL_PREFERRED_WG_MULTIPLE", k_pref_mult);
   KV_ULL("KERNEL_LOCAL_MEM_SIZE_BYTES", k_local_mem);
   KV_ULL("KERNEL_PRIVATE_MEM_SIZE_BYTES", k_private_mem);

   KV_INT("WIDTH", width);
   KV_INT("HEIGHT", height);
   KV_ULL("PIXELS", n_pixels);
   KV_INT("MAX_ITER", max_iter);
   KV_INT("LOCAL_X", local[0]);
   KV_INT("LOCAL_Y", local[1]);
   KV_INT("WORK_GROUP_ITEMS", wg_items);
   KV_INT("GLOBAL_X", global[0]);
   KV_INT("GLOBAL_Y", global[1]);

   KV_DBL("T_SETUP_S", t_setup);
   KV_DBL("T_WRITE_HTOD_S", 0.0);   // Mandelbrot nao tem dados de entrada
   KV_DBL("T_WARMUP_S", t_warm);
   KV_DBL("T_KERNEL_NS", kernel_ns);
   KV_DBL("T_KERNEL_S", kernel_s);
   KV_DBL("T_KERNEL_WALL_S", t_kernel_wall);
   KV_DBL("T_READ_DTOH_NS", read_ns);
   KV_DBL("T_READ_DTOH_S", t_read_wall);
   KV_DBL("T_TOTAL_S", t_total);
   KV_DBL("T_TOTAL_MINUS_KERNEL_S", t_total - kernel_s);

   KV_ULL("TOTAL_ITERATIONS", total_iters);
   KV_ULL("BYTES_WRITTEN", mem_size);
   KV_ULL("BYTES_READ", 0);
   KV_DBL("BANDWIDTH_GBS", bw_gbs);
   KV_DBL("BANDWIDTH_PCT_PEAK", 100.0 * bw_gbs / PEAK_BW_GBS);
   KV_DBL("GFLOPS", gflops);
   KV_DBL("GFLOPS_PCT_PEAK", 100.0 * gflops / PEAK_GFLOPS);

   // ---- Imagem (opcional, fora do T_total) ----
   if (save_image) {
      double t_img0 = wtime();
      if (save_pgm(output_file, h_iters, width, height, max_iter) != 0) {
         return EXIT_FAILURE;
      }
      KV_STR("IMAGE_FILE", output_file);
      KV_DBL("T_SAVE_IMAGE_S", wtime() - t_img0);
   } else {
      KV_STR("IMAGE_FILE", "none");
   }

   // ---- Cleanup ----
   free(h_iters);
   free(source);
   err = clReleaseEvent(ev_kernel);          checkError(err, "clReleaseEvent(kernel)");
   err = clReleaseEvent(ev_read);            checkError(err, "clReleaseEvent(read)");
   err = clReleaseMemObject(d_iters);        checkError(err, "clReleaseMemObject");
   err = clReleaseKernel(kernel);            checkError(err, "clReleaseKernel");
   err = clReleaseProgram(program);          checkError(err, "clReleaseProgram");
   err = clReleaseCommandQueue(queue);       checkError(err, "clReleaseCommandQueue");
   err = clReleaseContext(context);          checkError(err, "clReleaseContext");

   return EXIT_SUCCESS;
}
