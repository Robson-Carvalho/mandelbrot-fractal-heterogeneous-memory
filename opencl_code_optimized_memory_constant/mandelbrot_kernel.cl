// Kernel do Mandelbrot: cada work-item calcula UM pixel.
//
//   get_global_id(0) -> px (coluna)
//   get_global_id(1) -> py (linha)
//
// OTIMIZACOES desta versao (sobre a versao "warp", que continua incluida):
//   1. LUT em memoria constante: o host pre-calcula lut[0..max_iter] (iteracao ->
//      tom de cinza, uchar) e envia uma vez como __constant. O kernel so faz lut[iter]
//      (cache de constantes, broadcast quando o warp le o mesmo indice).
//   2. Escrita de 1 byte (uchar) por pixel em vez de 2 (ushort): metade do trafego de
//      escrita na VRAM e metade do buffer lido de volta pelo PCIe.

#pragma OPENCL FP_CONTRACT OFF

// Laco de escape (mesma conta do check_mandelbrot() do serial). Retorna a contagem de iteracoes.
static int escape_iter(int px, int py, int width, int height,
                       float minX, float maxX, float minY, float maxY, int max_iter)
{
    // Pixel -> numero complexo c (mesma conta do codigo serial)
    float cr = minX + (maxX - minX) * (px / (float)width);
    float ci = maxY - (maxY - minY) * (py / (float)height);

    float fr = 0.0f, fi = 0.0f;
    int iter = max_iter;

    for (int i = 0; i < max_iter; i++) {
        float fr2 = fr * fr;
        float fi2 = fi * fi;
        fi = 2.0f * fr * fi + ci;
        fr = fr2 - fi2 + cr;

        if (fr * fr + fi * fi > 4.0f) {
            iter = i + 1;
            break;
        }
    }
    return iter;
}

// Kernel medido: grava o tom de cinza (1 byte) consultando a LUT.
// ATENCAO: manter este kernel PRIMEIRO no arquivo (o host le os registradores do 1o "Used" do ptxas).
__kernel void mandelbrot(__global uchar *pixels,
                         __constant uchar *lut,
                         const int width,
                         const int height,
                         const float minX,
                         const float maxX,
                         const float minY,
                         const float maxY,
                         const int max_iter)
{
    // OTIMIZACAO (divergencia de warp): remapeia qual pixel cada work-item
    // calcula. Cada warp (32 work-items consecutivos em id linear) passa a cobrir
    // um bloco compacto 8x4 de pixels vizinhos, que tendem a ter contagens de
    // iteracao parecidas -> menos lanes ociosas esperando o mais lento do warp.
    // Requer local_x multiplo de 8 e local_y multiplo de 4; senao usa o mapa padrao.
    int lw = get_local_size(0), lh = get_local_size(1);
    int lx = get_local_id(0),   ly = get_local_id(1);
    if ((lw % 8) == 0 && (lh % 4) == 0) {
        int lid   = ly * lw + lx;
        int warp  = lid / 32;
        int lane  = lid % 32;
        int bpr   = lw / 8;                 // blocos 8x4 por linha da tile
        lx = (warp % bpr) * 8 + (lane % 8);
        ly = (warp / bpr) * 4 + (lane / 8);
    }
    int px = get_group_id(0) * lw + lx;
    int py = get_group_id(1) * lh + ly;

    if (px >= width || py >= height) return;

    int iter = escape_iter(px, py, width, height, minX, maxX, minY, maxY, max_iter);

    pixels[(size_t)py * width + px] = lut[iter];
}

// Kernel auxiliar, NAO medido (roda uma vez fora do T_total, como o aquecimento):
// soma as iteracoes de cada linha, so para o host calcular TOTAL_ITERATIONS e GFLOPS,
// ja que a saida de 1 byte nao guarda mais a contagem de iteracoes.
__kernel void mandelbrot_count(__global uint *row_sums,
                               const int width,
                               const int height,
                               const float minX,
                               const float maxX,
                               const float minY,
                               const float maxY,
                               const int max_iter)
{
    int px = get_global_id(0);
    int py = get_global_id(1);
    if (px >= width || py >= height) return;

    int iter = escape_iter(px, py, width, height, minX, maxX, minY, maxY, max_iter);
    atomic_add(&row_sums[py], (uint)iter);
}
