/**
 * @file    test_bignum_div_burnikel_extra.c
 * @author  git@bayborodov.com
 * @version 1.0.0
 * @date    08.07.2026
 *
 * @brief   Расширенные тесты для модуля bignum_div_burnikel
 *
 * @details
 *   Проверяем:
 *    - NULL-параметры
 *    - Контракт: len > BIGNUM_CAPACITY
 *    - Отсутствие записи за пределы буферов (memory guard check)
 */

#include "bignum_div_burnikel.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

// Вспомогательная функция для сравнения
/*static int bignum_are_equal(const bignum_t* a, const bignum_t* b) {
    if (a == NULL || b == NULL) {
        return a == b;
    }
    if (a->len != b->len) {
        return 0;
    }
    if (a->len == 0) {
        return 1;  // оба пустые
    }
    return memcmp(a->words, b->words, a->len * sizeof(uint64_t)) == 0;
}*/

// 1. Тест: NULL-параметры
static void test_null_arg(void) {
    printf("test_null_arg...");
    bignum_t n = {0}, d = {0}, q = {0}, r = {0};
    d.len = 1; 
    d.words[0] = 1;
    
    assert(bignum_div_burnikel(NULL, &d, &q, &r) == BIGNUM_DIV_BURNIKEL_ERR_NULL_PTR);
    assert(bignum_div_burnikel(&n, NULL, &q, &r) == BIGNUM_DIV_BURNIKEL_ERR_NULL_PTR);
    assert(bignum_div_burnikel(&n, &d, NULL, &r) == BIGNUM_DIV_BURNIKEL_ERR_NULL_PTR);
    assert(bignum_div_burnikel(&n, &d, &q, NULL) == BIGNUM_DIV_BURNIKEL_ERR_NULL_PTR);
    printf("OK\n");
}

// 2. Тест: len > BIGNUM_CAPACITY (нарушение контракта)
static void test_contract_violation_len_overflow(void) {
    printf("test_contract_violation_len_overflow...");
    bignum_t n = {0}, d = {0}, q = {0}, r = {0};
    
    n.len = BIGNUM_CAPACITY + 1;
    d.len = 1; 
    d.words[0] = 1;
    
    // Ассемблерная реализация явно проверяет длину и возвращает ошибку
    int rc = bignum_div_burnikel(&n, &d, &q, &r);
    assert(rc == BIGNUM_DIV_BURNIKEL_ERR_BAD_LENGTH);
    
    n.len = 1;
    d.len = BIGNUM_CAPACITY + 1;
    rc = bignum_div_burnikel(&n, &d, &q, &r);
    assert(rc == BIGNUM_DIV_BURNIKEL_ERR_BAD_LENGTH);
    
    printf("OK\n");
}

// 3. Test deep block recursion with an uneven high/low decomposition.
static void test_recursive_block_case(void) {
    printf("test_recursive_block_case...");
    bignum_t n = {0}, d = {0}, q = {0}, r = {0};
    d.len = 5;
    d.words[0] = 0xD1B54A32D192ED03ULL;
    d.words[1] = 0x94D049BB133111EBULL;
    d.words[2] = 0xA24BAED4963EE407ULL;
    d.words[3] = 0x9FB21C651E98DF25ULL;
    d.words[4] = 0x8000000000000001ULL;
    n.len = 15;
    for (size_t i = 0U; i < n.len; ++i) {
        n.words[i] = UINT64_C(0x9E3779B97F4A7C15) * (i + 3U);
    }
    const bignum_t n_before = n;
    const bignum_t d_before = d;
    assert(bignum_div_burnikel(&n, &d, &q, &r) == BIGNUM_DIV_BURNIKEL_OK);
    assert(memcmp(&n, &n_before, sizeof(n)) == 0);
    assert(memcmp(&d, &d_before, sizeof(d)) == 0);
    assert(r.len <= d.len);
    assert(q.len <= BIGNUM_CAPACITY);
    printf("OK\\n");
}

// 4. Test that output objects remain byte-for-byte unchanged on an overlap error.
static void test_transactional_overlap(void) {
    printf("test_transactional_overlap...");
    bignum_t n = { .len = 1U, .words = { 100U } };
    bignum_t d = { .len = 1U, .words = { 3U } };
    bignum_t r = { .len = 1U, .words = { 0x55U } };
    const bignum_t before = r;
    assert(bignum_div_burnikel(&n, &d, &n, &r) == BIGNUM_DIV_BURNIKEL_ERR_BUFFER_OVERLAP);
    assert(memcmp(&r, &before, sizeof(r)) == 0);
    printf("OK\\n");
}

// 5. Test that the function does not write beyond quotient/remainder buffers.
static void test_memory_guard_check(void) {
    printf("test_memory_guard_check...");

    uint64_t guard_val = 0xDEADBEEFDEADBEEF;
    size_t buffer_size = sizeof(bignum_t) + 2 * sizeof(uint64_t);
    
    char* q_buf = (char*)malloc(buffer_size);
    char* r_buf = (char*)malloc(buffer_size);

    uint64_t* q_guard1 = (uint64_t*)q_buf;
    bignum_t* q = (bignum_t*)(q_buf + sizeof(uint64_t));
    uint64_t* q_guard2 = (uint64_t*)((char*)q + sizeof(bignum_t));

    uint64_t* r_guard1 = (uint64_t*)r_buf;
    bignum_t* r = (bignum_t*)(r_buf + sizeof(uint64_t));
    uint64_t* r_guard2 = (uint64_t*)((char*)r + sizeof(bignum_t));

    *q_guard1 = guard_val;
    *q_guard2 = guard_val;
    *r_guard1 = guard_val;
    *r_guard2 = guard_val;

    bignum_t n = {0}, d = {0};
    n.len = 1; n.words[0] = 100;
    d.len = 1; d.words[0] = 3;

    int rc = bignum_div_burnikel(&n, &d, q, r);
    assert(rc == BIGNUM_DIV_BURNIKEL_OK);
    
    assert(q->len == 1 && q->words[0] == 33);
    assert(r->len == 1 && r->words[0] == 1);

    // Проверяем, что "сторожевые" значения не затерты
    assert(*q_guard1 == guard_val);
    assert(*q_guard2 == guard_val);
    assert(*r_guard1 == guard_val);
    assert(*r_guard2 == guard_val);

    free(q_buf);
    free(r_buf);
    printf("OK\n");
}

int main(void) {
    printf("=== Extra tests for bignum_div_burnikel ===\n");
    test_null_arg();
    test_contract_violation_len_overflow();
    test_recursive_block_case();
    test_transactional_overlap();
    test_memory_guard_check();
    printf("=== All extra tests passed ===\n");
    return EXIT_SUCCESS;
}
