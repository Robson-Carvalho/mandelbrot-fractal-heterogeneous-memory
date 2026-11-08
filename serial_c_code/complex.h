#ifndef COMPLEX_H
#define COMPLEX_H

typedef struct {
    float real;
    float imag;
} Complex_number;

float real_part(Complex_number number);
float imag_part(Complex_number number);
void print_complex(Complex_number number);

#endif
