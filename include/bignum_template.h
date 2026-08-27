/**
 * @file    bignum_template.h
 * @author  git@bayborodov.com
 * @version 1.0.0
 * @date    07.11.2025
 *
 * @brief   Публичный API для логического сдвига bignum_t влево.
 *
 * @details
 *   Выполняет in-place (на месте) логический сдвиг большого числа на
 *   заданное количество бит. Нормализация (удаление ведущих нулей)
 *   выполняется автоматически.
 *
 *   Функция является потокобезопасной при условии, что разные потоки
 *   работают с разными, не пересекающимися объектами `bignum_t`.
 *
 *   **Алгоритм:**
 *    1. Проверка аргументов.
 *    2. Нулевой сдвиг — быстрый выход.
 *    3. Разбиение `template_amount` на сдвиг по словам (`word_template`) и битам (`bit_template`).
 *    4. Проверка на переполнение (при выходе старшего бита за BIGNUM_CAPACITY).
 *    5. Сдвиг по словам, затем побитовый сдвиг с переносами между словами.
 *    6. Обновление `len` и нормализация результата.
 *
 * @see     bignum.h
 * @since   1.0.0
 *
 * @history
 *   - rev. 1 (02.08.2025): Первоначальное создание API.
 *   - rev. 2 (02.08.2025): API улучшен по результатам аудита: добавлены
 *                         макросы версий, `restrict`, `size_t`, улучшены
 *                         Doxygen-комментарии и include guards.
 *   - rev. 3 (07.11.2025): Removed version control functions.
 */

#ifndef BIGNUM_TEMPLATE_H
#define BIGNUM_TEMPLATE_H

#include <bignum.h>
#include <stddef.h>
#include <stdint.h>

// Проверка на наличие определения BIGNUM_CAPACITY из общего заголовка
#ifndef BIGNUM_CAPACITY
#  error "bignum.h must define BIGNUM_CAPACITY"
#endif

#ifdef __cplusplus
extern "C" {
#endif


/**
 * @brief Reports the result of the in-place bignum shift.
 * @details A successful status guarantees the caller-owned object was updated;
 * every error status leaves the object unchanged. The API allocates no memory
 * and does not transfer ownership.
 */
typedef enum {
    BIGNUM_TEMPLATE_SUCCESS         =  0, /**< Shift completed or amount was zero; `num` is valid and normalized. */
    BIGNUM_TEMPLATE_ERROR_NULL_ARG  = -1, /**< `num` was NULL; no object was dereferenced and no output exists. */
    BIGNUM_TEMPLATE_ERROR_OVERFLOW  = -2  /**< Significant bits would exceed capacity; `num` remains unchanged and retry is valid with a smaller amount. */
} bignum_template_status_t;

/**
 * @brief      Выполняет логический сдвиг большого числа влево.
 *
 * @param[in,out] num           Указатель на число для модификации. Размер внутреннего
 *                              буфера определяется BIGNUM_CAPACITY.
 * @param[in]     template_amount  Количество бит для сдвига влево.
 *
 * @return
 *   - `BIGNUM_TEMPLATE_SUCCESS` (0) – сдвиг выполнен успешно.
 *   - `BIGNUM_TEMPLATE_ERROR_NULL_ARG` (-1) – передан NULL вместо числа.
 *   - `BIGNUM_TEMPLATE_ERROR_OVERFLOW` (-2) – сдвиг привёл к переполнению ёмкости.
 *
 * @details
 *   **Алгоритм:**
 *   1.  Проверка аргументов на NULL.
 *   2.  Если `template_amount` равен 0, немедленно вернуть успех.
 *   3.  Вычислить сдвиг в целых словах (`word_template`) и в битах внутри слова (`bit_template`).
 *   4.  Проверить, не приведет ли сдвиг к переполнению (самый старший бит
 *       сдвигается за пределы емкости `BIGNUM_CAPACITY`).
 *   5.  Выполнить сдвиг по словам, перемещая данные в старшие позиции.
 *   6.  Выполнить побитовый сдвиг внутри слов, распространяя биты-переносы
 *       из младших слов в старшие.
 *   7.  Обновить поле `len` и нормализовать результат (удалить ведущие нули).
 *
 * @pre `num` is either NULL or points to a live caller-owned `bignum_t`; the
 * object is not concurrently modified by another thread.
 * @post On success `num` is shifted in place and normalized; on error the
 * object and any caller-visible state are unchanged.
 * @warning The operation is reentrant for independent objects; overlapping
 * concurrent readers/writers require external synchronization.
 * @thread_safety Safe for independent objects and not safe for concurrent
 * mutation of the same object.
 * @complexity O(BIGNUM_CAPACITY) worst-case time and O(1) auxiliary space.
 */
bignum_template_status_t bignum_template(bignum_t* restrict num, size_t template_amount);

#ifdef __cplusplus
}
#endif

#endif /* BIGNUM_TEMPLATE_H */
