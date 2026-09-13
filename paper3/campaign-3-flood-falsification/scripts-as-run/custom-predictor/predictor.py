#!/usr/bin/env python3
"""v3.1 P0.1 datapath-coupled predictor.

Unlike the sklearn control (which never touches the ballast files on the
inference path -- the whole reason v2/v3's "lying pod" observation was
confined to Ready/health signals, not predict), this predictor genuinely
reads ballast bytes on every /predict call and fails loudly (5xx) if that
read errors. Two modes, selected by PREDICTOR_MODE:

  normal        -- serves immediately; each predict reads NUM_SAMPLE_FILES
                   random 64MB ranges from ballast files and returns their
                   sha256 (comparable against a baseline captured on a
                   healthy pod, for CORRECTNESS not just HTTP-code checks).
  startup_load  -- reads every ballast file fully BEFORE opening the port,
                   simulating a dense-LLM weight-load pattern. If that read
                   fails, the process exits nonzero and the port never
                   opens -- the pod never reaches Ready. Answers: for a
                   workload that touches everything at startup, does lazy
                   pulling fail fast (safe) or fail silent (still the "lying
                   pod" problem, just deferred to a different phase)?
"""
import glob
import hashlib
import http.server
import json
import os
import random
import sys
import time

MODEL_PATH = os.environ.get("MODEL_PATH", "/mnt/models")
MODE = os.environ.get("PREDICTOR_MODE", "normal")
NUM_SAMPLE_FILES = int(os.environ.get("NUM_SAMPLE_FILES", "3"))
READ_BYTES = int(os.environ.get("READ_BYTES", str(64 * 1024 * 1024)))
PORT = int(os.environ.get("PORT", "8080"))


def list_ballast_files():
    return sorted(glob.glob(os.path.join(MODEL_PATH, "ballast-*.bin")))


def read_fragment(path, nbytes, seed=None):
    """Read a deterministic-if-seeded or random nbytes range from path."""
    size = os.path.getsize(path)
    n = min(nbytes, size)
    rng = random.Random(seed) if seed is not None else random
    offset = rng.randint(0, max(0, size - n))
    with open(path, "rb") as f:
        f.seek(offset)
        data = f.read(n)
    if len(data) != n:
        raise IOError(f"short read on {path}: got {len(data)} want {n} at offset {offset}")
    return offset, hashlib.sha256(data).hexdigest()


def do_startup_load():
    t0 = time.time()
    files = list_ballast_files()
    print(f"[startup_load] reading {len(files)} ballast files fully before serving", file=sys.stderr, flush=True)
    read_bytes = 0
    try:
        for path in files:
            with open(path, "rb") as f:
                while True:
                    chunk = f.read(64 * 1024 * 1024)
                    if not chunk:
                        break
                    read_bytes += len(chunk)
    except Exception as e:
        print(f"STARTUP_LOAD_FAILED after {read_bytes} bytes / {time.time()-t0:.1f}s: {e}", file=sys.stderr, flush=True)
        sys.exit(1)
    print(f"[startup_load] completed: {read_bytes} bytes in {time.time()-t0:.1f}s -- opening port", file=sys.stderr, flush=True)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _write(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path in ("/healthz", "/") or self.path.startswith("/v1/models/"):
            self._write(200, {"ready": True, "mode": MODE})
        else:
            self._write(404, {"error": "not found"})

    def do_POST(self):
        if not self.path.endswith(":predict"):
            self._write(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length else b"{}"
            payload = json.loads(raw or b"{}")
        except Exception:
            payload = {}
        # optional deterministic seed for baseline-vs-live comparability
        seed = payload.get("seed") if isinstance(payload, dict) else None

        files = list_ballast_files()
        if not files:
            self._write(500, {"error": "no ballast files found under " + MODEL_PATH})
            return
        rng = random.Random(seed) if seed is not None else random
        picks = rng.sample(files, min(NUM_SAMPLE_FILES, len(files)))
        predictions, errors = [], []
        for i, p in enumerate(picks):
            try:
                file_seed = (seed * 1000 + i) if seed is not None else None
                offset, digest = read_fragment(p, READ_BYTES, seed=file_seed)
                predictions.append({"file": os.path.basename(p), "offset": offset, "sha256": digest})
            except Exception as e:
                errors.append({"file": os.path.basename(p), "error": str(e)})
        if errors:
            self._write(503, {"predictions": predictions, "errors": errors})
        else:
            self._write(200, {"predictions": predictions})

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))


if __name__ == "__main__":
    if MODE == "startup_load":
        do_startup_load()
    httpd = http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"serving on :{PORT} mode={MODE} model_path={MODEL_PATH}", file=sys.stderr, flush=True)
    httpd.serve_forever()
