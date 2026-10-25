#include "cpu5_stats.h"
#if !defined(CPU5_STATS_CACHE_ENABLE) || !defined(CPU5_STATS_BACKEND_ID)
#error "CPU5 system smoke requires generated hardware identity"
#endif
static inline void barrier(void) { __asm__ volatile("fence rw,rw" ::: "memory"); }

void cpu5_smoke(void)
{
    volatile cpu5_stats_u32 *out=(volatile cpu5_stats_u32 *)0x10000u;
    volatile cpu5_stats_u32 *work=(volatile cpu5_stats_u32 *)0x10200u;
    cpu5_stats_u32 i,j,fail=0,checksum=0;
    cpu5_stats_u64 cycles_start,cycles_stop,sum=0;
    out[0]=0;
    /* Reading ID is also the first START. A second START below replaces it. */
    out[3]=cpu5_stats_read(0);
    out[2]=cpu5_stats_read(0x18);
    out[4]=cpu5_stats_read(8);
    out[5]=cpu5_stats_read(12);
    out[6]=cpu5_stats_read(16);
    out[7]=cpu5_stats_read(20);
    out[8]=cpu5_stats_read(28);
    if (out[3]!=CPU5_STATS_ID || out[2]!=4u) fail|=1u;
    if (out[4]!=(CPU5_STATS_CACHE_ENABLE?3u:0u)) fail|=2u;
    if (out[5]!=0x02040010u || out[6]!=0x02040010u) fail|=4u;
    if (out[7]!=0x00100001u || out[8]!=CPU5_STATS_BACKEND_ID) fail|=8u;
    for(i=0;i<16u;++i) work[i]=i+11u;
    barrier();
    if(cpu5_stats_read(0)!=CPU5_STATS_ID)fail|=16u;
    /* Volatile inputs and explicit M opcodes prevent constant folding. */
    for(i=0;i<24u;++i){
        cpu5_stats_u32 a=work[i&15u],b=i+3u,m,d;
        __asm__ volatile("mul %0,%1,%2":"=r"(m):"r"(a),"r"(b));
        __asm__ volatile("divu %0,%1,%2":"=r"(d):"r"(m),"r"(b));
        work[(i+1u)&15u]=d+i;
        checksum+=m^d;
        if((i&3u)==0u)barrier();
    }
    barrier();
    if(cpu5_stats_read(4)!=CPU5_STATS_ID)fail|=32u;
    for(i=0;i<8u;++i)out[9u+i]=cpu5_stats_read(0x40u+i*4u);
    for(i=0;i<4u;++i)out[13u+i]=cpu5_stats_read(0x80u+i*4u);
    cycles_start=cpu5_stats_join(out[9],out[10]);
    cycles_stop=cpu5_stats_join(out[13],out[14]);
    /* Retain all 40 profile words, then reread them while time advances. */
    for(i=0;i<10u;++i){
        cpu5_stats_u64 a,b;
        for(j=0;j<2u;++j){
            out[32u+i*2u+j]=cpu5_stats_read(cpu5_stats_profile_offset(0,i)+j*4u);
            out[52u+i*2u+j]=cpu5_stats_read(cpu5_stats_profile_offset(1,i)+j*4u);
        }
        a=cpu5_stats_join(out[32u+i*2u],out[33u+i*2u]);
        b=cpu5_stats_join(out[52u+i*2u],out[53u+i*2u]);
        sum+=b-a;
    }
    for(i=0;i<10u;++i)for(j=0;j<2u;++j){
        out[72u+i*2u+j]=cpu5_stats_read(cpu5_stats_profile_offset(0,i)+j*4u);
        out[92u+i*2u+j]=cpu5_stats_read(cpu5_stats_profile_offset(1,i)+j*4u);
        if(out[72u+i*2u+j]!=out[32u+i*2u+j] || out[92u+i*2u+j]!=out[52u+i*2u+j])fail|=64u;
    }
    out[17]=(cpu5_stats_u32)(cycles_stop-cycles_start);
    out[18]=(cpu5_stats_u32)((cycles_stop-cycles_start)>>32);
    out[19]=(cpu5_stats_u32)sum;out[20]=(cpu5_stats_u32)(sum>>32);
    out[21]=checksum;
    if(sum!=cycles_stop-cycles_start || sum==0u)fail|=128u;
    out[1]=fail;barrier();out[0]=fail?0xbad50005u:0x600d5005u;
    for(;;)__asm__ volatile("j ." ::: "memory");
}
