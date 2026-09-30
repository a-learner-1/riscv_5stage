#include <stdarg.h>

#include "coremark.h"
#include "core_portme.h"
#include "mmio.h"

#define COREMARK_CLOCK_HZ 100000000u
#define TOHOST_ADDR       0x00013ffcu

#define TOHOST_REG (*(volatile ee_u32 *)TOHOST_ADDR)

volatile ee_s32 seed1_volatile = 0;
volatile ee_s32 seed2_volatile = 0;
volatile ee_s32 seed3_volatile = 0x66;
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

ee_u32 default_num_contexts = 1;

static CORE_TICKS start_ticks;
static CORE_TICKS stop_ticks;
static ee_u32 coremark_failed;

static int string_starts_with(const char *text, const char *prefix)
{
    while (*prefix != '\0') {
        if (*text != *prefix)
            return 0;
        ++text;
        ++prefix;
    }
    return 1;
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

    while (*text != '\0') {
        count += emit_char(*text);
        ++text;
    }

    return count;
}

static int emit_unsigned(ee_u32 value,
                         ee_u32 base,
                         int width,
                         char padding)
{
    char buffer[16];
    int digits = 0;
    int count = 0;

    do {
        ee_u32 digit = value % base;
        buffer[digits] = (digit < 10u)
            ? (char)('0' + digit)
            : (char)('a' + digit - 10u);
        ++digits;
        value /= base;
    } while (value != 0u);

    while (width > digits) {
        count += emit_char(padding);
        --width;
    }

    while (digits > 0) {
        --digits;
        count += emit_char(buffer[digits]);
    }

    return count;
}

int ee_printf(const char *format, ...)
{
    va_list arguments;
    int count = 0;

    /*
     * ITERATIONS=1 is intentionally shorter than CoreMark's official
     * ten-second reporting rule.  Treat CRC and datatype failures as real
     * smoke-test failures, but do not fail only because the run is short.
     */
    if (string_starts_with(format, "[%u]ERROR!") ||
        string_starts_with(format, "ERROR:"))
        coremark_failed = 1u;

    if (string_starts_with(format, "ERROR!") &&
        !string_starts_with(
            format,
            "ERROR! Must execute for at least 10 secs"))
        coremark_failed = 1u;

    va_start(arguments, format);

    while (*format != '\0') {
        int width = 0;
        int is_long = 0;
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

        while ((*format >= '0') && (*format <= '9')) {
            width = width * 10 + (*format - '0');
            ++format;
        }

        if (*format == 'l') {
            is_long = 1;
            ++format;
        }

        switch (*format) {
        case 'c':
            count += emit_char((char)va_arg(arguments, int));
            break;

        case 's':
            count += emit_string(va_arg(arguments, const char *));
            break;

        case 'd': {
            ee_s32 value = is_long
                ? (ee_s32)va_arg(arguments, long)
                : (ee_s32)va_arg(arguments, int);
            ee_u32 magnitude;

            if (value < 0) {
                count += emit_char('-');
                if (width > 0)
                    --width;
                magnitude = (ee_u32)(-(value + 1)) + 1u;
            } else {
                magnitude = (ee_u32)value;
            }
            count += emit_unsigned(magnitude, 10u, width, padding);
            break;
        }

        case 'u': {
            ee_u32 value = is_long
                ? (ee_u32)va_arg(arguments, unsigned long)
                : (ee_u32)va_arg(arguments, unsigned int);
            count += emit_unsigned(value, 10u, width, padding);
            break;
        }

        case 'x': {
            ee_u32 value = is_long
                ? (ee_u32)va_arg(arguments, unsigned long)
                : (ee_u32)va_arg(arguments, unsigned int);
            count += emit_unsigned(value, 16u, width, padding);
            break;
        }

        default:
            count += emit_char('%');
            if (is_long)
                count += emit_char('l');
            if (*format != '\0')
                count += emit_char(*format);
            break;
        }

        if (*format != '\0')
            ++format;
    }

    va_end(arguments);
    return count;
}

void start_time(void)
{
    start_ticks = mmio_read_cycle();
}

void stop_time(void)
{
    stop_ticks = mmio_read_cycle();
}

CORE_TICKS get_time(void)
{
    return stop_ticks - start_ticks;
}

secs_ret time_in_secs(CORE_TICKS ticks)
{
    return (secs_ret)(ticks / COREMARK_CLOCK_HZ);
}

void portable_init(core_portable *portable, int *argc, char *argv[])
{
    (void)argc;
    (void)argv;

    coremark_failed = 0u;
    portable->portable_id = 1u;

    if (sizeof(ee_u32) != 4u)
        ee_printf("ERROR: ee_u32 is not 32 bits\n");
    if (sizeof(ee_ptr_int) != sizeof(void *))
        ee_printf("ERROR: ee_ptr_int cannot hold a pointer\n");
}

void portable_fini(core_portable *portable)
{
    portable->portable_id = 0u;

    if (coremark_failed == 0u)
        ee_printf(
            "SMOKE CHECK: algorithm CRCs and datatypes passed; "
            "the 10-second score rule was intentionally skipped.\n");
    else
        ee_printf("SMOKE CHECK: algorithm or datatype validation failed.\n");

    mmio_uart_flush();
    TOHOST_REG = (coremark_failed == 0u) ? 1u : 2u;
}
