#include <stdio.h>
#include <stdlib.h>
#ifdef __APPLE__
#else
#include <CL/cl.h>
#endif

int main() {
    cl_uint num_platforms = 0;
    cl_int err;

    err = clGetPlatformIDs(0, NULL, &num_platforms);
    if (err != CL_SUCCESS || num_platforms == 0) {
        fprintf(stderr, "Erro: Nenhuma plataforma OpenCL encontrada ou falha no acesso.\n");
        return 1;
    }

    printf("=== Plataformas OpenCL Encontradas: %u ===\n", num_platforms);

    cl_platform_id *platforms = (cl_platform_id *)malloc(sizeof(cl_platform_id) * num_platforms);
    clGetPlatformIDs(num_platforms, platforms, NULL);

    for (cl_uint i = 0; i < num_platforms; i++) {
        char buffer[1024];

        clGetPlatformInfo(platforms[i], CL_PLATFORM_NAME, sizeof(buffer), buffer, NULL);
        printf("\n[%u] Plataforma: %s\n", i, buffer);

        clGetPlatformInfo(platforms[i], CL_PLATFORM_VENDOR, sizeof(buffer), buffer, NULL);
        printf("    Fornecedor: %s\n", buffer);

        clGetPlatformInfo(platforms[i], CL_PLATFORM_VERSION, sizeof(buffer), buffer, NULL);
        printf("    Versão:     %s\n", buffer);


        cl_uint num_devices = 0;
        err = clGetDeviceIDs(platforms[i], CL_DEVICE_TYPE_ALL, 0, NULL, &num_devices);
        
        if (err != CL_SUCCESS || num_devices == 0) {
            printf("    -> Nenhum dispositivo encontrado para esta plataforma.\n");
            continue;
        }

        cl_device_id *devices = (cl_device_id *)malloc(sizeof(cl_device_id) * num_devices);
        clGetDeviceIDs(platforms[i], CL_DEVICE_TYPE_ALL, num_devices, devices, NULL);

        printf("    Dispositivos associados (%u):\n", num_devices);
        for (cl_uint j = 0; j < num_devices; j++) {
            clGetDeviceInfo(devices[j], CL_DEVICE_NAME, sizeof(buffer), buffer, NULL);
            printf("        -> [%u] Dispositivo: %s\n", j, buffer);

            cl_uint compute_units;
            clGetDeviceInfo(devices[j], CL_DEVICE_MAX_COMPUTE_UNITS, sizeof(compute_units), &compute_units, NULL);
            printf("            Unidades de Computação: %u\n", compute_units);
        }

        free(devices);
    }

    free(platforms);
    return 0;
}