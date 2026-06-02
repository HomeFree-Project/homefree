# NVMe temperature thresholds — don't apply CPU-style margin to spec values

The sensor-temperature alert source resolves `(warn, err)` per sensor
via `web-platform/backend/services/hw_buckets.py:resolve_thresholds`.
For CPUs and GPUs, the kernel's `temp{N}_crit` is Tjmax (the throttle
point), and the right thing to do is alert *below* it — the cascade
derives `warn = crit - 15, err = crit - 5`. That's CPU semantics.

**That logic is wrong for NVMe.** The NVMe spec defines two distinct
fields on the controller Identify structure:

- `WCTEMP` (Warning Composite Temperature Threshold) — the firmware's
  own "this is too warm" line. Surfaced by the Linux nvme driver as
  `temp1_max` on the Composite sensor.
- `CCTEMP` (Critical Composite Temperature Threshold) — the firmware's
  own throttle/protection line. Surfaced as `temp1_crit`.

These ARE the warn and crit thresholds. The drive engineers chose them
based on the drive's own thermal model. They are NOT Tjmax-like points
to subtract a margin from. WCTEMP and CCTEMP are typically only 3-5 °C
apart (e.g. 81.8 vs 84.8 °C on a Samsung 970), so subtracting a 15 °C
margin from CCTEMP places the warn line well *below* the drive's own
WCTEMP — guaranteeing false-positive warnings under normal warm
operation.

So `resolve_thresholds` has an NVMe-specific branch *before* the
generic `_crit` branch:

```python
if kind == "nvme" and crit_c is not None and max_c is not None:
    return (int(round(max_c)), int(round(crit_c)))
```

Composite (the only sensor that's spec-mandated to carry both) takes
this branch and gets the firmware's exact thresholds. CPU/GPU paths
are unchanged and still use margin subtraction.

## Auxiliary NVMe sensors (Sensor 1 / Sensor 2 / …) are not alert-worthy

A typical NVMe exposes a `Composite` sensor plus auxiliary per-die
thermistors (controller die, NAND array, …). The firmware deliberately
leaves `_max` and `_crit` unset on the auxiliaries — Linux passes
through the spec sentinel `0xFFFF` Kelvin (= ~65 261 °C in milli-C),
which `services/hwmon.py:_read_temp_limit` correctly strips to `None`.

This is the drive saying "I have no published threshold for this
sensor — alert on Composite instead." NAND under sustained writes can
reach 90 °C+ without the drive considering itself in danger, because
the controller integrates that into Composite (the throttling signal)
and Composite stays well under CCTEMP.

`SensorTemperatureSource.evaluate` therefore skips any NVMe sensor
where both `crit_c` and `max_c` come back `None`. The Hardware page's
Sensors panel still surfaces these readings — they're useful diagnostic
data — but they don't drive push alerts.

## Related pattern

Same trap shape as `feedback_no_per_sku_thresholds` / the
`drive-temp` ATA `op_limit_max` issue: a single field on the device
gets repurposed for something it doesn't mean. Always check what the
spec / driver intends a field to be *for*, not just what a number can
be plugged into.

## How to apply

- When wiring a new temperature source, look up what each `temp{N}_*`
  file means for the specific driver before plumbing it into a
  threshold calculation. The semantics differ between coretemp,
  k10temp, amdgpu, nvme, spd5118.
- If a driver publishes both `_max` and `_crit`, ask whether they ARE
  the thresholds (NVMe) or whether they are reference values to derive
  thresholds from (CPU Tjmax). Don't assume the CPU pattern is
  universal — it isn't.
- Sensors with no driver-exposed limits should not drive push alerts.
  Surface them visually; require driver-exposed `_max`/`_crit` before
  firing.

## Related

- `feedback_no_per_sku_thresholds` (auto-memory) — bucket by
  driver/family or read from device; never hardcode a per-SKU value.
- `project_drive_temp_thresholds` (auto-memory) — ATA `op_limit_max` is
  MTBF-optimal, not a warn threshold; mirror trap on the SMART side.
