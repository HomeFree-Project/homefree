"""Unit tests for the hardware temperature threshold cascade
(services/hw_buckets.py).

The NVMe both-limits case is the key regression this pins: a Composite sensor
exposing WCTEMP (_max) and CCTEMP (_crit) must use them DIRECTLY as (warn, err)
— NOT margin-subtract from CCTEMP, which would warn below the drive's own
WCTEMP. See docs/agent-notes/nvme-threshold-cascade.md.
"""
from services.hw_buckets import (
    resolve_thresholds,
    resolve_thresholds_with_overrides,
    GPU_DEFAULT_NO_CRIT,
    NVME_DEFAULT_NO_LIMITS,
    CPU_BUCKET_THRESHOLDS,
)
import pytest


@pytest.mark.parametrize(
    "kind,crit,maxc,expected",
    [
        # NVMe with BOTH limits -> use directly: warn=WCTEMP(max), err=CCTEMP(crit).
        ("nvme", 85.0, 82.0, (82, 85)),
        ("nvme", 84.6, 81.4, (81, 85)),  # values are rounded to ints
        # _crit present (CPU/GPU semantics) -> (crit-15, crit-5).
        ("cpu", 100.0, None, (85, 95)),
        ("gpu", 95.0, None, (80, 90)),
        ("nvme", 85.0, None, (70, 80)),  # anomalous nvme crit-only -> margin path
        # _max present, nvme only -> (max, max+3).
        ("nvme", None, 70.0, (70, 73)),
        # No device data -> static class rows.
        ("gpu", None, None, GPU_DEFAULT_NO_CRIT),
        ("nvme", None, None, NVME_DEFAULT_NO_LIMITS),
        ("weird-kind", None, None, CPU_BUCKET_THRESHOLDS["unknown"]),
    ],
)
def test_resolve_thresholds(kind, crit, maxc, expected):
    assert resolve_thresholds(kind, crit, maxc) == expected


def test_nvme_both_limits_must_not_margin_subtract():
    # The exact regression from the agent note: CCTEMP=85, WCTEMP=82.
    assert resolve_thresholds("nvme", 85.0, 82.0) == (82, 85)
    assert resolve_thresholds("nvme", 85.0, 82.0) != (70, 80)


def test_cpu_bucket_path(monkeypatch):
    # With no device limits, a CPU falls to its CPUID-family class bucket.
    monkeypatch.setattr("services.hw_buckets.cpu_bucket", lambda: "amd-zen3plus")
    assert resolve_thresholds("cpu", None, None) == CPU_BUCKET_THRESHOLDS["amd-zen3plus"]


def test_max_only_is_nvme_only(monkeypatch):
    # A bare _max on a CPU is ignored (the _max path is nvme-only) -> bucket.
    monkeypatch.setattr("services.hw_buckets.cpu_bucket", lambda: "intel")
    assert resolve_thresholds("cpu", None, 70.0) == CPU_BUCKET_THRESHOLDS["intel"]


@pytest.mark.parametrize(
    "user_warn,user_err,expected",
    [
        (None, None, (82, 85)),  # both inferred (nvme both-limits -> 82,85)
        (50, None, (50, 85)),    # warn pinned, err inferred
        (None, 90, (82, 90)),    # err pinned, warn inferred
        (40, 90, (40, 90)),      # both pinned
    ],
)
def test_overrides_layer_per_tier(user_warn, user_err, expected):
    assert (
        resolve_thresholds_with_overrides("nvme", 85.0, 82.0, user_warn, user_err)
        == expected
    )
