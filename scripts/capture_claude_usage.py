"""Capture only the subscription quota fields from Claude Code's status line."""

import json
import os
from pathlib import Path
import sys
from tempfile import NamedTemporaryFile
import time

MAX_STATUS_LINE_BYTES = 1024 * 1024


def extract_bucket(bucket):
    if not isinstance(bucket, dict):
        return None
    used = bucket.get("used_percentage")
    if type(used) not in (int, float) or not 0 <= used <= 100:
        return None
    result = {"usedPercentage": used}
    reset = bucket.get("resets_at")
    if type(reset) in (int, float) and 0 < reset <= 253402300799:
        result["resetsAt"] = reset
    return result


def main():
    captured_at = time.time()
    data = sys.stdin.buffer.read(MAX_STATUS_LINE_BYTES + 1)
    if len(data) > MAX_STATUS_LINE_BYTES:
        return 0
    try:
        payload = json.loads(data)
    except (ValueError, RecursionError):
        return 0
    limits = payload.get("rate_limits") if isinstance(payload, dict) else None
    if not isinstance(limits, dict):
        return 0

    snapshot = {}
    for output_key, input_key in (("fiveHour", "five_hour"), ("sevenDay", "seven_day")):
        bucket = extract_bucket(limits.get(input_key))
        if bucket is not None:
            snapshot[output_key] = bucket
    if not snapshot:
        return 0
    snapshot["capturedAt"] = captured_at

    directory = Path.home() / "Library" / "Caches" / "PetQuotaDisplay"
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary_path = None
    try:
        with NamedTemporaryFile(mode="w", encoding="utf-8", dir=directory, delete=False) as output:
            temporary_path = Path(output.name)
            json.dump(snapshot, output)
        os.replace(temporary_path, directory / "claude-usage.json")
    finally:
        if temporary_path is not None and temporary_path.exists():
            temporary_path.unlink()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
