#!/usr/bin/env python3
"""Phone-local, single-run titlebar fixture; bounded even if its caller disappears."""
import functools
from http.server import HTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
import sys
import time

root = Path(sys.argv[1])
with HTTPServer(('127.0.0.1', 0), functools.partial(SimpleHTTPRequestHandler, directory=str(root))) as server:
    server.timeout = 0.25
    (root / 'port').write_text(str(server.server_port))
    print(f'ready phone-loopback port={server.server_port} root={root}', flush=True)
    deadline = time.monotonic() + 240
    while time.monotonic() < deadline and not (root / 'stop').exists():
        server.handle_request()
print('server stopped', flush=True)
(root / 'done').touch()
