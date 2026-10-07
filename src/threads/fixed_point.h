#ifndef THREADS_FIXED_POINT_H
#define THREADS_FIXED_POINT_H

#include <stdint.h>

/* 17.14 Fixed-Point Representation
   1 bit sign, 17 bits integer, 14 bits fraction.
   f = 2^14 = 16384 */
#define FP_F (1 << 14)

/* Convert integer n to fixed point */
#define FP_INT_TO_FP(n) ((int)((n) * (FP_F)))

/* Convert fixed point x to integer (rounding toward zero) */
#define FP_TO_INT_ZERO(x) ((int)((x) / (FP_F)))

/* Convert fixed point x to integer (rounding to nearest) */
#define FP_TO_INT_NEAR(x) ((int)((x) >= 0 ? (((x) + ((FP_F) / 2)) / (FP_F)) \
                                          : (((x) - ((FP_F) / 2)) / (FP_F))))

/* Add two fixed-point numbers */
#define FP_ADD(x, y) ((x) + (y))

/* Subtract two fixed-point numbers */
#define FP_SUB(x, y) ((x) - (y))

/* Add an integer n to fixed-point x */
#define FP_ADD_INT(x, n) ((x) + ((n) * (FP_F)))

/* Subtract an integer n from fixed-point x */
#define FP_SUB_INT(x, n) ((x) - ((n) * (FP_F)))

/* Multiply two fixed-point numbers */
#define FP_MULT(x, y) ((int)(((int64_t)(x)) * (y) / (FP_F)))

/* Multiply fixed-point x by an integer n */
#define FP_MULT_INT(x, n) ((x) * (n))

/* Divide fixed-point x by fixed-point y */
#define FP_DIV(x, y) ((int)(((int64_t)(x)) * (FP_F) / (y)))

/* Divide fixed-point x by an integer n */
#define FP_DIV_INT(x, n) ((x) / (n))

#endif /* threads/fixed_point.h */