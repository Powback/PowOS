#!/usr/bin/env python3
# Every 100 ms: wall time (ms) and summed tcp_info counters of the waypipe TCP connection(s) to comp:5000.
#   t_ms  acked(app->comp)  received(comp->app)  retrans_segments
import re, subprocess, sys, time
num = lambda k, s: sum(int(x) for x in re.findall(r'\b' + k + r':(\d+)', s))
while True:
    out = subprocess.run(['ss', '-tinH', 'state', 'established', '( dport = :5000 )'],
                         capture_output=True, text=True).stdout
    retr = sum(int(x) for x in re.findall(r'\bretrans:\d+/(\d+)', out))
    print(int(time.time() * 1000), num('bytes_acked', out), num('bytes_received', out), retr, flush=True)
    time.sleep(0.1)
