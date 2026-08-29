#!/usr/bin/env python3
"""Small no-inline-code Python runtime checker for Windows PowerShell launchers."""
import argparse
import importlib
import sys

parser = argparse.ArgumentParser()
parser.add_argument("--modules", nargs="*", default=[])
parser.add_argument("--show-frida-version", action="store_true")
args = parser.parse_args()

for name in args.modules:
    importlib.import_module(name)

print(f"Python {sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}")
if args.show_frida_version:
    frida = importlib.import_module("frida")
    print(f"Frida {frida.__version__}")
