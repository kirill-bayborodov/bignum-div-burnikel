# Burnikel--Ziegler Design Notes

## Scope

This note defines the block-recursive quotient/remainder strategy required for `bignum-div-burnikel`. The C11 implementation is the correctness reference and baseline. The production YASM implementation must provide the same observable API while keeping its own workspace and control flow.

## Representation

A `bignum_t` contains at most 32 little-endian 64-bit limbs. A block is a contiguous sequence of limbs interpreted in base `B = 2^(64*n)`, where `n` is the current recursion block width. Inputs are normalized privately before recursion. No input or output object is modified until the complete operation succeeds.

## D2/1 primitive

`D2/1` divides a two-block value by a one-block value. For a block width `n`, write the dividend as `[u1, u0]` and the divisor as `v`, with `0 < v <= B`. The primitive recursively divides the high block and then combines its remainder with the low block:

1. Divide `u1` by `v`, producing high quotient `q1` and remainder `r1`.
2. Form `[r1, u0]` without truncating significant limbs.
3. Divide the combined value by `v`, producing `q0` and final remainder `r0`.
4. Return `q = [q1, q0]` and `r0`.

The base case uses bounded binary long division over the current block. The recursive case must strictly reduce the operand block width; a `2n`-by-`n` subproblem is therefore dispatched to the bounded base primitive or to a smaller D2/1 instance.

## D3/2 primitive

`D3/2` divides a three-block value `[u2, u1, u0]` by a two-block divisor `[v1, v0]`. It first obtains the trial quotient from `D2/1([u2, u1], v1)`, then corrects the trial quotient by multiplying it by `v0` and comparing the result with the intermediate remainder combined with `u0`:

1. Compute `(qhat, c) = D2/1([u2, u1], v1)`.
2. Form `r = [c, u0] - qhat*v0` using bounded block arithmetic.
3. While `r` is negative, decrement `qhat` and add the full divisor `[v1, v0]` to `r`.
4. Return `qhat` and the normalized non-negative remainder `r`.

The correction loop is bounded by the trial-quotient invariant. All intermediate multiplication, subtraction and addition operations use explicit carry/borrow propagation and capacity checks.

## Public operation

The top-level operation selects a power-of-two block width for the normalized divisor, pads private operands to that width, and invokes the D2/1/D3/2 recursion as required by the operand ratio. Inputs are borrowed. `quotient` and `remainder` are caller-owned outputs and remain byte-for-byte unchanged on every error path.

## ASM requirements

The YASM implementation must contain independent D2/1 and D3/2 routines or equivalent local labels with explicit block-width and workspace invariants. It must preserve System V AMD64 callee-saved registers, validate pointer/length/overlap conditions, avoid writes to public outputs before success, and expose only `bignum_div_burnikel` as the public entry point. The C11 source must not be linked as an ASM fallback.

For the fixed 32-limb representation, the private workspace must provide separate storage for normalized dividend blocks, normalized divisor blocks, trial quotient blocks, partial remainder blocks and correction products. Every recursive call must receive a smaller block width or dispatch to the bounded base case; a call that preserves the same `(number_len, divisor_len)` pair is a correctness defect. The final ASM acceptance gate requires differential agreement with C11 across zero, one-limb, uneven-block, near-capacity, correction-loop and randomized cases, plus guard-byte and transactional-output checks.

## References

1. Christoph Burnikel and Joachim Ziegler, *Fast Recursive Division*: https://pure.mpg.de/rest/items/item_1819444_4/component/file_2599480/content
2. GNU MP, *Divide and Conquer Division*: https://gmplib.org/manual/Divide-and-Conquer-Division.html
3. Paul Zimmermann, *Efficient Algorithms on Numbers, Polynomials, and Series*: https://algo.inria.fr/seminars/sem99-00/zimmermann.html

## Planned YASM register and workspace map

The entry point keeps the four public objects in callee-saved registers after validation: `r14` for the dividend, `r15` for the divisor, `r12` for the quotient and `r13` for the remainder. The private stack frame is divided into non-overlapping regions for normalized dividend limbs, normalized divisor limbs, quotient limbs, partial remainder limbs and correction-product limbs. A recursion frame records the current block width, the number of active blocks and the output offsets; no public output address is used as temporary storage.

The D2/1 routine is planned as a bounded block operation over two adjacent dividend blocks and one divisor block. Its return convention is a quotient block pointer/length and a remainder block pointer/length in private workspace. The D3/2 routine consumes two divisor blocks, obtains a trial quotient from D2/1, computes the low-block correction product with `mul`, and performs a bounded decrement/add-back loop before returning the normalized remainder. The top-level dispatcher selects the base case for one-limb divisors and reduces the block width for every recursive call.

The implementation must be validated in stages. First, each private primitive will be exercised through the public API with inputs that force one-limb, two-block, three-block, uneven-block and near-capacity paths. Second, the public outputs will be compared byte-for-byte against the C11 reference. Third, the final benchmark matrices will be rerun only after the primitive differential suite is green.

This map was the implementation checkpoint for the formal ASM primitives. The source now contains and executes the recursive D2/1 and D3/2 paths; their acceptance evidence is recorded in `docs/QUALITY_GATES_REVIEW.md`.
