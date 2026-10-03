"""Build deterministic RV32 port fixtures; mock timer data never yields a score."""
import hashlib
import json
from pathlib import Path
import subprocess
from build_coremark_images import prefix
ROOT = Path(__file__).resolve().parents[1]
FLAGS = ['-march=rv32i', '-mabi=ilp32', '-O2', '-ffreestanding', '-fno-builtin',
         '-fno-stack-protector', '-fno-pic', '-msmall-data-limit=0', '-mno-relax',
         '-ffunction-sections', '-fdata-sections', '-Wall', '-Wextra', '-Werror']

def run(args):
    return subprocess.check_output(args, cwd=ROOT, text=True)

def image(path, output, words):
    data=path.read_bytes()
    if len(data)>words*4:
        raise RuntimeError('Fixture memory overflow')
    data += bytes(words*4-len(data))
    output.write_text(''.join(f'{int.from_bytes(data[i:i+4], "little"):08x}\n' for i in range(0,len(data),4)), encoding='ascii')

def main():
    cross=prefix()
    version=run([cross+'gcc', '--version']).splitlines()[0]
    definitions=[]
    reports={}
    for hz in (50000000,100000000):
        for formal in (0,1):
            name=f'coremark_math_{hz//1000000}_{"formal" if formal else "smoke"}'
            build=ROOT/'build/coremark_port_tests'/name
            build.mkdir(parents=True,exist_ok=True)
            header={'COMPILER_VERSION':version,'COMPILER_FLAGS':' '.join(FLAGS),
                    'MEM_LOCATION':'TEST ONLY: scripted MMIO, no performance score',
                    'COREMARK_PROFILE_NAME':name,'COREMARK_BUILD_PROFILE':name}
            config='\n'.join('#define '+key+' '+json.dumps(value) for key,value in header.items())+'\n'
            config+=f'#define COREMARK_CLOCK_HZ {hz}u\n#define COREMARK_UART_BAUD 5000000u\n#define COREMARK_FORMAL {formal}\n#define COREMARK_BUILD_ITERATIONS 123u\n'
            (build/'coremark_build_config.h').write_text(config,encoding='ascii')
            elf=build/(name+'.elf')
            sources=['software/coremark_port/start_coremark.S','software/coremark_port/core_portme.c','tests/coremark_port_math.c']
            command=[cross+'gcc',*FLAGS,'-DITERATIONS=123','-DPERFORMANCE_RUN=1','-DTOTAL_DATA_SIZE=2000',
                     '-DCOREMARK_PORT_TEST_INCLUDE="port_test_io.h"','-I'+str(build),
                     '-Ibenchmarks/coremark','-Isoftware/coremark_port','-Isoftware','-Itests',
                     '-nostdlib','-nostartfiles','-static','-Wl,-T,software/link.ld',
                     '-Wl,--gc-sections','-Wl,--no-relax','-Wl,-Map,'+str(build/(name+'.map')),
                     *sources,'-lgcc','-o',str(elf)]
            run(command)
            for section,words,suffix in (('.text',8192,''),('.data',4096,'_data')):
                binary=build/(name+suffix+'.bin')
                run([cross+'objcopy','-O','binary','-j',section,str(elf),str(binary)])
                image(binary,ROOT/'programs'/(name+suffix+'.hex'),words)
            symbols={}
            for line in run([cross+'nm','-n',str(elf)]).splitlines():
                cols=line.split()
                if len(cols)==3:
                    symbols[cols[2]]=int(cols[0],16)
            if symbols['__stack_top']-symbols['__bss_end']<2048:
                raise RuntimeError('Insufficient fixture stack')
            tag=name.upper()
            for symbol,label in [('coremark_math_cases','CASES'),('coremark_math_failure','FAILURE')]:
                definitions.append(f"`define {tag}_{label} 32'h{symbols[symbol]:08x}")
            reports[name]={'clock_hz':hz,'formal':formal,'mock_timing':True,'version':version,
                           'command':command,'cases':13,'text_bytes':(build/(name+'.bin')).stat().st_size,
                           'sources':{s:hashlib.sha256((ROOT/s).read_bytes()).hexdigest() for s in sources},
                           'symbols':{k:symbols[k] for k in ['coremark_math_cases','coremark_math_failure']}}
            print(name+': '+run([cross+'size',str(elf)]).splitlines()[-1])
    (ROOT/'programs/coremark_math_symbols.vh').write_text('\n'.join(definitions)+'\n',encoding='ascii')
    (ROOT/'build/coremark_port_tests/build_report.json').write_text(json.dumps(reports,indent=2)+'\n',encoding='utf-8')

if __name__=='__main__':
    main()
