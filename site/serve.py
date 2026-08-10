#!/usr/bin/env python3
"""Static server for the pitch page, with caching turned off.

python -m http.server sends Last-Modified and no Cache-Control, so browsers
reuse a stale copy without revalidating -- edits appear not to take effect.
"""
import functools
import http.server
import os
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8437
ROOT = os.path.dirname(os.path.abspath(__file__))


class NoCacheHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        super().end_headers()

    def send_header(self, keyword, value):
        # Drop Last-Modified so conditional requests can't produce a 304 either.
        if keyword.lower() == "last-modified":
            return
        super().send_header(keyword, value)


handler = functools.partial(NoCacheHandler, directory=ROOT)
with http.server.ThreadingHTTPServer(("0.0.0.0", PORT), handler) as httpd:
    print(f"serving {ROOT} on 0.0.0.0:{PORT} (no-cache)", flush=True)
    httpd.serve_forever()
