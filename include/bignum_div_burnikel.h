/**
 * @file bignum_div_burnikel.h
 * @brief Public quotient/remainder API for fixed-capacity unsigned bignums.
 * @details The operation uses a block-recursive Burnikel--Ziegler decomposition.
 * Inputs are borrowed, outputs are caller-owned, and both outputs remain
 * unchanged on validation or arithmetic failure. Calls are reentrant when
 * concurrently used objects do not overlap.
 */
#ifndef BIGNUM_DIV_BURNIKEL_H
#define BIGNUM_DIV_BURNIKEL_H

#include <bignum.h>
#include <stddef.h>
#include <stdint.h>

#ifndef BIGNUM_CAPACITY
#error "bignum.h must define BIGNUM_CAPACITY"
#endif

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Reports validation and arithmetic outcomes of bignum_div_burnikel.
 * @details Success commits normalized quotient and remainder. Every error
 * leaves both output objects unchanged.
 */
typedef enum bignum_div_burnikel_status {
    BIGNUM_DIV_BURNIKEL_OK = 0, /**< Division completed successfully. */
    BIGNUM_DIV_BURNIKEL_ERR_NULL_PTR = -1, /**< A required pointer was NULL. */
    BIGNUM_DIV_BURNIKEL_ERR_DIVISION_BY_ZERO = -2, /**< Divisor represents zero. */
    BIGNUM_DIV_BURNIKEL_ERR_BUFFER_OVERLAP = -3, /**< Inputs and outputs overlap. */
    BIGNUM_DIV_BURNIKEL_ERR_BAD_LENGTH = -4, /**< An input length exceeds capacity. */
    BIGNUM_DIV_BURNIKEL_ERR_OVERFLOW = -5 /**< A result cannot fit capacity. */
} bignum_div_burnikel_status_t;

/**
 * @brief Divides one unsigned bignum by another.
 * @details Computes `dividend = quotient * divisor + remainder` with
 * `remainder < divisor`. Inputs are normalized privately, and the normalized
 * outputs are published only after successful completion. No allocation is
 * performed and no pointer is retained after return.
 * @param[in] dividend Borrowed dividend; never modified.
 * @param[in] divisor Borrowed non-zero divisor; never modified.
 * @param[out] quotient Caller-owned writable output distinct from all inputs
 * and from remainder; unchanged on failure.
 * @param[out] remainder Caller-owned writable output distinct from all inputs
 * and from quotient; unchanged on failure.
 * @return A named bignum_div_burnikel_status_t value.
 * @pre All non-NULL objects point to valid storage. Input lengths are at most
 * BIGNUM_CAPACITY. Outputs do not overlap inputs or one another.
 * @post On success, both outputs are normalized and satisfy the division
 * identity. On failure, both outputs retain their prior byte representation.
 * @warning Concurrent calls are safe only when their bignum objects do not
 * overlap. The function does not release caller-owned storage.
 * @complexity The block recursion uses O(W log W) block operations plus the
 * bounded base-case work for fixed capacity W.
 */
bignum_div_burnikel_status_t bignum_div_burnikel(
    const bignum_t *dividend,
    const bignum_t *divisor,
    bignum_t *quotient,
    bignum_t *remainder);

#ifdef __cplusplus
}
#endif

#endif /* BIGNUM_DIV_BURNIKEL_H */
