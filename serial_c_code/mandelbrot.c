#include <stdio.h>
#include "complex.h"
#include "mandelbrot.h"

Mandelbrot_check_return check_mandelbrot(Complex_number c, int max_iter){
    float fr = 0.0f, fi = 0.0f;

    for(int i = 0; i < max_iter; i++){
        // (fr + fi*i)² + c  →  (fr²-fi²) + (2·fr·fi)·i + c
        float fr2 = fr * fr;
        float fi2 = fi * fi;
        fi = 2.0f * fr * fi + c.imag;
        fr = fr2 - fi2 + c.real;

        if (fr * fr + fi * fi > 4.0f) {
            Complex_number fval = {fr, fi};
            return (Mandelbrot_check_return){0, fval, i+1};
        }
    }

    Complex_number fval = {fr, fi};
    return (Mandelbrot_check_return){1, fval, max_iter};
}
