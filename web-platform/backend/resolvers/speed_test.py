"""
Speed test resolver — on-demand WAN measurement against Cloudflare.

Hits speed.cloudflare.com/__down and /__up directly with httpx (already in
the admin-backend pythonEnv). Runs as a single-slot background test: only
one run at a time, a second start() cancels the first.

Five phases produce download / upload throughput, idle latency / jitter,
and the loaded-latency deltas that drive the Waveform-style bufferbloat
grade. No persistence — results live only in the resolver until the next
run.
"""

import logging
import os
import statistics
import threading
import time
import uuid
from datetime import datetime, timezone
from typing import Optional

import httpx

logger = logging.getLogger(__name__)

CF_BASE = "https://speed.cloudflare.com"

# Parallel-stream throughput config. A single TCP stream on a high-bandwidth
# link is window-limited (BDP) and tops out well below the line speed —
# Cloudflare's and fast.com's own clients run ~6 parallel connections.
# Per stream we loop over fixed-size transfers; aggregate bytes across all
# streams ÷ steady-state elapsed = headline throughput.
THROUGHPUT_STREAMS = 6
THROUGHPUT_WARMUP_S = 0.5     # bytes during slow-start are discarded
DOWNLOAD_STEADY_S = 7.0       # bytes counted for this many seconds after warmup
UPLOAD_STEADY_S = 7.0
# Per-request size for the parallel download phase. Cloudflare's abuse
# heuristics 403 ALL requests when 6 streams concurrently fetch 100 MB
# chunks (their own JS speedtest tops out at 25 MB for the same reason).
# 25 MB × 6 streams comfortably saturates a 1 Gbps line and stays under
# their per-request abuse threshold.
PER_STREAM_DOWNLOAD_BYTES = 25_000_000
PER_STREAM_UPLOAD_BYTES   = 25_000_000

# Modern browser UA — Cloudflare is much friendlier about parallel
# connections to /__down when the requester doesn't look like a bot.
HTTP_HEADERS = {
    "user-agent": "Mozilla/5.0 (X11; Linux x86_64) HomeFree-SpeedTest/1.0",
}

# Latency phase config.
LATENCY_PROBE_COUNT = 20
LATENCY_LOADED_PROBE_COUNT = 10
LATENCY_LOADED_BUDGET_S = 6.0

# Waveform-style bufferbloat grades, keyed on max(loaded_down, loaded_up)
# minus idle median, in milliseconds.
GRADE_THRESHOLDS = [
    (5,   "A+"),
    (30,  "A"),
    (60,  "B"),
    (200, "C"),
    (400, "D"),
]


def _grade(added_ms: float) -> str:
    for threshold, grade in GRADE_THRESHOLDS:
        if added_ms < threshold:
            return grade
    return "F"


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


class _UploadBody:
    """Lazy bytes producer for httpx upload — avoids materialising the full
    payload in RAM. Yields fixed-size chunks of urandom until `size` bytes
    are sent or the cancel/stop flag is set.

    When `counter`/`diag` are supplied, each chunk is tallied AS IT IS SENT
    (right after httpx pulls it from this iterator and writes it to the
    socket), not when the whole POST completes. This is what makes upload
    throughput symmetric with download: on any uplink slower than the
    per-stream completion rate, a single 25 MB POST does not finish inside
    the steady-state window, so completion-only counting left the counter
    at 0 and reported 0.0 Mbps. Counting per chunk reflects the bytes
    actually pushed onto the wire during the window."""

    def __init__(self, size: int, cancel_event: threading.Event, chunk: int = 65536,
                 counter: "Optional[_AtomicBytes]" = None,
                 diag: "Optional[_StreamDiagnostics]" = None,
                 idx: Optional[int] = None,
                 stop_event: Optional[threading.Event] = None):
        self.size = size
        self.cancel_event = cancel_event
        self.chunk = chunk
        self.counter = counter
        self.diag = diag
        self.idx = idx
        self.stop_event = stop_event

    def __iter__(self):
        remaining = self.size
        while remaining > 0:
            if self.cancel_event.is_set() or (
                self.stop_event is not None and self.stop_event.is_set()
            ):
                return
            n = min(self.chunk, remaining)
            yield os.urandom(n)
            remaining -= n
            # Tally AFTER the yield resumes — at that point httpx has taken
            # this chunk and written it to the connection, so it represents
            # bytes genuinely sent (not merely queued for a POST that may
            # never finish within the measurement window).
            if self.counter is not None:
                self.counter.add(n)
            if self.diag is not None and self.idx is not None:
                self.diag.record_bytes(self.idx, n)


class _AtomicBytes:
    """Thread-safe byte counter shared across parallel-stream workers."""

    def __init__(self):
        self._n = 0
        self._lock = threading.Lock()

    def add(self, n: int) -> None:
        with self._lock:
            self._n += n

    def reset(self) -> None:
        with self._lock:
            self._n = 0

    def value(self) -> int:
        with self._lock:
            return self._n


class _StreamDiagnostics:
    """Per-worker diagnostics shared by all stream workers in a phase.
    Bytes received, error count, and the most recent error message — so
    when a phase reports 0 Mbps we can see WHY in the partial state."""

    def __init__(self, n_streams: int):
        self._lock = threading.Lock()
        self.bytes_per_stream = [0] * n_streams
        self.errors_per_stream = [0] * n_streams
        self.last_error_per_stream: list = [None] * n_streams
        self.last_status_per_stream: list = [None] * n_streams

    def record_bytes(self, idx: int, n: int) -> None:
        with self._lock:
            self.bytes_per_stream[idx] += n

    def record_error(self, idx: int, msg: str) -> None:
        with self._lock:
            self.errors_per_stream[idx] += 1
            self.last_error_per_stream[idx] = msg[:200]

    def record_status(self, idx: int, status: int) -> None:
        with self._lock:
            self.last_status_per_stream[idx] = status

    def snapshot(self) -> dict:
        with self._lock:
            return {
                "streams": len(self.bytes_per_stream),
                "bytes_total": sum(self.bytes_per_stream),
                "errors_total": sum(self.errors_per_stream),
                "per_stream": [
                    {
                        "bytes": self.bytes_per_stream[i],
                        "errors": self.errors_per_stream[i],
                        "last_status": self.last_status_per_stream[i],
                        "last_error": self.last_error_per_stream[i],
                    }
                    for i in range(len(self.bytes_per_stream))
                ],
            }


class SpeedTestResolver:
    """Single-slot speed test runner. Class-level state — there is at most
    one test running across the whole admin-api process."""

    _lock = threading.Lock()
    _state: dict = {
        "test_id": None,
        "phase": "idle",
        "progress": 0,
        "partial": {},
        "results": None,
        "error": None,
        "started_at": None,
        "finished_at": None,
    }
    _cancel_event: Optional[threading.Event] = None
    _thread: Optional[threading.Thread] = None

    # ---------------------- public API ----------------------

    @classmethod
    def start(cls) -> dict:
        with cls._lock:
            if cls._thread and cls._thread.is_alive():
                # Cancel the running test before starting a new one.
                if cls._cancel_event:
                    cls._cancel_event.set()
                cls._thread.join(timeout=2.0)

            test_id = uuid.uuid4().hex
            cls._cancel_event = threading.Event()
            cls._state = {
                "test_id": test_id,
                "phase": "starting",
                "progress": 0,
                "partial": {},
                "results": None,
                "error": None,
                "started_at": _now_iso(),
                "finished_at": None,
            }
            cancel_event = cls._cancel_event
            cls._thread = threading.Thread(
                target=cls._run_test,
                args=(cancel_event,),
                daemon=True,
                name=f"speed-test-{test_id[:8]}",
            )
            cls._thread.start()

            return {"test_id": test_id, "started_at": cls._state["started_at"]}

    @classmethod
    def status(cls) -> dict:
        with cls._lock:
            return dict(cls._state)

    @classmethod
    def cancel(cls) -> dict:
        with cls._lock:
            if cls._cancel_event and cls._thread and cls._thread.is_alive():
                cls._cancel_event.set()
                return {"cancelled": True, "test_id": cls._state["test_id"]}
            return {"cancelled": False, "test_id": cls._state["test_id"]}

    # ---------------------- internals ----------------------

    @classmethod
    def _set(cls, **kwargs) -> None:
        with cls._lock:
            cls._state.update(kwargs)

    @classmethod
    def _update_partial(cls, key: str, value) -> None:
        with cls._lock:
            cls._state["partial"][key] = value

    @classmethod
    def _check_cancel(cls, cancel_event: threading.Event) -> bool:
        return cancel_event.is_set()

    @classmethod
    def _run_test(cls, cancel_event: threading.Event) -> None:
        t0 = time.monotonic()
        try:
            # Throughput phase spawns its own clients per worker thread to
            # avoid pool contention; this client is only used for latency
            # probes and the small metadata fetch.
            limits = httpx.Limits(max_keepalive_connections=8, max_connections=16)
            timeout = httpx.Timeout(connect=10.0, read=30.0, write=30.0, pool=10.0)
            # HTTP/1.1 only — pythonEnv doesn't ship the optional `h2` package,
            # and per-sample throughput at our ~100 MB sample sizes isn't
            # materially affected by HTTP/2 multiplexing.
            with httpx.Client(timeout=timeout, limits=limits) as client:
                # ---- Phase 1: idle latency ----
                cls._set(phase="latency_idle", progress=2)
                idle_samples = cls._measure_latency(client, cancel_event, LATENCY_PROBE_COUNT)
                if not idle_samples:
                    raise RuntimeError("no connectivity — idle latency probe returned no samples")
                idle_median = statistics.median(idle_samples)
                jitter = _iqr(idle_samples)
                cls._update_partial("latency", {
                    "idle_ms": round(idle_median, 1),
                    "jitter_ms": round(jitter, 1),
                })
                cls._set(progress=5)
                if cancel_event.is_set():
                    raise _Cancelled()

                # Capture server metadata from the first /__down response.
                server_meta = cls._fetch_server_meta(client)
                if server_meta:
                    cls._update_partial("server", server_meta)

                # ---- Phase 2: download throughput ----
                cls._set(phase="download", progress=8)
                download_mbps = cls._measure_throughput_download(cancel_event)
                cls._update_partial("download_mbps", round(download_mbps, 1))
                cls._set(progress=40)
                if cancel_event.is_set():
                    raise _Cancelled()

                # ---- Phase 3: loaded latency (download) ----
                cls._set(phase="latency_loaded_down", progress=42)
                loaded_down = cls._measure_loaded_latency(
                    client, cancel_event, direction="down",
                )
                cls._update_partial("latency", {
                    **cls._state["partial"].get("latency", {}),
                    "loaded_down_ms": round(loaded_down, 1) if loaded_down is not None else None,
                })
                cls._set(progress=50)
                if cancel_event.is_set():
                    raise _Cancelled()

                # ---- Phase 4: upload throughput ----
                cls._set(phase="upload", progress=52)
                upload_mbps = cls._measure_throughput_upload(cancel_event)
                cls._update_partial("upload_mbps", round(upload_mbps, 1))
                cls._set(progress=85)
                if cancel_event.is_set():
                    raise _Cancelled()

                # ---- Phase 5: loaded latency (upload) ----
                cls._set(phase="latency_loaded_up", progress=87)
                loaded_up = cls._measure_loaded_latency(
                    client, cancel_event, direction="up",
                )
                cls._update_partial("latency", {
                    **cls._state["partial"].get("latency", {}),
                    "loaded_up_ms": round(loaded_up, 1) if loaded_up is not None else None,
                })
                cls._set(progress=95)

                # ---- Grading ----
                loaded_max = max(
                    v for v in (loaded_down, loaded_up) if v is not None
                ) if (loaded_down or loaded_up) else idle_median
                added = max(0.0, loaded_max - idle_median)
                grade = _grade(added)

                results = {
                    "download_mbps": round(download_mbps, 1),
                    "upload_mbps": round(upload_mbps, 1),
                    "latency": {
                        "idle_ms": round(idle_median, 1),
                        "jitter_ms": round(jitter, 1),
                        "loaded_down_ms": round(loaded_down, 1) if loaded_down is not None else None,
                        "loaded_up_ms": round(loaded_up, 1) if loaded_up is not None else None,
                    },
                    "bufferbloat": {
                        "added_ms": round(added, 1),
                        "grade": grade,
                    },
                    "server": cls._state["partial"].get("server"),
                    "duration_s": round(time.monotonic() - t0, 1),
                }
                cls._set(
                    phase="done",
                    progress=100,
                    results=results,
                    finished_at=_now_iso(),
                )

        except _Cancelled:
            cls._set(
                phase="cancelled",
                progress=cls._state.get("progress", 0),
                error="cancelled",
                finished_at=_now_iso(),
            )
        except Exception as e:
            logger.exception("speed test failed")
            cls._set(
                phase="error",
                error=str(e),
                finished_at=_now_iso(),
            )

    # ---------------------- phase implementations ----------------------

    @staticmethod
    def _fetch_server_meta(client: httpx.Client) -> Optional[dict]:
        """Pull the Cloudflare PoP metadata from /__down response headers.
        Cloudflare returns cf-meta-* headers identifying the edge node."""
        try:
            r = client.get(f"{CF_BASE}/__down", params={"bytes": 0})
            h = {k.lower(): v for k, v in r.headers.items()}
            return {
                "city": h.get("cf-meta-city") or h.get("cf-meta-region") or "unknown",
                "iata": h.get("cf-meta-iata") or h.get("cf-meta-colo") or "",
                "ip": h.get("cf-meta-ip") or "",
            }
        except Exception:
            return None

    @staticmethod
    def _measure_latency(
        client: httpx.Client,
        cancel_event: threading.Event,
        count: int,
    ) -> list:
        """Small-body GETs to /__down?bytes=0; record wall-clock RTT.
        Discards the slowest 10% to drop connection-setup outliers."""
        samples = []
        for _ in range(count):
            if cancel_event.is_set():
                break
            t = time.monotonic()
            try:
                r = client.get(f"{CF_BASE}/__down", params={"bytes": 0})
                r.read()
                samples.append((time.monotonic() - t) * 1000.0)
            except Exception:
                continue
        if len(samples) < 4:
            return samples
        samples.sort()
        # drop slowest 10% as outliers (TLS resumption, route changes)
        drop = max(1, len(samples) // 10)
        return samples[:-drop]

    @classmethod
    def _measure_throughput_download(cls, cancel_event: threading.Event) -> float:
        """N parallel GET streams over a fixed wall-clock window. First
        THROUGHPUT_WARMUP_S of bytes are discarded (TCP slow-start), then
        bytes across all streams are accumulated for DOWNLOAD_STEADY_S.
        Returns aggregate Mbps."""
        return cls._parallel_throughput(
            cancel_event=cancel_event,
            stream_fn=cls._download_stream,
            steady_s=DOWNLOAD_STEADY_S,
            progress_start=8, progress_end=40,
            diag_key="download_streams",
        )

    @classmethod
    def _measure_throughput_upload(cls, cancel_event: threading.Event) -> float:
        return cls._parallel_throughput(
            cancel_event=cancel_event,
            stream_fn=cls._upload_stream,
            steady_s=UPLOAD_STEADY_S,
            progress_start=52, progress_end=85,
            diag_key="upload_streams",
        )

    @classmethod
    def _parallel_throughput(
        cls,
        cancel_event: threading.Event,
        stream_fn,
        steady_s: float,
        progress_start: int,
        progress_end: int,
        diag_key: str,
    ) -> float:
        """Run THROUGHPUT_STREAMS workers in parallel. Each worker calls
        stream_fn(idx, counter, diag, stop_event, cancel_event) with its
        own httpx.Client. Diagnostics are surfaced to partial state so
        the UI can show per-stream bytes/errors when a phase returns 0."""
        counter = _AtomicBytes()
        diag = _StreamDiagnostics(THROUGHPUT_STREAMS)
        stop = threading.Event()
        workers = []
        for i in range(THROUGHPUT_STREAMS):
            t = threading.Thread(
                target=stream_fn,
                args=(i, counter, diag, stop, cancel_event),
                daemon=True,
                name=f"speed-test-stream-{i}",
            )
            t.start()
            workers.append(t)

        try:
            # Warmup: let TCP slow-start ramp before we start counting.
            warmup_end = time.monotonic() + THROUGHPUT_WARMUP_S
            while time.monotonic() < warmup_end:
                if cancel_event.is_set():
                    stop.set()
                    return 0.0
                time.sleep(0.05)
            counter.reset()
            t_start = time.monotonic()

            # Steady-state window — tick progress + surface live diagnostics.
            end = t_start + steady_s
            while time.monotonic() < end:
                if cancel_event.is_set():
                    break
                frac = (time.monotonic() - t_start) / steady_s
                cls._set(progress=int(progress_start + min(1.0, frac) * (progress_end - progress_start)))
                cls._update_partial(diag_key, diag.snapshot())
                time.sleep(0.25)

            # Snapshot counter + clock simultaneously, BEFORE telling workers
            # to stop — otherwise drain-time bytes would inflate the read.
            elapsed = max(0.001, time.monotonic() - t_start)
            bytes_seen = counter.value()
            stop.set()
            for w in workers:
                w.join(timeout=3.0)
            # Final diagnostics snapshot.
            cls._update_partial(diag_key, diag.snapshot())

            return (bytes_seen * 8) / 1_000_000 / elapsed
        finally:
            stop.set()

    @classmethod
    def _download_stream(
        cls,
        idx: int,
        counter: "_AtomicBytes",
        diag: "_StreamDiagnostics",
        stop: threading.Event,
        cancel_event: threading.Event,
    ) -> None:
        """Worker: open one GET stream after another, feeding actually
        received bytes into the shared counter until stop or cancel.
        Records HTTP status + exception messages to diagnostics so the
        UI can surface them when bytes_total is 0."""
        timeout = httpx.Timeout(connect=10.0, read=30.0, write=30.0, pool=10.0)
        try:
            with httpx.Client(timeout=timeout, headers=HTTP_HEADERS) as c:
                while not stop.is_set() and not cancel_event.is_set():
                    try:
                        with c.stream("GET", f"{CF_BASE}/__down",
                                      params={"bytes": PER_STREAM_DOWNLOAD_BYTES}) as r:
                            diag.record_status(idx, r.status_code)
                            if r.status_code != 200:
                                # Pull a tiny prefix of the body for diagnostics.
                                body_prefix = b""
                                for chunk in r.iter_bytes(chunk_size=256):
                                    body_prefix = chunk[:256]
                                    break
                                msg = f"HTTP {r.status_code}: {body_prefix!r}"
                                diag.record_error(idx, msg)
                                logger.warning("download stream %d %s", idx, msg)
                                time.sleep(0.5)
                                continue
                            for chunk in r.iter_bytes(chunk_size=65536):
                                n = len(chunk)
                                counter.add(n)
                                diag.record_bytes(idx, n)
                                if stop.is_set() or cancel_event.is_set():
                                    return
                    except Exception as e:
                        diag.record_error(idx, f"{type(e).__name__}: {e}")
                        logger.warning("download stream %d error: %s", idx, e)
                        if stop.is_set() or cancel_event.is_set():
                            return
        except Exception as e:
            diag.record_error(idx, f"client init: {type(e).__name__}: {e}")
            logger.warning("download stream %d client init: %s", idx, e)

    @classmethod
    def _upload_stream(
        cls,
        idx: int,
        counter: "_AtomicBytes",
        diag: "_StreamDiagnostics",
        stop: threading.Event,
        cancel_event: threading.Event,
    ) -> None:
        """Worker: POST after POST. Bytes are tallied by the body iterator
        AS THEY ARE SENT (see _UploadBody) rather than once per completed
        POST — otherwise an uplink too slow to finish a 25 MB POST inside
        the steady-state window leaves the counter at 0 and reports 0.0
        Mbps. Passing `stop` into the body also lets an in-flight POST stop
        producing the instant the window ends, so the worker joins
        promptly."""
        timeout = httpx.Timeout(connect=10.0, read=30.0, write=30.0, pool=10.0)
        try:
            with httpx.Client(timeout=timeout, headers=HTTP_HEADERS) as c:
                while not stop.is_set() and not cancel_event.is_set():
                    try:
                        body = _UploadBody(
                            PER_STREAM_UPLOAD_BYTES, cancel_event,
                            counter=counter, diag=diag, idx=idx, stop_event=stop,
                        )
                        r = c.post(
                            f"{CF_BASE}/__up",
                            content=iter(body),
                            headers={"content-length": str(PER_STREAM_UPLOAD_BYTES),
                                     "content-type": "application/octet-stream"},
                        )
                        r.read()
                        diag.record_status(idx, r.status_code)
                        if r.status_code >= 400:
                            diag.record_error(idx, f"HTTP {r.status_code}")
                            logger.warning("upload stream %d HTTP %s", idx, r.status_code)
                            time.sleep(0.5)
                            continue
                        # Bytes already tallied incrementally by the body
                        # iterator as they were written to the socket.
                    except Exception as e:
                        if stop.is_set() or cancel_event.is_set():
                            # Expected at the window end: stopping the body
                            # mid-stream sends fewer than the declared
                            # content-length, which raises here. Not a real
                            # error — the bytes sent were already counted.
                            return
                        diag.record_error(idx, f"{type(e).__name__}: {e}")
                        logger.warning("upload stream %d error: %s", idx, e)
        except Exception as e:
            diag.record_error(idx, f"client init: {type(e).__name__}: {e}")
            logger.warning("upload stream %d client init: %s", idx, e)

    @classmethod
    def _measure_loaded_latency(
        cls,
        client: httpx.Client,
        cancel_event: threading.Event,
        direction: str,
    ) -> Optional[float]:
        """Fire latency probes while a saturating stream runs in another
        thread. Returns the median of the loaded RTTs in ms, or None if
        every probe failed."""
        stop = threading.Event()
        deadline = time.monotonic() + LATENCY_LOADED_BUDGET_S

        def saturate():
            # Use a fresh client so the probe client's connection pool isn't
            # contended for headers — the saturating stream takes its own
            # connection.
            sat_timeout = httpx.Timeout(connect=10.0, read=30.0, write=30.0, pool=10.0)
            try:
                with httpx.Client(timeout=sat_timeout) as sat:
                    while not stop.is_set() and not cancel_event.is_set():
                        try:
                            if direction == "down":
                                with sat.stream("GET", f"{CF_BASE}/__down",
                                                params={"bytes": 100_000_000}) as r:
                                    for _ in r.iter_bytes(chunk_size=65536):
                                        if stop.is_set() or cancel_event.is_set():
                                            return
                            else:
                                body = _UploadBody(25_000_000, cancel_event)
                                sat.post(
                                    f"{CF_BASE}/__up",
                                    content=iter(body),
                                    headers={"content-length": "25000000",
                                             "content-type": "application/octet-stream"},
                                ).read()
                        except Exception:
                            return
            except Exception:
                return

        worker = threading.Thread(target=saturate, daemon=True,
                                  name=f"speed-test-sat-{direction}")
        worker.start()
        # let the stream ramp up before sampling
        time.sleep(0.5)

        samples = []
        while (len(samples) < LATENCY_LOADED_PROBE_COUNT
               and time.monotonic() < deadline
               and not cancel_event.is_set()):
            t = time.monotonic()
            try:
                r = client.get(f"{CF_BASE}/__down", params={"bytes": 0})
                r.read()
                samples.append((time.monotonic() - t) * 1000.0)
            except Exception:
                pass

        stop.set()
        worker.join(timeout=2.0)
        if not samples:
            return None
        return statistics.median(samples)


def _iqr(values: list) -> float:
    """Inter-quartile range as a jitter proxy. Robust to a single bad sample."""
    if len(values) < 4:
        return 0.0
    s = sorted(values)
    q1 = s[len(s) // 4]
    q3 = s[(3 * len(s)) // 4]
    return q3 - q1


class _Cancelled(Exception):
    pass
