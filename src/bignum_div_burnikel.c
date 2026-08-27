/**
 * @file bignum_div_burnikel.c
 * @brief C11 reference implementation of block-recursive Burnikel--Ziegler division.
 * @details The implementation validates all inputs before publication, recursively
 * divides high and low word blocks, and uses a bounded binary-division base case.
 * It performs no allocation and preserves both output objects on errors.
 */
#include "bignum_div_burnikel.h"
#include <stddef.h>
#include <stdint.h>
#include <string.h>

static void normalize_words(uint64_t *words, size_t *length)
{
    while (*length != 0U && words[*length - 1U] == 0U) --*length;
}

static int compare_words(const uint64_t *left, size_t left_len,
                         const uint64_t *right, size_t right_len)
{
    if (left_len != right_len) return left_len < right_len ? -1 : 1;
    while (left_len != 0U) {
        --left_len;
        if (left[left_len] != right[left_len]) {
            return left[left_len] < right[left_len] ? -1 : 1;
        }
    }
    return 0;
}

static uint64_t get_bit(const uint64_t *words, size_t length, size_t bit_index)
{
    const size_t word = bit_index / 64U;
    return word < length ? (words[word] >> (bit_index % 64U)) & 1U : 0U;
}

static void shift_insert(uint64_t *words, size_t *length, uint64_t bit)
{
    uint64_t carry = bit & 1U;
    for (size_t i = 0U; i < BIGNUM_CAPACITY; ++i) {
        const uint64_t next = words[i] >> 63U;
        words[i] = (words[i] << 1U) | carry;
        carry = next;
    }
    *length = BIGNUM_CAPACITY;
    normalize_words(words, length);
}

static void subtract_words(uint64_t *left, size_t *left_len,
                           const uint64_t *right, size_t right_len)
{
    uint64_t borrow = 0U;
    for (size_t i = 0U; i < BIGNUM_CAPACITY; ++i) {
        const uint64_t rhs = (i < right_len ? right[i] : 0U) + borrow;
        const uint64_t old = left[i];
        left[i] = old - rhs;
        borrow = old < rhs ? 1U : 0U;
    }
    normalize_words(left, left_len);
}

/* Bounded base case: binary long division over one fixed-capacity block. */
static void divide_base(const uint64_t *number, size_t number_len,
                        const uint64_t *divisor, size_t divisor_len,
                        uint64_t *quotient, size_t *quotient_len,
                        uint64_t *remainder, size_t *remainder_len)
{
    size_t q_len = 0U;
    size_t r_len = 0U;
    memset(quotient, 0, BIGNUM_CAPACITY * sizeof(*quotient));
    memset(remainder, 0, BIGNUM_CAPACITY * sizeof(*remainder));
    for (size_t remaining = number_len * 64U; remaining != 0U; --remaining) {
        const size_t bit = remaining - 1U;
        shift_insert(remainder, &r_len, get_bit(number, number_len, bit));
        if (compare_words(remainder, r_len, divisor, divisor_len) >= 0) {
            subtract_words(remainder, &r_len, divisor, divisor_len);
            quotient[bit / 64U] |= UINT64_C(1) << (bit % 64U);
            if (q_len < bit / 64U + 1U) q_len = bit / 64U + 1U;
        }
    }
    normalize_words(quotient, &q_len);
    *quotient_len = q_len;
    *remainder_len = r_len;
}

/*
 * Burnikel--Ziegler block recursion. The high block is divided first; its
 * remainder is concatenated with the low block and divided recursively.
 * Every recursive subproblem is bounded by BIGNUM_CAPACITY words.
 */
static void divide_blocks(const uint64_t *number, size_t number_len,
                          const uint64_t *divisor, size_t divisor_len,
                          uint64_t *quotient, size_t *quotient_len,
                          uint64_t *remainder, size_t *remainder_len)
{
    if (number_len <= divisor_len + 1U || number_len <= 2U ||
        number_len <= divisor_len * 2U) {
        divide_base(number, number_len, divisor, divisor_len,
                    quotient, quotient_len, remainder, remainder_len);
        return;
    }

    size_t low_len = number_len / 2U;
    if (low_len < divisor_len) low_len = divisor_len;
    if (low_len >= number_len) low_len = number_len - 1U;
    const size_t high_len = number_len - low_len;
    uint64_t high_q[BIGNUM_CAPACITY] = {0};
    uint64_t high_r[BIGNUM_CAPACITY] = {0};
    size_t high_q_len = 0U;
    size_t high_r_len = 0U;
    divide_blocks(number + low_len, high_len, divisor, divisor_len,
                  high_q, &high_q_len, high_r, &high_r_len);

    uint64_t combined[BIGNUM_CAPACITY] = {0};
    uint64_t low_q[BIGNUM_CAPACITY] = {0};
    uint64_t low_r[BIGNUM_CAPACITY] = {0};
    size_t combined_len = low_len + high_r_len;
    if (combined_len > BIGNUM_CAPACITY) combined_len = BIGNUM_CAPACITY;
    for (size_t i = 0U; i < low_len && i < BIGNUM_CAPACITY; ++i) combined[i] = number[i];
    for (size_t i = 0U; i < high_r_len && low_len + i < BIGNUM_CAPACITY; ++i) {
        combined[low_len + i] = high_r[i];
    }
    normalize_words(combined, &combined_len);
    size_t low_q_len = 0U;
    size_t low_r_len = 0U;
    divide_blocks(combined, combined_len, divisor, divisor_len,
                  low_q, &low_q_len, low_r, &low_r_len);

    memset(quotient, 0, BIGNUM_CAPACITY * sizeof(*quotient));
    for (size_t i = 0U; i < high_q_len && low_len + i < BIGNUM_CAPACITY; ++i) {
        quotient[low_len + i] = high_q[i];
    }
    for (size_t i = 0U; i < low_q_len && i < BIGNUM_CAPACITY; ++i) quotient[i] = low_q[i];
    *quotient_len = BIGNUM_CAPACITY;
    normalize_words(quotient, quotient_len);
    memcpy(remainder, low_r, BIGNUM_CAPACITY * sizeof(*remainder));
    *remainder_len = low_r_len;
}

bignum_div_burnikel_status_t bignum_div_burnikel(
    const bignum_t *dividend, const bignum_t *divisor,
    bignum_t *quotient, bignum_t *remainder)
{
    if (dividend == NULL || divisor == NULL || quotient == NULL || remainder == NULL) {
        return BIGNUM_DIV_BURNIKEL_ERR_NULL_PTR;
    }
    if (quotient == remainder || quotient == dividend || quotient == divisor ||
        remainder == dividend || remainder == divisor) {
        return BIGNUM_DIV_BURNIKEL_ERR_BUFFER_OVERLAP;
    }
    if (dividend->len > BIGNUM_CAPACITY || divisor->len > BIGNUM_CAPACITY) {
        return BIGNUM_DIV_BURNIKEL_ERR_BAD_LENGTH;
    }
    bignum_t q = {0};
    bignum_t r = {0};
    uint64_t n[BIGNUM_CAPACITY] = {0};
    uint64_t d[BIGNUM_CAPACITY] = {0};
    size_t n_len = dividend->len;
    size_t d_len = divisor->len;
    memcpy(n, dividend->words, sizeof(n));
    memcpy(d, divisor->words, sizeof(d));
    normalize_words(n, &n_len);
    normalize_words(d, &d_len);
    if (d_len == 0U) return BIGNUM_DIV_BURNIKEL_ERR_DIVISION_BY_ZERO;
    divide_blocks(n, n_len, d, d_len, q.words, &q.len, r.words, &r.len);
    *quotient = q;
    *remainder = r;
    return BIGNUM_DIV_BURNIKEL_OK;
}
