import os, subprocess, sys
mode = sys.argv[1]
args = [a for a in sys.argv[2:] if a not in ['-mthreads']]
base = r'C:\Program Files (x86)\Intel\oneAPI\compiler\latest\bin\compiler'
exe = os.path.join(base, 'clang++.exe' if mode == 'cxx' else 'clang.exe')
cmd = [exe, '-Qunused-arguments'] + args
raise SystemExit(subprocess.call(cmd))
