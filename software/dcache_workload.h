/* Real volatile loads/stores; data arrays intentionally collide in one set. */
volatile u32 dcache_a[4] __attribute__((aligned(1024)));
volatile u32 dcache_b[4] __attribute__((aligned(1024)));
volatile u32 dcache_c[4] __attribute__((aligned(1024)));
volatile u32 dcache_buffer[64] __attribute__((aligned(1024)));
volatile u32 dcache_result,dcache_completed;

static void dcache_workload(void)
{
    for(u32 n=0;n<4u;n++) {
        dcache_a[n]=n+1u;dcache_b[n]=n+11u;dcache_c[n]=n+21u;
    }
    u32 total=0u;
    for(u32 n=0;n<64u;n++) {
        u32 k=n&3u;
        total+=dcache_a[k];total+=dcache_b[k];total+=dcache_a[k];
        total+=dcache_c[k];total+=dcache_a[k];total+=dcache_b[k];
    }
    dcache_result=total;
    if(total!=3520u) fail(0x20u);
    for(u32 n=0;n<64u;n++) dcache_buffer[n]=0x12340000u+n;
    for(u32 n=0;n<64u;n++) if(dcache_buffer[n]!=0x12340000u+n) fail(0x21u);
    // Write hits must update only their byte lanes and also reach AXI RAM.
    u32 pointer=(u32)&dcache_buffer[0],loaded;
    __asm__ volatile("sb %0, 1(%1)" :: "r"(0xa5u),"r"(pointer) : "memory");
    __asm__ volatile("sh %0, 2(%1)" :: "r"(0xbeefu),"r"(pointer) : "memory");
    if(dcache_buffer[0]!=0xbeefa500u) fail(0x22u);
    __asm__ volatile("lbu %0, 1(%1)" : "=r"(loaded) : "r"(pointer) : "memory");
    if(loaded!=0xa5u) fail(0x23u);
    __asm__ volatile("lb %0, 1(%1)" : "=r"(loaded) : "r"(pointer) : "memory");
    if(loaded!=0xffffffa5u) fail(0x24u);
    __asm__ volatile("lhu %0, 2(%1)" : "=r"(loaded) : "r"(pointer) : "memory");
    if(loaded!=0xbeefu) fail(0x25u);
    __asm__ volatile("lh %0, 2(%1)" : "=r"(loaded) : "r"(pointer) : "memory");
    if(loaded!=0xffffbeefu) fail(0x26u);
    // Read the same cached word again, then replace both possible ways and
    // read from backing RAM; this catches cache-only writes on physical FPGA.
    (void)dcache_buffer[0];
    for(u32 n=0;n<4u;n++) { (void)dcache_a[n];(void)dcache_b[n];(void)dcache_c[n]; }
    if(dcache_buffer[0]!=0xbeefa500u) fail(0x27u);
    // Each read of the statistics device must reach its AXI endpoint.
    volatile u32 *stats=(volatile u32 *)0x30000000u;
    u32 snapshot[9];
    for(u32 n=0;n<9u;n++) snapshot[n]=stats[n];
    if(snapshot[0]!=0x44433241u||snapshot[1]!=0x02400010u||
       snapshot[3]==0u||snapshot[4]==0u||snapshot[6]!=0u||snapshot[7]==0u||
       snapshot[8]==0u||snapshot[2]!=snapshot[3]+snapshot[4]+snapshot[7]+snapshot[8]||
       snapshot[5]!=snapshot[4]*4u) fail(0x28u);
    dcache_completed=1u;
}
