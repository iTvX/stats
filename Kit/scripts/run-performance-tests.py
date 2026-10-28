#!/usr/bin/env python3
"""Test production sampling, history, storage and widgets without launching Stats.

Run without arguments for isolated core tests. Pass --products pointing at
the Release build products to also test the actual Kit.framework views.
"""
import argparse
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
TESTS = ROOT / "Tests/Performance"


def run(products=None):
    platform = Path(subprocess.check_output(
        ["xcrun", "--sdk", "macosx", "--show-sdk-platform-path"], text=True).strip())
    frameworks = platform / "Developer/Library/Frameworks"
    private_frameworks = platform / "Developer/Library/PrivateFrameworks"
    libraries = platform / "Developer/usr/lib"
    with tempfile.TemporaryDirectory(prefix="stats-performance-tests-") as directory:
        build = Path(directory)
        env = dict(os.environ, SWIFT_MODULECACHE_PATH=str(build / "cache"))
        fixture = build / "command-fixture"
        subprocess.run(["xcrun", "clang", "-O2", str(TESTS / "CommandFixture.c"), "-o", str(fixture)], check=True, timeout=60)
        env["STATS_COMMAND_FIXTURE"] = str(fixture)
        command = ["xcrun", "swiftc", "-swift-version", "5", "-g",
                   "-module-cache-path", str(build / "cache"),
                   "-I", str(libraries), "-L", str(libraries),
                   "-Xlinker", "-rpath", "-Xlinker", str(libraries),
                   "-F", str(frameworks), "-Xlinker", "-rpath", "-Xlinker", str(frameworks),
                   "-Xlinker", "-rpath", "-Xlinker", str(private_frameworks)]

        def execute(test_file, suite, sources, extra=(), app=False):
            count = len(re.findall(r"^    func test\w+\(", test_file.read_text(), re.MULTILINE))
            if not count:
                raise RuntimeError("No performance tests discovered")
            bundle_id = "com.itvx.stats.performance-tests." + suite.lower()
            setup = (
                "import AppKit\n"
                f'let testDomain = "{bundle_id}"\n'
                "precondition(Bundle.main.bundleIdentifier == testDomain)\n"
                "UserDefaults.standard.removePersistentDomain(forName: testDomain)\n"
                "NSApplication.shared.setActivationPolicy(.prohibited)\n"
            ) if app else ""
            cleanup = "UserDefaults.standard.removePersistentDomain(forName: testDomain)\n" if app else ""
            (build / "main.swift").write_text(
                "import XCTest\nimport Darwin\n" + setup +
                f"let suite = {suite}.defaultTestSuite\nsuite.run()\n" + cleanup +
                f"exit(suite.testRun?.hasSucceeded == true && suite.testRun?.executionCount == {count} ? 0 : 1)\n")
            executable = build / suite
            if app:
                bundle = build / "PerformanceTests.app"
                executable = bundle / "Contents/MacOS/PerformanceTests"
                executable.parent.mkdir(parents=True, exist_ok=True)
                (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
                    "CFBundleIdentifier": bundle_id,
                    "CFBundleExecutable": "PerformanceTests", "CFBundlePackageType": "APPL",
                    "LSBackgroundOnly": True,
                }))
            print(f"Running {count} tests: {suite}", flush=True)
            subprocess.run(command + list(extra) + [str(p) for p in sources] +
                           [str(test_file), str(build / "main.swift"), "-o", str(executable)],
                           check=True, env=env, timeout=180)
            try:
                subprocess.run([str(executable)], check=True, env=env, timeout=45)
            finally:
                if app:
                    subprocess.run(["/usr/bin/defaults", "delete", bundle_id],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)

        execute(TESTS / "RuntimeTests.swift", "PerformanceTests", [
            ROOT / "Kit/plugins/ReaderWorkQueue.swift", ROOT / "Kit/plugins/Repeater.swift",
            ROOT / "Kit/module/reader.swift", ROOT / "Kit/Widgets/MiniValuePresentation.swift",
            TESTS / "Support.swift",
        ])
        execute(TESTS / "CommandTests.swift", "CommandTests", [
            ROOT / "Kit/plugins/CommandRunner.swift", ROOT / "Kit/module/commandReader.swift",
            ROOT / "Kit/plugins/ReaderWorkQueue.swift", ROOT / "Kit/plugins/Repeater.swift",
            ROOT / "Kit/module/reader.swift", TESTS / "Support.swift",
        ])
        execute(TESTS / "EnergyTests.swift", "EnergyTests", [ROOT / "Kit/plugins/EnergySampling.swift"])
        execute(TESTS / "ChartHistoryTests.swift", "ChartHistoryTests", [
            ROOT / "Kit/plugins/ChartHistoryBuffer.swift",
        ])
        execute(TESTS / "LineChartDataTests.swift", "LineChartDataTests", [
            ROOT / "Kit/plugins/ChartHistoryBuffer.swift", ROOT / "Kit/plugins/LineChartData.swift",
        ])
        execute(TESTS / "IOServiceTests.swift", "IOServiceTests", [
            ROOT / "Kit/plugins/IOServiceProperties.swift",
        ])
        execute(TESTS / "StorageTests.swift", "StorageTests", [
            ROOT / "Kit/plugins/DB.swift", TESTS / "StorageSupport.swift",
        ])
        if products:
            products = Path(products).resolve()
            if not (products / "Kit.framework").is_dir():
                raise RuntimeError("Build Kit.framework before running widget tests")
            execute(TESTS / "WidgetTests.swift", "WidgetPerformanceTests", [],
                    ["-F", str(products), "-framework", "Kit",
                     "-Xcc", "-I" + str(ROOT / "Kit/lldb"),
                     "-Xlinker", "-rpath", "-Xlinker", str(products)], app=True)
            execute(TESTS / "SensorViewTests.swift", "SensorViewTests", [
                ROOT / "Modules/Sensors/popup.swift", ROOT / "Modules/Sensors/values.swift",
                TESTS / "SensorViewSupport.swift",
            ], ["-F", str(products), "-framework", "Kit",
                "-Xcc", "-I" + str(ROOT / "Kit/lldb"),
                "-Xlinker", "-rpath", "-Xlinker", str(products)], app=True)
            execute(TESTS / "SamplingIntegrationTests.swift", "SamplingIntegrationTests", [],
                    ["-F", str(products), "-framework", "Kit", "-framework", "RAM",
                     "-Xcc", "-I" + str(ROOT / "Kit/lldb"),
                     "-Xlinker", "-rpath", "-Xlinker", str(products)], app=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--products", type=Path)
    run(parser.parse_args().products)
