#!/usr/bin/env python3
"""Backend import-all gate (Wave 0a of the test-net plan).

Imports every backend *library* module under the packaged pythonEnv to catch
ImportError / ModuleNotFoundError / SyntaxError / top-level NameError — the
documented runtime-only failure where a missing resolver import only blows up
when that code path is first hit in production.

Run by checks/backend-imports (offline, in the Nix sandbox) and by
scripts/test.sh (only where the deps are available).

Excluded:
  - main.py, schema.py: import `strawberry`, which is NOT in any packaged
    pythonEnv (both the admin and installer services run simple_main.py).
    Dead GraphQL-era code — flagged for removal, not part of the live closure.
  - dashboard_sampler.py, drive_temp_sampler.py: standalone daemon entrypoints,
    excluded until their import-time safety is confirmed (avoid side effects in
    the sandbox). Their pure logic is unit-tested separately (planned).
"""
import importlib
import pathlib
import sys
import traceback

BACKEND = pathlib.Path(__file__).resolve().parent.parent
EXCLUDE = {"main.py", "schema.py", "dashboard_sampler.py", "drive_temp_sampler.py"}


def discover():
    for p in sorted(BACKEND.rglob("*.py")):
        rel = p.relative_to(BACKEND)
        if rel.name in EXCLUDE:
            continue
        # Skip hidden/dunder paths (incl. __pycache__, __init__.py) and the
        # tests dir itself.
        if any(part.startswith((".", "_")) for part in rel.parts):
            continue
        if "tests" in rel.parts:
            continue
        yield ".".join(rel.with_suffix("").parts)


def main() -> int:
    sys.path.insert(0, str(BACKEND))
    failures = []
    count = 0
    for mod in discover():
        count += 1
        try:
            importlib.import_module(mod)
        except BaseException:  # noqa: BLE001 — report every failure, keep going
            failures.append((mod, traceback.format_exc()))
    for mod, tb in failures:
        print(f"IMPORT FAIL: {mod}\n{tb}", file=sys.stderr)
    if failures:
        print(
            f"backend-imports: {len(failures)}/{count} module(s) failed to import",
            file=sys.stderr,
        )
        return 1
    print(f"backend-imports: all {count} module(s) imported OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
