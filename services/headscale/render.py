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


def copy_tree(src: Path, dest: Path) -> None:
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(src, dest)


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

    copy_tree(src / "init", dest / "init")
    copy_file(src / "config" / "dns_records.json", dest / "dns_records.json")
    render_template(src / ".env.tpl", dest / ".env")
    copy_file(src / "config" / "headscale.yaml.tpl", dest / "headscale_config.yml")
    copy_file(src / "config" / "headplane.yaml.tpl", dest / "headplane_config.yml")


if __name__ == "__main__":
    main()
