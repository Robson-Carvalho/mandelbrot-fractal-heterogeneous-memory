#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <time.h>
#include "complex.h"
#include "mandelbrot.h"

int mandelbrot(int px, int py, int width, int height, float minX, float maxX, float minY, float maxY, int max_iter) {
    Complex_number c;

    float unidades_largura = maxX - minX; // Quantidade de unidades de largura do plano
    float unidades_altura = maxY - minY; // Quantidade de unidades de altura do plano

    float proporcao_x = (px / (float)width); // De 0 a 1
    float proporcao_y = (py / (float)height); // De 0 a 1

    // Multiplica a proporção pelo tamanho total do plano matemático
    float deslocamento_x = unidades_largura * proporcao_x; 
    float deslocamento_y = unidades_altura * proporcao_y;

    // Soma o ponto de início (minX) para o X, mas subtrai do topo (maxY) para o Y
    float enquadramento_eixo_x = minX + deslocamento_x;
    float enquadramento_eixo_y = maxY - deslocamento_y;

    // Número complexo que será calculado
    c = (Complex_number){enquadramento_eixo_x, enquadramento_eixo_y};

    Mandelbrot_check_return result = check_mandelbrot(c, max_iter);
    
    int iter = result.iterations_to_scape;

    return iter;
}

int main(int argc, char *argv[]) {
    if (argc < 9) {
        printf("Uso: %s <width> <height> <minX> <maxX> <minY> <maxY> <max_iter> <output_filename>\n", argv[0]);
        return 1;
    }

    int width = atoi(argv[1]);
    printf("width: %d\n", width);
    int height = atoi(argv[2]);
    printf("height: %d\n", height);
    float minX = (float)atof(argv[3]);
    printf("minX: %f\n", minX);
    float maxX = (float)atof(argv[4]);
    printf("maxX: %f\n", maxX);
    float minY = (float)atof(argv[5]);
    printf("minY: %f\n", minY);
    float maxY = (float)atof(argv[6]);
    printf("maxY: %f\n", maxY);
    int max_iter = atoi(argv[7]);
    printf("max_iter: %d\n", max_iter);
    char *filename = argv[8];

    FILE *file_image = fopen(filename, "wb");
    if (!file_image) {
        perror("Erro ao abrir arquivo");
        return 1;
    }
    printf("Salvando imagem em: %s\n", filename);

    fprintf(file_image, "P6\n%d %d\n255\n", width, height);

    // --- Medição interna de tempo (clock_gettime) ---
    struct timespec t_start, t_end;
    clock_gettime(CLOCK_MONOTONIC, &t_start);

    unsigned long long total_iterations = 0;

    for (int py = 0; py < height; py++) {

         for (int px = 0; px < width; px++) {

            int iter = mandelbrot(px, py, width, height, minX, maxX, minY, maxY, max_iter);
            total_iterations += (unsigned long long)iter;
           
            unsigned char r, g, b;

            //  dentro do limite (faz parte do conjunto)
            if (iter == max_iter) { 
                r = g = b = 0;
            } 
            // fora do limite (não faz parte do conjunto)
            else {
                unsigned char tom = (unsigned char)(sinf(0.1f * iter) * 127.5f + 127.5f);
                r = g = b = tom;
            }       

            fputc(r, file_image);
            fputc(g, file_image);
            fputc(b, file_image);
         }
    }

    clock_gettime(CLOCK_MONOTONIC, &t_end);
    double elapsed = (t_end.tv_sec - t_start.tv_sec) +
                     (t_end.tv_nsec - t_start.tv_nsec) / 1e9;
    printf("Tempo de processamento (clock_gettime): %.6f segundos\n", elapsed);
    printf("Total de iteracoes somadas: %llu\n", total_iterations);
    // -------------------------------------------------

    fclose(file_image);
    return 0;
}
