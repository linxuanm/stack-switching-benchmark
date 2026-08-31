# gdb -batch -x count-insns.py --args <wizeng> ...   (env FUNC=<symbol>, NCALLS=<k>)
import gdb, os
func = os.environ.get("FUNC", "X86_64Runtime.runtime_handle_suspend")
ncalls = int(os.environ.get("NCALLS", "3"))
gdb.execute("set pagination off")
gdb.execute("break " + func)
gdb.execute("run", to_string=True)
for call in range(ncalls):
    rsp = int(gdb.parse_and_eval("$rsp"))
    ret = int(gdb.parse_and_eval("*(unsigned long*)$rsp"))
    n = 0
    calls = 0
    while True:
        gdb.execute("stepi", to_string=True)
        n += 1
        pc = int(gdb.parse_and_eval("$pc"))
        if pc == ret and int(gdb.parse_and_eval("$rsp")) == rsp + 8:
            break
        if n > 200000:
            print("gave up"); break
    print("%s call #%d: %d instructions" % (func, call + 1, n))
    if call + 1 < ncalls:
        gdb.execute("continue", to_string=True)
gdb.execute("kill", to_string=True)
