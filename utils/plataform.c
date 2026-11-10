#include <stdio.h>
#include <stdlib.h>

#ifdef __APPLE__
#include <OpenCL/opencl.h>
#else
#include <CL/cl.h>
#endif

/* Extensões específicas da NVIDIA (opcional para leitura de Compute Capability) */
#ifndef CL_DEVICE_COMPUTE_CAPABILITY_MAJOR_NV
#define CL_DEVICE_COMPUTE_CAPABILITY_MAJOR_NV 0x4000
#define CL_DEVICE_COMPUTE_CAPABILITY_MINOR_NV 0x4001
#endif

int main() {
    cl_uint num_platforms = 0;
    cl_int err = clGetPlatformIDs(0, NULL, &num_platforms);

    if (err != CL_SUCCESS || num_platforms == 0) {
        fprintf(stderr, "Erro: Nenhuma plataforma OpenCL encontrada.\n");
        return 1;
    }

    cl_platform_id *platforms = (cl_platform_id *)malloc(sizeof(cl_platform_id) * num_platforms);
    clGetPlatformIDs(num_platforms, platforms, NULL);

    for (cl_uint i = 0; i < num_platforms; i++) {
        cl_uint num_devices = 0;
        clGetDeviceIDs(platforms[i], CL_DEVICE_TYPE_ALL, 0, NULL, &num_devices);
        if (num_devices == 0) continue;

        cl_device_id *devices = (cl_device_id *)malloc(sizeof(cl_device_id) * num_devices);
        clGetDeviceIDs(platforms[i], CL_DEVICE_TYPE_ALL, num_devices, devices, NULL);

        for (cl_uint j = 0; j < num_devices; j++) {
            char name[256];
            cl_uint compute_units = 0;
            cl_uint max_work_item_dims = 0;
            size_t max_work_group_size = 0;
            size_t max_work_item_sizes[3] = {0, 0, 0};
            cl_uint cc_major = 0, cc_minor = 0;

            clGetDeviceInfo(devices[j], CL_DEVICE_NAME, sizeof(name), name, NULL);
            clGetDeviceInfo(devices[j], CL_DEVICE_MAX_COMPUTE_UNITS, sizeof(compute_units), &compute_units, NULL);
            
            /* Consulta limites de dimensões de trabalho */
            clGetDeviceInfo(devices[j], CL_DEVICE_MAX_WORK_ITEM_DIMENSIONS, sizeof(max_work_item_dims), &max_work_item_dims, NULL);
            clGetDeviceInfo(devices[j], CL_DEVICE_MAX_WORK_ITEM_SIZES, sizeof(max_work_item_sizes), max_work_item_sizes, NULL);
            clGetDeviceInfo(devices[j], CL_DEVICE_MAX_WORK_GROUP_SIZE, sizeof(max_work_group_size), &max_work_group_size, NULL);

            /* Tenta obter a Compute Capability via extensão NVIDIA */
            clGetDeviceInfo(devices[j], CL_DEVICE_COMPUTE_CAPABILITY_MAJOR_NV, sizeof(cc_major), &cc_major, NULL);
            clGetDeviceInfo(devices[j], CL_DEVICE_COMPUTE_CAPABILITY_MINOR_NV, sizeof(cc_minor), &cc_minor, NULL);

            printf("==================================================\n");
            printf("Dispositivo: %s\n", name);
            printf("Compute Units (SMs): %u\n", compute_units);

            if (cc_major > 0) {
                printf("NVIDIA Compute Capability: %u.%u\n", cc_major, cc_minor);
                
                /* Arquitetura Ampere (CC 8.6 / GA107 - RTX 3050 Laptop): 128 FP32 CUDA Cores por SM */
                cl_uint cores_per_sm = (cc_major == 8) ? 128 : 64; // Estimativa genérica
                printf("CUDA Cores por Unidade (SM): %u\n", cores_per_sm);
                printf("Total de CUDA Cores estimado: %u\n", compute_units * cores_per_sm);
            }

            printf("\n--- Dimensões Máximas (Work-Items / Work-Group) ---\n");
            printf("Dimensões Máximas Suportadas: %uD\n", max_work_item_dims);
            printf("Tamanho Máximo do Bloco (Work-Group Size): %zu\n", max_work_group_size);
            printf("Tamanho Máximo por Dimensão (X, Y, Z):\n");
            printf("  -> X (Dim [0]): %zu\n", max_work_item_sizes[0]);
            printf("  -> Y (Dim [1]): %zu\n", max_work_item_sizes[1]);
            printf("  -> Z (Dim [2]): %zu\n", max_work_item_sizes[2]);
            printf("==================================================\n");
        }
        free(devices);
    }
    free(platforms);
    return 0;
}