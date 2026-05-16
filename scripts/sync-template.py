#!/usr/bin/env python3
"""
Regenerate /etc/nixos/homefree-configuration.nix from
install.py's HOMEFREE_CONFIG_TEMPLATE.

The template is rendered once at install time; without this step
any new JSON→Nix bindings added to install.py would never reach a
deployed system. This script preserves the install-time username
and hashedPassword by extracting them from the existing file.

Usage: sync-template.py <install.py path> <homefree-configuration.nix path>

Output:
  stderr: a single JSON status line ({"action": "noop"|"regenerate"|"skip", ...})
  stdout: rendered file content, only when action == "regenerate"

The caller writes stdout to the target path if non-empty.
"""

import json
import re
import sys
from pathlib import Path


def extract_template(install_py_path: Path) -> str:
    src = install_py_path.read_text()
    m = re.search(r'HOMEFREE_CONFIG_TEMPLATE = """(.+?)"""', src, re.DOTALL)
    if not m:
        raise RuntimeError(f"HOMEFREE_CONFIG_TEMPLATE not found in {install_py_path}")
    return m.group(1)


def extract_subs(existing_nix: str) -> dict:
    m = re.search(
        r'users\.users\.([A-Za-z0-9_-]+)\s*=\s*\{\s*hashedPassword\s*=\s*"([^"]*)"',
        existing_nix,
    )
    if not m:
        raise RuntimeError(
            "Could not extract username/hashedPassword from existing "
            "homefree-configuration.nix"
        )
    return {"username": m.group(1), "hashed_password": m.group(2)}


def render(template: str, subs: dict) -> str:
    out = template
    for key, val in subs.items():
        out = out.replace(f"@@{key}@@", val)
    return out


def emit_status(payload: dict) -> None:
    sys.stderr.write(json.dumps(payload) + "\n")


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: sync-template.py <install.py> <homefree-configuration.nix>", file=sys.stderr)
        return 1

    install_py = Path(sys.argv[1])
    target = Path(sys.argv[2])

    if not install_py.exists():
        emit_status({"action": "error", "reason": f"install.py not found: {install_py}"})
        return 1

    if not target.exists():
        emit_status({"action": "skip", "reason": "target does not exist"})
        return 0

    try:
        existing = target.read_text()
        template = extract_template(install_py)
        subs = extract_subs(existing)
        rendered = render(template, subs)
    except Exception as e:
        emit_status({"action": "error", "reason": str(e)})
        return 1

    if rendered == existing:
        emit_status({"action": "noop"})
        return 0

    leftover = re.findall(r"@@([a-z_]+)@@", rendered)
    if leftover:
        emit_status({
            "action": "error",
            "reason": f"unresolved placeholders: {sorted(set(leftover))}",
        })
        return 2

    emit_status({"action": "regenerate", "username": subs["username"]})
    sys.stdout.write(rendered)
    return 0


if __name__ == "__main__":
    sys.exit(main())
