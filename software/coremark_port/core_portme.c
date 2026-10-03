#include <stdarg.h>

#include "coremark.h"
#include "core_portme.h"
#ifdef COREMARK_PORT_TEST_INCLUDE
/* Deterministic I/O belongs only to the focused port test firmware. */
#include COREMARK_PORT_TEST_INCLUDE
#else
#include "mmio.h"
#include "timer.h"
#endif

#ifndef COREMARK_TOHOST_WRITE
#define COREMARK_TOHOST_WRITE(value) \
    (*(volatile ee_u32 *)0x00013ffcu = (value))
#endif

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
#else
volatile ee_s32 seed1_volatile = 0;
volatile ee_s32 seed2_volatile = 0;
#endif
volatile ee_s32 seed3_volatile = 0x66;
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

ee_u32 default_num_contexts = 1;
volatile ee_u32 coremark_actual_iterations;
volatile CORE_TICKS coremark_elapsed_ticks;
volatile ee_u32 coremark_failed;

static volatile CORE_TICKS start_ticks;
static volatile CORE_TICKS stop_ticks;
static ee_u32 report_seen;
static ee_u32 short_run_seen;
static ee_u32 valid_operation_seen;
static ee_u32 reported_seed_crc;
static ee_u32 reported_list_crc;
static ee_u32 reported_matrix_crc;
static ee_u32 reported_state_crc;

enum {
    REPORT_TICKS = 1u,
    REPORT_ITERATIONS = 2u,
    REPORT_SEED = 4u,
    REPORT_LIST = 8u,
    REPORT_MATRIX = 16u,
    REPORT_STATE = 32u,
    REPORT_COMPLETE = 63u
};

static int string_starts_with(const char *text, const char *prefix)
{
    while (*prefix != '\0') {
        if (*text++ != *prefix++)
            return 0;
    }
    return 1;
}

static int string_equals(const char *left, const char *right)
{
    while (*left != '\0' && *left == *right) {
        ++left;
        ++right;
    }
    return *left == *right;
}

static int emit_char(char character)
{
    mmio_putchar(character);
    return 1;
}

static int emit_string(const char *text)
{
    int count = 0;
    if (text == NULL)
        text = "(null)";
    while (*text != '\0')
        count += emit_char(*text++);
    return count;
}

static int unsigned_digits(ee_u64 value, ee_u32 base)
{
    int digits = 1;
    while (value >= base) {
        value /= base;
        ++digits;
    }
    return digits;
}

static int emit_unsigned(ee_u64 value, ee_u32 base, int width, char padding)
{
    char buffer[32];
    int digits = 0;
    int count = 0;
    do {
        ee_u32 digit = (ee_u32)(value % base);
        buffer[digits++] = digit < 10u
            ? (char)('0' + digit) : (char)('a' + digit - 10u);
        value /= base;
    } while (value != 0u);
    while (width-- > digits)
        count += emit_char(padding);
    while (digits > 0)
        count += emit_char(buffer[--digits]);
    return count;
}

/* Round the exact IEEE-754 binary value to a decimal integer using two
 * 64-bit limbs. This avoids double multiplication moving a value onto a
 * rounding tie, and avoids undefined out-of-range floating conversions.
 * Ties round to even, as printf does in its default rounding mode. */
static int decimal_round(double value, int precision, ee_u64 *rounded,
                         int *negative)
{
    union { double number; ee_u64 bits; } representation;
    ee_u64 significand, lower, upper, high, low, quotient, remainder, half;
    ee_u32 five = 1u, exponent;
    int binary_shift, right, index, round_up = 0;

    representation.number = value;
    *negative = (int)(representation.bits >> 63);
    exponent = (ee_u32)((representation.bits >> 52) & 0x7ffu);
    if (exponent == 0x7ffu || precision < 0 || precision > 9)
        return 0;
    significand = representation.bits & 0x000fffffffffffffULL;
    if (exponent != 0u)
        significand |= 0x0010000000000000ULL;
    for (index = 0; index < precision; ++index)
        five *= 5u;
    lower = (significand & 0xffffffffu) * five;
    upper = (significand >> 32) * five + (lower >> 32);
    low = (upper << 32) | (lower & 0xffffffffu);
    high = upper >> 32;
    binary_shift = (exponent ? (int)exponent - 1023 : -1022) - 52 + precision;
    if (binary_shift >= 0) {
        if (high || binary_shift >= 63 ||
            low >= (0x8000000000000000ULL >> binary_shift))
            return 0;
        quotient = low << binary_shift;
    } else {
        right = -binary_shift;
        if (right >= 128) {
            quotient = 0u;
        } else if (right > 64) {
            quotient = high >> (right - 64);
            remainder = high & ((1ULL << (right - 64)) - 1u);
            half = 1ULL << (right - 65);
            round_up = remainder > half ||
                (remainder == half && (low || (quotient & 1u)));
        } else if (right == 64) {
            quotient = high;
            half = 0x8000000000000000ULL;
            round_up = low > half || (low == half && (quotient & 1u));
        } else {
            if (high >> right)
                return 0;
            quotient = (low >> right) | (high << (64 - right));
            remainder = low & ((1ULL << right) - 1u);
            half = 1ULL << (right - 1);
            round_up = remainder > half ||
                (remainder == half && (quotient & 1u));
        }
        if (quotient >= 0x8000000000000000ULL)
            return 0;
        quotient += (ee_u64)round_up;
    }
    if (quotient >= 0x8000000000000000ULL)
        return 0;
    *rounded = quotient;
    return 1;
}

/* Precision 0..9 and scaled magnitudes below 2^63 are supported. Every
 * rejected value makes the run fail, including a smoke run. */
static int emit_float(double value, int precision, int width, char padding)
{
    ee_u64 scale = 1u;
    ee_u64 rounded, integer, fraction;
    int negative, digits, count = 0, index;

    if (!decimal_round(value, precision, &rounded, &negative)) {
        coremark_failed = 1u;
        return emit_string("<float-range>");
    }
    for (index = 0; index < precision; ++index)
        scale *= 10u;
    integer = rounded / scale;
    fraction = rounded % scale;
    digits = unsigned_digits(integer, 10u) + negative;
    if (precision > 0)
        digits += precision + 1;
    if (padding != '0') {
        while (width-- > digits)
            count += emit_char(padding);
    }
    if (negative)
        count += emit_char('-');
    if (padding == '0') {
        while (width-- > digits)
            count += emit_char('0');
    }
    count += emit_unsigned(integer, 10u, 0, ' ');
    if (precision > 0) {
        count += emit_char('.');
        count += emit_unsigned(fraction, 10u, precision, '0');
    }
    return count;
}

static void observe_report(const char *format, va_list arguments)
{
    va_list copy;
    va_copy(copy, arguments);
    if (string_equals(format, "Iterations       : %lu\n")) {
        coremark_actual_iterations = (ee_u32)va_arg(copy, unsigned long);
        report_seen |= REPORT_ITERATIONS;
    } else if (string_equals(format, "seedcrc          : 0x%04x\n")) {
        reported_seed_crc = va_arg(copy, unsigned int);
        report_seen |= REPORT_SEED;
    } else if (string_equals(format, "[%d]crclist       : 0x%04x\n")) {
        if (va_arg(copy, int) == 0) {
            reported_list_crc = va_arg(copy, unsigned int);
            report_seen |= REPORT_LIST;
        }
    } else if (string_equals(format, "[%d]crcmatrix     : 0x%04x\n")) {
        if (va_arg(copy, int) == 0) {
            reported_matrix_crc = va_arg(copy, unsigned int);
            report_seen |= REPORT_MATRIX;
        }
    } else if (string_equals(format, "[%d]crcstate      : 0x%04x\n")) {
        if (va_arg(copy, int) == 0) {
            reported_state_crc = va_arg(copy, unsigned int);
            report_seen |= REPORT_STATE;
        }
    }
    va_end(copy);
}

int ee_printf(const char *format, ...)
{
    va_list arguments;
    int count = 0;

    if (string_starts_with(format,
                          "ERROR! Must execute for at least 10 secs")) {
        short_run_seen = 1u;
        if (COREMARK_FORMAL)
            coremark_failed = 1u;
    } else if (string_starts_with(format, "[%u]ERROR!") ||
               string_starts_with(format, "ERROR:") ||
               string_starts_with(format, "ERROR!") ||
               string_starts_with(format, "Cannot validate operation") ||
               string_starts_with(format, "list_head structure too big")) {
        coremark_failed = 1u;
    }
    if (string_starts_with(format, "Errors detected") &&
        (COREMARK_FORMAL || !short_run_seen))
        coremark_failed = 1u;
    if (string_starts_with(format, "Correct operation validated."))
        valid_operation_seen = 1u;

    va_start(arguments, format);
    if (string_equals(format, "Total ticks      : %lu\n")) {
        /* Upstream casts to ee_u32 before printing. Consume its original
         * argument, then print the actual 64-bit elapsed value instead. */
        (void)va_arg(arguments, unsigned long);
        coremark_elapsed_ticks = get_time();
        report_seen |= REPORT_TICKS;
        count = emit_string("Total ticks      : ");
        count += emit_unsigned(coremark_elapsed_ticks, 10u, 0, ' ');
        count += emit_char('\n');
        va_end(arguments);
        return count;
    }
    observe_report(format, arguments);

    while (*format != '\0') {
        int width = 0, length = 0, precision = 6;
        char padding = ' ';
        if (*format != '%') {
            count += emit_char(*format++);
            continue;
        }
        ++format;
        if (*format == '%') {
            count += emit_char('%');
            ++format;
            continue;
        }
        if (*format == '0') {
            padding = '0';
            ++format;
        }
        while (*format >= '0' && *format <= '9') {
            if (width > 64) {
                coremark_failed = 1u;
                break;
            }
            width = width * 10 + (*format++ - '0');
        }
        if (*format == '.') {
            ++format;
            precision = 0;
            while (*format >= '0' && *format <= '9') {
                if (precision > 9) {
                    coremark_failed = 1u;
                    break;
                }
                precision = precision * 10 + (*format++ - '0');
            }
        }
        while (*format == 'l' && length < 2) {
            ++length;
            ++format;
        }
        if (width > 64 || precision > 9) {
            coremark_failed = 1u;
            count += emit_string("<format-range>");
            break;
        }
        switch (*format) {
        case 'c':
            count += emit_char((char)va_arg(arguments, int));
            break;
        case 's':
            count += emit_string(va_arg(arguments, const char *));
            break;
        case 'd': {
            long long value = length == 2
                ? va_arg(arguments, long long) : length == 1
                ? va_arg(arguments, long) : va_arg(arguments, int);
            ee_u64 magnitude = value < 0
                ? (ee_u64)(-(value + 1)) + 1u : (ee_u64)value;
            if (value < 0) {
                if (padding != '0') {
                    int digits = unsigned_digits(magnitude, 10u) + 1;
                    while (width > digits) {
                        count += emit_char(' ');
                        --width;
                    }
                }
                count += emit_char('-');
                if (width > 0)
                    --width;
            }
            count += emit_unsigned(magnitude, 10u, width, padding);
            break;
        }
        case 'u':
        case 'x': {
            ee_u64 value = length == 2
                ? va_arg(arguments, unsigned long long) : length == 1
                ? va_arg(arguments, unsigned long)
                : va_arg(arguments, unsigned int);
            count += emit_unsigned(value, *format == 'x' ? 16u : 10u,
                                   width, padding);
            break;
        }
        case 'f':
            count += emit_float(va_arg(arguments, double), precision,
                                width, padding);
            break;
        default:
            coremark_failed = 1u;
            count += emit_string("<format-error>");
            va_end(arguments);
            return count;
        }
        ++format;
    }
    va_end(arguments);
    return count;
}

void start_time(void)
{
    start_ticks = timer_read_time();
}

void stop_time(void)
{
    stop_ticks = timer_read_time();
    coremark_elapsed_ticks = stop_ticks - start_ticks;
}

CORE_TICKS get_time(void)
{
    return stop_ticks - start_ticks;
}

secs_ret time_in_secs(CORE_TICKS ticks)
{
    return (secs_ret)ticks / (secs_ret)COREMARK_CLOCK_HZ;
}

void portable_init(core_portable *portable, int *argc, char *argv[])
{
    (void)argc;
    (void)argv;
    coremark_failed = 0u;
    coremark_actual_iterations = 0u;
    coremark_elapsed_ticks = 0u;
    start_ticks = stop_ticks = 0u;
    report_seen = short_run_seen = valid_operation_seen = 0u;
    reported_seed_crc = reported_list_crc = 0u;
    reported_matrix_crc = reported_state_crc = 0u;
    portable->portable_id = 1u;
    if (sizeof(ee_u32) != 4u)
        ee_printf("ERROR: ee_u32 is not 32 bits\n");
    if (sizeof(ee_ptr_int) != sizeof(void *))
        ee_printf("ERROR: ee_ptr_int cannot hold a pointer\n");
    if (sizeof(CORE_TICKS) != 8u || sizeof(double) != 8u)
        ee_printf("ERROR: CoreMark requires 64-bit ticks and double\n");
}

static int known_crcs_match(void)
{
    /* These are the upstream known results for 2K and 6K data sizes. */
#if VALIDATION_RUN
    if (reported_seed_crc == 0x18f2u)
        return reported_list_crc == 0xe3c1u &&
               reported_matrix_crc == 0x0747u && reported_state_crc == 0x8d84u;
    if (reported_seed_crc == 0x7b05u)
        return reported_list_crc == 0x3340u &&
               reported_matrix_crc == 0x1199u && reported_state_crc == 0x39bfu;
#else
    if (reported_seed_crc == 0xe9f5u)
        return reported_list_crc == 0xe714u &&
               reported_matrix_crc == 0x1fd7u && reported_state_crc == 0x8e3au;
    if (reported_seed_crc == 0x8a02u)
        return reported_list_crc == 0xd4b0u &&
               reported_matrix_crc == 0xbe52u && reported_state_crc == 0x5e47u;
#endif
    return 0;
}

void portable_fini(core_portable *portable)
{
    double seconds = time_in_secs(get_time());
    double rate = seconds > 0.0
        ? (double)coremark_actual_iterations / seconds : 0.0;
    portable->portable_id = 0u;
    if (report_seen != REPORT_COMPLETE || coremark_actual_iterations == 0u ||
        get_time() == 0u || !known_crcs_match())
        coremark_failed = 1u;
    if (COREMARK_FORMAL &&
        (get_time() < (CORE_TICKS)COREMARK_CLOCK_HZ * 10u ||
         !valid_operation_seen))
        coremark_failed = 1u;

    ee_printf("COREMARK profile=%s\n", COREMARK_PROFILE_NAME);
    ee_printf("COREMARK mode=%s\n", COREMARK_FORMAL ? "formal" : "smoke");
    ee_printf("COREMARK run=%s\n", VALIDATION_RUN ? "validation" : "performance");
    ee_printf("COREMARK cpu_hz=%u\n", (ee_u32)COREMARK_CLOCK_HZ);
    ee_printf("COREMARK uart_baud=%u\n", (ee_u32)COREMARK_UART_BAUD);
    ee_printf("COREMARK iterations_requested=%u\n", (ee_u32)ITERATIONS);
    ee_printf("COREMARK iterations=%u\n", coremark_actual_iterations);
    ee_printf("COREMARK raw_ticks=%llu\n", (ee_u64)get_time());
    ee_printf("COREMARK seconds=%.9f\n", seconds);
    ee_printf("COREMARK iterations_per_second=%.9f\n", rate);
    ee_printf("COREMARK coremark_per_mhz=%.9f\n",
              rate * 1000000.0 / (double)COREMARK_CLOCK_HZ);
    ee_printf("COREMARK seed1=0x%04x\n", (ee_u32)(ee_u16)seed1_volatile);
    ee_printf("COREMARK seed2=0x%04x\n", (ee_u32)(ee_u16)seed2_volatile);
    ee_printf("COREMARK seed3=0x%04x\n", (ee_u32)(ee_u16)seed3_volatile);
    ee_printf("COREMARK seedcrc=0x%04x\n", reported_seed_crc);
    ee_printf("COREMARK crclist=0x%04x\n", reported_list_crc);
    ee_printf("COREMARK crcmatrix=0x%04x\n", reported_matrix_crc);
    ee_printf("COREMARK crcstate=0x%04x\n", reported_state_crc);
    ee_printf("COREMARK compiler=%s\n", COMPILER_VERSION);
    ee_printf("COREMARK flags=%s\n", COMPILER_FLAGS);
    ee_printf("COREMARK memory=%s\n", MEM_LOCATION);
    if (!COREMARK_FORMAL)
        ee_printf("NOTE: smoke timing is a functional observation; it is not a formal score.\n");
    ee_printf("COREMARK RESULT: %s %s\n",
              COREMARK_FORMAL ? "FORMAL" : "SMOKE",
              coremark_failed ? "FAIL" : "PASS");
    mmio_uart_flush();
    COREMARK_TOHOST_WRITE(coremark_failed ? 2u : 1u);
}
