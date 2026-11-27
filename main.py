#!/usr/bin/env python3
"""Launch the native PetQuota client for the current desktop."""

from __future__ import annotations

import platform
import subprocess
import sys
from pathlib import Path


def main() -> int:
    repository = Path(__file__).resolve().parent
    system = platform.system()
    if system == "Windows":
        command = ["dotnet", "run", "--project", str(repository / "windows/PetQuota/PetQuota.csproj"), "--", *sys.argv[1:]]
        missing_tool = "未找到 .NET 10 SDK。也可以直接运行 Windows 发布包内的 PetQuota.exe。"
    elif system == "Darwin":
        command = ["swift", "run", "--scratch-path", str(repository / ".build"), "PetQuotaDisplay", *sys.argv[1:]]
        missing_tool = "未找到 Swift。请先安装 Xcode Command Line Tools。"
    else:
        print("PetQuotaDisplay supports Windows and macOS.", file=sys.stderr)
        return 1
    try:
        return subprocess.call(command, cwd=repository)
    except FileNotFoundError:
        print(missing_tool, file=sys.stderr)
        return 127
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
