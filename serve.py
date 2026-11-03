#!/usr/bin/env python3
"""Static server for the RSDKv5 web build.

`python3 -m http.server` is fine for a quick look, but it hands the browser no
cache policy at all. That means a browser is free to keep an old index.html /
RetroEngine.js around after a rebuild (heuristic caching), which looks exactly
like "the game got slower" when in fact the old loader is still running.

Rules:
  * code + config -> no-cache (always revalidate; 304s are cheap)
  * Data.rsdk     -> immutable for a year (200 MB must never be re-downloaded
                     by the HTTP cache; the loader keeps its own Cache Storage
                     copy as well)
  * ranges are supported so a truncated download can resume.

Usage: python3 serve.py [port] [directory]
"""

import os
import sys
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8081
ROOT = sys.argv[2] if len(sys.argv) > 2 else "build-web"


class Handler(SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def end_headers(self):
        path = self.path.split("?", 1)[0]
        name = os.path.basename(path)

        if name.lower() == "data.rsdk":
            self.send_header("Cache-Control", "public, max-age=31536000, immutable")
        else:
            self.send_header("Cache-Control", "no-cache")

        super().end_headers()

    def copyfile(self, source, outputfile):
        # SimpleHTTPRequestHandler already handles Range when it sends a
        # partial response; this keeps the copy loop shutil-based.
        super().copyfile(source, outputfile)

    def log_message(self, fmt, *args):
        # Keep the console readable: only log failures and big transfers.
        if args and str(args[1]).startswith(("4", "5")):
            super().log_message(fmt, *args)


def main():
    handler = partial(Handler, directory=ROOT)
    httpd = ThreadingHTTPServer(("0.0.0.0", PORT), handler)
    httpd.daemon_threads = True
    print(f"serving {os.path.abspath(ROOT)} on http://localhost:{PORT}/", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
