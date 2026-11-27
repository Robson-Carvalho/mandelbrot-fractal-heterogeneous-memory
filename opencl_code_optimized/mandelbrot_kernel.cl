// Kernel do Mandelbrot: cada work-item calcula UM pixel.
//
//   get_global_id(0) -> px (coluna)
//   get_global_id(1) -> py (linha)

#pragma OPENCL FP_CONTRACT OFF

__kernel void mandelbrot(__global ushort *iters,
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

    // Pixel -> número complexo c (mesma conta do código serial)
    float cr = minX + (maxX - minX) * (px / (float)width);
    float ci = maxY - (maxY - minY) * (py / (float)height);

    // Mesmo laço do check_mandelbrot() do código serial
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

    iters[(size_t)py * width + px] = (ushort)iter;
}
