import sys,time
def w(s):
    sys.stdout.buffer.write(s.encode() if isinstance(s,str) else s)
    sys.stdout.buffer.flush()

# Phase 1: Individual protocol negotiation sequences
# Each should be completely invisible to the mirror
w("PHASE1_START\n")

w("push1_before ")
w("\x1b[>1u")       # Push mode: enable disambiguate-escape-codes
time.sleep(0.1)
w("push1_after\n")

w("push5_before ")
w("\x1b[>5u")       # Push mode: flags=5
time.sleep(0.1)
w("push5_after\n")

w("query_before ")
w("\x1b[?u")        # Query current mode
time.sleep(0.1)
w("query_after\n")

w("setflags_before ")
w("\x1b[=1;2u")     # Set specific flags
time.sleep(0.1)
w("setflags_after\n")

w("pop_before ")
w("\x1b[<u")        # Pop mode
time.sleep(0.1)
w("pop_after\n")

w("\x1b[<u")        # Pop remaining
time.sleep(0.1)

w("PHASE1_DONE\n")

# Phase 2: Interleaved with normal output (no gaps)
w("PHASE2_START\n")
w("before")
w("\x1b[>1u")       # Should be stripped completely
w("-after")
w("\x1b[<u")        # Should be stripped completely
w("-end\n")
w("PHASE2_DONE\n")

# Phase 3: Rapid push/pop cycling
w("PHASE3_START\n")
for i in range(10):
    w("\x1b[>1u")   # Push
    w(f"[{i}]")
    w("\x1b[<u")    # Pop
    time.sleep(0.02)
w("\n")
w("PHASE3_DONE\n")
