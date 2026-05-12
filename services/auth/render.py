#!/usr/bin/env python3
import argparse
import os
import shutil
import string
from pathlib import Path


def copy_file(src: Path, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dest)


def render_template(src: Path, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(string.Template(src.read_text()).safe_substitute(os.environ))


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

    render_template(src / "config" / "configuration.yml.tpl", dest / "config" / "configuration.yml")
    render_template(src / "config" / "users_database.yml.tpl", dest / "config" / "users_database.yml")


if __name__ == "__main__":
    main()
