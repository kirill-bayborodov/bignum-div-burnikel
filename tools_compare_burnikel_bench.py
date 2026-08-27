#!/usr/bin/env python3
"""Compare bignum-div-burnikel benchmark matrix summaries."""
from __future__ import annotations

import json
import sys
from pathlib import Path


def load(path: Path) -> dict[str, float]:
    data = json.loads(path.read_text(encoding="utf-8"))
    result: dict[str, float] = {}
    for item in data.get("profiles", []):
        if not isinstance(item, dict):
            continue
        profile_id = str(item.get("profile_id", ""))
        mode = str(item.get("mode", ""))
        metrics = item.get("metrics", {})
        value = metrics.get("median_ns_per_call") if isinstance(metrics, dict) else None
        key = f"{profile_id}/{mode}"
        if profile_id and mode and isinstance(value, (int, float)):
            result[key] = float(value)
    return result


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: tools_compare_burnikel_bench.py C11_SUMMARY ASM_SUMMARY", file=sys.stderr)
        return 2
    c11 = load(Path(sys.argv[1]))
    asm = load(Path(sys.argv[2]))
    keys = sorted(set(c11) & set(asm))
    if not keys:
        print("no comparable metrics", file=sys.stderr)
        return 1
    print("profile,c11_ns_per_call,asm_ns_per_call,speedup_c11_over_asm")
    for key in keys:
        speedup = c11[key] / asm[key] if asm[key] else 0.0
        print(f"{key},{c11[key]:.3f},{asm[key]:.3f},{speedup:.3f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
