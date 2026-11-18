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
    int px = get_global_id(0);
    int py = get_global_id(1);

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
