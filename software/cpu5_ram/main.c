/* Freestanding RV32I fixture: every array access is an observable RAM access. */
typedef unsigned int u32;
typedef unsigned short u16;
typedef unsigned char u8;
typedef signed int s32;
typedef signed short s16;
typedef signed char s8;
#ifndef INPUT_SEED
#define INPUT_SEED 0x13579bdfu
#endif

volatile u32 input_seed = INPUT_SEED;
volatile u32 words[16];
volatile u16 halves[16];
volatile u8 bytes[32];
volatile u32 result[8];
volatile u32 * volatile cursor = &words[0];

/* GCC may choose LBU/LHU plus shifts for volatile signed objects.  Keep the
 * architectural signed-load cases explicit while the workload remains C. */
static inline s32 signed_byte(volatile u8 *p)
{
    s32 value;
    __asm__ volatile ("lb %0, 0(%1)" : "=r" (value) : "r" (p) : "memory");
    return value;
}
static inline s32 signed_half(volatile u16 *p)
{
    s32 value;
    __asm__ volatile ("lh %0, 0(%1)" : "=r" (value) : "r" (p) : "memory");
    return value;
}

__attribute__((noinline)) static u32 stack_mix(u32 index, u32 value)
{
    volatile u32 local[4];
    local[0] = value + index;
    local[1] = value ^ 0x89abcdefu;
    local[2] = value >> 3;
    local[3] = local[0] + local[1];
    return local[3] ^ local[2];
}

int main(void)
{
    u32 seed = input_seed;
    u32 sum = 0x31415926u;
    for (u32 i = 0; i != 16; ++i) {
        words[i] = (seed ^ (0x01020304u + (i << 12))) + (i << 1);
        halves[i] = (u16)(0x8000u ^ (seed >> (i & 7)) ^ (i << 8));
    }
    for (u32 i = 0; i != 32; ++i)
        bytes[i] = (u8)((seed >> (i & 15)) + (i << 3) - i);
    bytes[0] = 0x80u; bytes[1] = 0x7fu;
    bytes[2] = 0xffu; bytes[3] = 0;
    halves[0] = 0x8000u; halves[1] = 0x7fffu;
    halves[2] = 0xffffu; halves[3] = 0;
    for (u32 i = 0; i != 16; ++i) {
        u32 a = words[i];
        s32 h = signed_half(&halves[i]);
        u32 ub = bytes[i << 1];
        s32 sb = signed_byte(&bytes[(i << 1) + 1]);
        sum = ((sum << 5) | (sum >> 27)) ^ a;
        sum += (u32)h;
        sum ^= ((u32)sb << 8) | ub;
        words[i] = a + sum;
        if (words[i] & 1u) {
            sum ^= 0x5a5a5a5au;
            result[7] = i;
        }
        sum += stack_mix(i, sum);
    }
    cursor = &words[(seed >> 4) & 15u];
    u32 x = *cursor;
    *cursor = x ^ sum;
    x = *cursor;
    sum += x;
    /* A load into x0 must still access RAM and complete successfully. */
    __asm__ volatile ("lw zero, 0(%0)" : : "r" (&words[0]) : "memory");
    result[0] = sum;
    result[1] = stack_mix(7, sum);
    result[2] = (u32)signed_byte(&bytes[0]);
    result[3] = (u32)signed_half(&halves[0]);
    result[4] = bytes[2];
    result[5] = halves[2];
    result[6] = *cursor;
    result[7] = 0x600d0000u | (seed & 0xffffu);
    return 0;
}
