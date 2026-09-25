#!/usr/bin/env python3
"""Build ZAQ's managed Python environment from the fetched crawler lock.

Usage: python3.13 scripts/provision_python.py CRAWLER_DIR VENV_DIR
"""

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import venv


class ProvisionError(Exception):
    """A prerequisite or managed-path safety check failed."""


def require_python_313():
    if sys.implementation.name != "cpython" or sys.version_info[:2] != (3, 13):
        raise ProvisionError("CPython 3.13 is required to provision ZAQ's Python environment")


def require_lock(crawler_dir):
    lock = crawler_dir / "requirements.lock"
    if not lock.is_file():
        raise ProvisionError(f"Crawler lock is missing: {lock}")
    return lock


def require_safe_destination(venv_dir):
    if venv_dir.is_symlink():
        raise ProvisionError(f"Refusing to replace symlink at managed venv path: {venv_dir}")

    if venv_dir.exists():
        python = venv_python(venv_dir)
        if not venv_dir.is_dir() or not (venv_dir / "pyvenv.cfg").is_file() or not python.is_file():
            raise ProvisionError(f"Refusing to replace non-venv path: {venv_dir}")


def venv_python(venv_dir):
    return venv_dir / ("Scripts/python.exe" if os.name == "nt" else "bin/python3")


def provision(crawler_dir, venv_dir):
    require_python_313()
    lock = require_lock(crawler_dir)
    require_safe_destination(venv_dir)

    if venv_dir.exists():
        shutil.rmtree(venv_dir)

    venv_dir.parent.mkdir(parents=True, exist_ok=True)

    try:
        venv.EnvBuilder(with_pip=True).create(venv_dir)
        python = venv_python(venv_dir)
        subprocess.run(
            [str(python), "-m", "pip", "install", "--no-deps", "-r", str(lock)],
            check=True,
        )
        subprocess.run([str(python), "-m", "pip", "check"], check=True)
    except Exception:
        if venv_dir.exists():
            shutil.rmtree(venv_dir)
        raise


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("crawler_dir", type=Path)
    parser.add_argument("venv_dir", type=Path)
    args = parser.parse_args(argv)

    try:
        provision(args.crawler_dir, args.venv_dir)
    except (OSError, subprocess.CalledProcessError, ProvisionError) as error:
        print(f"Python provisioning failed: {error}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
