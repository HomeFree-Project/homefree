#!/usr/bin/env python3
"""
Strict-overlay YAML merger for Home Assistant config files.

Semantics
---------
- Top-level **dict**: each key in defaults overwrites the matching key in
  target (recursive: nested dicts merge the same way). Target's keys that
  are absent from defaults are preserved.
- Top-level **list of dicts with an `id` field** (e.g. automations.yaml,
  scenes.yaml): entries are matched by `id`. Defaults' entries replace
  same-id target entries. Target entries whose id isn't in defaults are
  preserved.
- Anything else: defaults wins (full replace).

CLI: merge-ha-yaml --target TARGET --defaults DEFAULTS --output OUTPUT

Exit codes: 0 = wrote output; non-zero = parse error (output untouched).
"""
import argparse
import sys

import yaml


def has_id_field(lst):
    return bool(lst) and all(isinstance(x, dict) and "id" in x for x in lst)


def merge(target, defaults):
    if defaults is None:
        return target
    if target is None:
        return defaults
    if isinstance(target, dict) and isinstance(defaults, dict):
        result = dict(target)
        for k, v in defaults.items():
            if (
                k in result
                and isinstance(result[k], (dict, list))
                and isinstance(v, (dict, list))
            ):
                result[k] = merge(result[k], v)
            else:
                result[k] = v
        return result
    if isinstance(target, list) and isinstance(defaults, list):
        if has_id_field(target) and has_id_field(defaults):
            defaults_ids = {x["id"] for x in defaults}
            kept = [x for x in target if x.get("id") not in defaults_ids]
            return kept + defaults
        return defaults
    return defaults


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", required=True)
    ap.add_argument("--defaults", required=True)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()

    try:
        with open(args.defaults) as f:
            defaults = yaml.safe_load(f)
    except (FileNotFoundError, yaml.YAMLError) as e:
        print(f"merge-ha-yaml: failed to parse defaults {args.defaults}: {e}", file=sys.stderr)
        sys.exit(2)

    try:
        with open(args.target) as f:
            target = yaml.safe_load(f)
    except FileNotFoundError:
        target = None
    except yaml.YAMLError as e:
        print(f"merge-ha-yaml: failed to parse target {args.target}: {e}", file=sys.stderr)
        sys.exit(3)

    result = merge(target, defaults)

    with open(args.output, "w") as f:
        yaml.safe_dump(
            result, f, sort_keys=False, default_flow_style=False, allow_unicode=True
        )


if __name__ == "__main__":
    main()
