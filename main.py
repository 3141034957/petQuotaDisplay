#!/usr/bin/env python3
"""Convenient launcher for the native macOS quota orb."""

from __future__ import annotations

import platform
import subprocess
import sys
from pathlib import Path


def main() -> int:
    if platform.system() != "Darwin":
        print("PetQuotaDisplay currently requires macOS.", file=sys.stderr)
        return 1

    repository = Path(__file__).resolve().parent
    command = [
        "swift",
        "run",
        "--scratch-path",
        str(repository / ".build"),
        "PetQuotaDisplay",
    ]
    try:
        return subprocess.call(command, cwd=repository)
    except FileNotFoundError:
        print("未找到 Swift。请先安装 Xcode Command Line Tools。", file=sys.stderr)
        return 127
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
