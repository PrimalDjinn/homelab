#!/usr/bin/env python3
import argparse
import shutil
from pathlib import Path


def copy_file(src: Path, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dest)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()

    src = Path(__file__).resolve().parent
    dest = args.output_dir
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)

    for name in ("docker-compose.yml", ".env.example", "start.sh", "README.md"):
        copy_file(src / name, dest / name)


if __name__ == "__main__":
    main()
