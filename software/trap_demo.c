/* M-only synchronous exception demonstration. Requires ENABLE_TRAPS=1.
 * No external interrupts, privilege switching or FENCE.I are used. */
typedef unsigned int u32;
extern void trap_entry(void);
extern const char trap_demo_ecall[], trap_demo_ebreak[];
extern const char trap_demo_illegal[], trap_demo_badcsr[];

volatile u32 trap_demo_count;
volatile u32 trap_demo_log[4][4];
volatile u32 trap_demo_guard = 0x12345678u;
volatile u32 trap_demo_resumed;

#define CSR_READ(name) ({u32 value; __asm__ volatile("csrr %0, " #name : "=r"(value)); value;})
#define CSR_WRITE(name, value) __asm__ volatile("csrw " #name ", %0" :: "r"((u32)(value)) : "memory")

static void uart_putc(char ch)
{
    volatile u32 *status = (volatile u32 *)0x20000014u;
    while (*status & 1u) {}
    *(volatile u32 *)0x20000010u = (unsigned char)ch;
}
static void uart_puts(const char *s) { while (*s) uart_putc(*s++); }
static void uart_flush(void)
{
    while (*(volatile u32 *)0x20000014u & 1u) {}
}
static void uart_hex(u32 value)
{
    for (int shift = 28; shift >= 0; shift -= 4) {
        u32 digit = (value >> shift) & 15u;
        uart_putc((char)(digit < 10u ? '0' + digit : 'A' + digit - 10u));
    }
}
static void fail(u32 code)
{
    uart_puts("TRAP FAIL "); uart_hex(code); uart_puts("\r\n"); uart_flush();
    *(volatile u32 *)0x00013ffcu = 0xdead0000u | code;
    for (;;) {}
}

/* Return the recovery PC to the assembly entry; all 32-bit demo faults
 * are deliberately skipped. A real application must choose recovery per cause. */
u32 trap_demo_handler(u32 cause, u32 pc, u32 tval, u32 status)
{
    const u32 expected_cause[4] = {11u, 3u, 2u, 2u};
    const u32 expected_pc[4] = {(u32)trap_demo_ecall, (u32)trap_demo_ebreak,
                               (u32)trap_demo_illegal, (u32)trap_demo_badcsr};
    const u32 expected_tval[4] = {0u, (u32)trap_demo_ebreak, 0xffffffffu, 0x77702073u};
    u32 slot = trap_demo_count;
    if (slot >= 4u || cause != expected_cause[slot] || pc != expected_pc[slot] ||
        tval != expected_tval[slot] || (status & 0x1888u) != 0x1880u)
        fail(0x10u + slot);
    trap_demo_log[slot][0] = cause;
    trap_demo_log[slot][1] = pc;
    trap_demo_log[slot][2] = tval;
    trap_demo_log[slot][3] = status;
    trap_demo_count = slot + 1u;
    return pc + 4u;
}

int main(void)
{
    u32 old, value;
    CSR_WRITE(mtvec, trap_entry);
    if (CSR_READ(mtvec) != (u32)trap_entry) fail(1u);
    CSR_WRITE(mscratch, 0x12345678u);
    value = 0xffu;
    __asm__ volatile("csrrs %0, mscratch, %1" : "=r"(old) : "r"(value));
    if (old != 0x12345678u || CSR_READ(mscratch) != 0x123456ffu) fail(2u);
    value = 0xf0u;
    __asm__ volatile("csrrc %0, mscratch, %1" : "=r"(old) : "r"(value));
    if (old != 0x123456ffu || CSR_READ(mscratch) != 0x1234560fu) fail(3u);
    __asm__ volatile("csrrwi %0, mscratch, 16" : "=r"(old));
    if (old != 0x1234560fu) fail(4u);
    __asm__ volatile("csrrsi %0, mscratch, 3" : "=r"(old));
    if (old != 16u) fail(5u);
    __asm__ volatile("csrrci %0, mscratch, 1" : "=r"(old));
    if (old != 19u || CSR_READ(mscratch) != 18u) fail(6u);
    __asm__ volatile("csrrw %0, misa, zero" : "=r"(old));
    if (old != 0x40000100u || CSR_READ(misa) != old || CSR_READ(mhartid) != 0u) fail(7u);
    trap_demo_guard = 0x89abcdefu;
    __asm__ volatile("fence iorw, iorw" ::: "memory");
    if (trap_demo_guard != 0x89abcdefu) fail(8u);
    value = 8u;
    __asm__ volatile("csrrs zero, mstatus, %0" :: "r"(value) : "memory");
    __asm__ volatile(".global trap_demo_ecall\ntrap_demo_ecall: ecall" ::: "memory");
    trap_demo_resumed++;
    __asm__ volatile(".global trap_demo_ebreak\ntrap_demo_ebreak: ebreak" ::: "memory");
    trap_demo_resumed++;
    __asm__ volatile(".global trap_demo_illegal\ntrap_demo_illegal: .word 0xffffffff" ::: "memory");
    trap_demo_resumed++;
    __asm__ volatile(".global trap_demo_badcsr\ntrap_demo_badcsr: .word 0x77702073" ::: "memory");
    trap_demo_resumed++;
    if (trap_demo_count != 4u || trap_demo_resumed != 4u ||
        trap_demo_guard != 0x89abcdefu || CSR_READ(mscratch) != 18u ||
        (CSR_READ(mstatus) & 0x1888u) != 0x1888u) fail(9u);
    uart_puts("TRAP PASS FENCE CSR ECALL EBREAK ILLEGAL\r\n");
    uart_flush();
    return 1;
}
