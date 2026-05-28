"""
Class-level hardware bucketing for sensor temperature thresholds.

The sensor-temperature alert source asks the kernel for each sensor's
driver-reported limit first (`temp{N}_crit` / `temp{N}_max` in hwmon).
That works for Intel `coretemp`, NVMe controllers, and discrete GPUs.
It does NOT work for:

  * AMD `k10temp` / `zenpower` — the driver intentionally never exposes
    Tjmax (AMD keeps per-SKU thermal limits in microcode rather than in
    a register the driver reads).
  * Integrated GPUs (amdgpu on APUs, i915) — typically expose no
    `_crit` either.

When the driver hides the limit, we still need a sensible default. The
honest answer is "I don't know this exact SKU's Tjmax." The next best
answer — and what `inxi`, `lshw`, and similar tools do — is bucket the
silicon by CPUID family (or PCI vendor for GPUs) and use a published
Tjmax range for that *class*. Every row in the table below is
class-level, not SKU-level (see `feedback_no_per_sku_thresholds`):
shared across many HomeFree deployments, principled rather than tuned
to one box.

Margins for deriving warn/err from a known Tjmax:

  warn = Tjmax - 15
  err  = Tjmax - 5

Mirrors the disk-temperature pattern's "limit - 10" convention — keep
broad headroom on the warn line so normal boost spikes don't fire, and
a small but non-trivial margin on err so a real cooling failure trips
before the chip starts throttling. Adjusting the margins later is a
single-line change.
"""

import logging
from functools import lru_cache
from pathlib import Path
from typing import Optional, Tuple

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------
# Threshold tables (the only "hardcoded data" — class-level, not SKU)
# ---------------------------------------------------------------------

# (warn_c, err_c) per CPU bucket — derived from documented Tjmax ranges
# for each architectural family, then trimmed by (15, 5) margins.
CPU_BUCKET_THRESHOLDS: dict = {
    # Intel typically exposes _crit via coretemp, so this row is the
    # belt-and-braces fallback for the rare case where coretemp doesn't
    # surface a value (very old hardware, custom kernels). Tjmax ~100.
    "intel":        (85, 95),

    # AMD Zen 3 / 4 / 5 — Ryzen 5xxx / 7xxx / 8xxx / 9xxx desktop,
    # Phoenix / Hawk Point / Rembrandt mobile APUs, modern EPYC. Tjmax
    # 95-100 °C across the family.
    "amd-zen3plus": (85, 95),

    # AMD Zen 1 / Zen+ / Zen 2 — Ryzen 1xxx / 2xxx / 3xxx desktop,
    # first-gen EPYC. Tjmax 90-95 °C.
    "amd-zen12":    (80, 90),

    # AMD pre-Zen (FX, A-series) and anything family <0x17. Conservative.
    "amd-other":    (75, 85),

    # ARM has no industry-wide Tjmax convention; SBC SoCs vary wildly.
    "arm-other":    (75, 85),

    # Truly unknown silicon — conservative default that matches the
    # pre-cascade behaviour, so a never-seen vendor doesn't suddenly
    # alert at a tighter threshold than it used to.
    "unknown":      (75, 85),
}

# GPU fallback when the driver exposes no `_crit`. iGPUs are the
# common case; discrete cards almost always report `_crit` so the
# cascade never reaches this row for them.
GPU_DEFAULT_NO_CRIT: Tuple[int, int] = (85, 90)

# NVMe controller fallback when the driver exposes neither `_crit`
# nor `_max`. The standard NVMe identify mandates these fields, so
# this row is purely defensive.
NVME_DEFAULT_NO_LIMITS: Tuple[int, int] = (70, 80)

# Margins applied when deriving thresholds from a device-reported
# `_crit`. (See module docstring for rationale.)
CRIT_WARN_MARGIN_C = 15
CRIT_ERR_MARGIN_C = 5

# Margin applied when deriving an err threshold from a device-reported
# `_max` (NVMe-only path). `_max` is itself "above this degrades
# longevity," so we use it as the warn line directly and only need a
# small bump for err.
MAX_ERR_BUMP_C = 3


# ---------------------------------------------------------------------
# CPU bucket detection
# ---------------------------------------------------------------------

_PROC_CPUINFO = Path("/proc/cpuinfo")


@lru_cache(maxsize=1)
def cpu_bucket() -> str:
    """Classify the host CPU into one of the keys of
    `CPU_BUCKET_THRESHOLDS`. Cached for the process lifetime — CPU
    identity doesn't change while we're running.
    """
    vendor: Optional[str] = None
    family: Optional[int] = None
    try:
        with _PROC_CPUINFO.open() as f:
            for line in f:
                if vendor is not None and family is not None:
                    break
                k, _, v = line.partition(":")
                k = k.strip()
                v = v.strip()
                if k == "vendor_id" and vendor is None:
                    vendor = v
                elif k == "cpu family" and family is None:
                    try:
                        family = int(v)
                    except ValueError:
                        pass
                elif k == "CPU implementer" and vendor is None:
                    # ARM /proc/cpuinfo has no `vendor_id`; "CPU
                    # implementer" is the closest equivalent (Arm Ltd
                    # = 0x41, etc.). Presence alone signals ARM.
                    vendor = "ARM"
    except OSError as e:
        logger.debug("hw_buckets: cpuinfo read failed: %s", e)

    if vendor == "GenuineIntel":
        return "intel"
    if vendor == "AuthenticAMD":
        # Family 0x17 = Zen / Zen+ / Zen 2
        # Family 0x19 = Zen 3 / Zen 4
        # Family 0x1A = Zen 5
        if family in (0x19, 0x1A):
            return "amd-zen3plus"
        if family == 0x17:
            return "amd-zen12"
        return "amd-other"
    if vendor == "ARM":
        return "arm-other"
    return "unknown"


# ---------------------------------------------------------------------
# Per-sensor threshold cascade
# ---------------------------------------------------------------------

def resolve_thresholds(
    kind: str,
    crit_c: Optional[float],
    max_c: Optional[float],
) -> Tuple[int, int]:
    """Resolve (warn_c, err_c) for a single sensor reading WITHOUT user
    overrides — the inferred-from-hardware view.

    Cascade:
      1. `_crit` from the driver — derive (crit-15, crit-5).
      2. `_max` from the driver (NVMe only) — derive (max, max+3).
      3. Class bucket: CPU goes through `cpu_bucket()`; GPU and NVMe
         fall to their static no-device-data rows.
      4. Truly unknown kind — same conservative fallback as the CPU
         "unknown" row.

    Returned values are ints (the existing source code compares ints
    everywhere; rounding here keeps the message strings tidy).
    """
    if crit_c is not None:
        return (
            int(round(crit_c)) - CRIT_WARN_MARGIN_C,
            int(round(crit_c)) - CRIT_ERR_MARGIN_C,
        )
    if max_c is not None and kind == "nvme":
        m = int(round(max_c))
        return (m, m + MAX_ERR_BUMP_C)

    if kind == "cpu":
        return CPU_BUCKET_THRESHOLDS[cpu_bucket()]
    if kind == "gpu":
        return GPU_DEFAULT_NO_CRIT
    if kind == "nvme":
        return NVME_DEFAULT_NO_LIMITS
    return CPU_BUCKET_THRESHOLDS["unknown"]


def resolve_thresholds_with_overrides(
    kind: str,
    crit_c: Optional[float],
    max_c: Optional[float],
    user_warn: Optional[int],
    user_err: Optional[int],
) -> Tuple[int, int]:
    """Same cascade as `resolve_thresholds`, with the user's per-class
    override layered on top per-tier — warn and err are independent so
    a user can pin one and let the other infer. Used by both the
    sensor-temperature alert source and the Hardware page resolver so
    the chart threshold lines and the alert thresholds always agree.
    """
    inferred_warn, inferred_err = resolve_thresholds(kind, crit_c, max_c)
    return (
        user_warn if user_warn is not None else inferred_warn,
        user_err if user_err is not None else inferred_err,
    )
