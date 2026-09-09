#!/usr/bin/env python3
"""Run LLM Serve Dashboard with concurrent HTTP request handling."""

import http.server
import runpy
import sys


if len(sys.argv) != 2:
    raise SystemExit("usage: threaded-dashboard.py /path/to/fleet-metrics.py")

# The upstream dashboard uses HTTPServer, so one slow metrics scrape blocks the
# page and health endpoint. Replace that class before the script imports it.
http.server.HTTPServer = http.server.ThreadingHTTPServer
target = sys.argv[1]
sys.argv = [target]
runpy.run_path(target, run_name="__main__")
