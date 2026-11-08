#include <stdio.h>
#include "complex.h"

float real_part(Complex_number number){
	float real = number.real;
	return real;
}

float imag_part(Complex_number number){
	float imag = number.imag;
	return imag;
}

void print_complex(Complex_number number){
	printf("Complex Number: %.2f + j%.2f\n", number.real, number.imag);
	return;
}
