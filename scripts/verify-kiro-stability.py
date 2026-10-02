#!/usr/bin/env python3
"""Run production-code regression checks on Macs with Command Line Tools only.

The standard XCTest suite still requires Xcode. This harness links the actual
debug production objects, excluding only the application's main entry point.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
subprocess.run(["swift", "build"], cwd=root / "src", check=True)
build = (root / "src/.build/debug").resolve()
objects = [str(p) for target in ["CLIProxyMenuBar", "Yams", "CYaml"]
           for p in (build / (target + ".build")).rglob("*.o") if p.name != "main.swift.o"]
with tempfile.TemporaryDirectory(prefix="viberouter-verification-") as directory:
    binary = Path(directory) / "kiro-stability"
    subprocess.run([
        "swiftc", "-parse-as-library", "-I", str(build / "Modules"),
        "-I", str(root / "src/.build/checkouts/Yams/Sources/CYaml/include"),
        "-F", str(build), "-framework", "Sparkle", "-Xlinker", "-rpath", "-Xlinker", str(build),
        str(root / "src/Verification/KiroStabilitySpec.swift"), *objects, "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], cwd=root, check=True)
