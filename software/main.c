typedef unsigned int  uint32_t;
typedef unsigned char uint8_t;
typedef unsigned short uint16_t;

/* Volatile objects force real loads and stores in the generated program. */
static volatile uint32_t values[10];
static volatile uint8_t byte_slot;
static volatile uint16_t half_slot;
static volatile uint32_t initialized_word = 0x12345678u;

int main(void)
{
    uint32_t sum = 0;
    uint32_t i;

    for (i = 0; i < 10; ++i) {
        values[i] = i + 1;
        sum += values[i];
    }

    byte_slot = 0xffu;
    half_slot = 0x8123u;

    if (sum != 55u)
        return 2;
    if (byte_slot != 255u)
        return 3;
    if (half_slot != 0x8123u)
        return 4;
    if (initialized_word != 0x12345678u)
        return 5;

    return 1;
}
