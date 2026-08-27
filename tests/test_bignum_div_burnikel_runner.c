/**
 * @file test_bignum_div_burnikel_runner.c
 * @brief Minimal distribution smoke test for bignum_div_burnikel.
 */
#include "bignum_div_burnikel.h"
#include <stdint.h>
#include <stdio.h>

int main(void)
{
    bignum_t dividend = {0};
    bignum_t divisor = {0};
    bignum_t quotient = {0};
    bignum_t remainder = {0};

    dividend.words[0] = UINT64_C(100);
    dividend.len = 1U;
    divisor.words[0] = UINT64_C(7);
    divisor.len = 1U;

    if (bignum_div_burnikel(&dividend, &divisor, &quotient, &remainder) !=
        BIGNUM_DIV_BURNIKEL_OK) {
        fputs("distribution smoke test: division failed\n", stderr);
        return 1;
    }
    if (quotient.len != 1U || quotient.words[0] != UINT64_C(14) ||
        remainder.len != 1U || remainder.words[0] != UINT64_C(2)) {
        fputs("distribution smoke test: result mismatch\n", stderr);
        return 1;
    }
    if (dividend.words[0] != UINT64_C(100) || dividend.len != 1U ||
        divisor.words[0] != UINT64_C(7) || divisor.len != 1U) {
        fputs("distribution smoke test: input mutation\n", stderr);
        return 1;
    }
    return 0;
}
