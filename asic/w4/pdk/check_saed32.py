"""核对 W4 所需的本地 SAED32 EDK 文件。"""

import os
from pathlib import Path
import sys


def main():
    root = os.environ.get("SAED32_EDK")
    if not root or not Path(root).is_dir():
        sys.exit("Set SAED32_EDK to the local EDK root directory.")

    manifest = Path(__file__).with_name("saed32") / "files.txt"
    paths = manifest.read_text(encoding="utf-8").splitlines()
    missing = []
    for relative in paths:
        try:
            with (Path(root) / relative).open("rb") as view:
                if not view.read(1):
                    missing.append(relative)
        except OSError:
            missing.append(relative)

    if missing:
        sys.exit("Missing, empty, or unreadable SAED32 files:\n" + "\n".join(missing))
    print(f"SAED32 PDK check passed: {len(paths)} files.")


if __name__ == "__main__":
    main()
