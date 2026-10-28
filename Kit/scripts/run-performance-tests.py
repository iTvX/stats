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
import shutil
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]
TESTS = ROOT / "Tests/Performance"


def run(products=None, only=None):
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
        executed_tests = 0

        def execute(test_file, suite, sources, extra=(), app=False, label=None, timeout=45):
            nonlocal executed_tests
            if only and not {suite, label}.intersection(only.split(",")):
                return
            count = len(re.findall(r"^    func test\w+\(", test_file.read_text(), re.MULTILINE))
            if not count:
                raise RuntimeError("No performance tests discovered")
            bundle_id = "com.itvx.stats.performance-tests." + (label or suite).lower()
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
                if products:
                    resources = bundle / "Contents/Resources"
                    resources.mkdir(exist_ok=True)
                    shutil.copy2(Path(products) / "Stats.app/Contents/Resources/Assets.car", resources / "Assets.car")
            print(f"Running {count} tests: {label or suite}", flush=True)
            subprocess.run(command + list(extra) + [str(p) for p in sources] +
                           [str(test_file), str(build / "main.swift"), "-o", str(executable)],
                           check=True, env=env, timeout=180)
            try:
                subprocess.run([str(executable)], check=True, env=env, timeout=timeout)
                executed_tests += count
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
        execute(TESTS / "DiscoveryCacheTests.swift", "DiscoveryCacheTests", [ROOT / "Kit/plugins/InvalidatingCache.swift"])
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
            execute(TESTS / "DeferredViewTests.swift", "DeferredViewTests", [],
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
            for module in ["CPU", "RAM", "GPU", "Net", "Disk", "Battery", "Bluetooth"]:
                module_path = ROOT / "Modules" / module
                if module == "Disk":
                    models = module_path / "models.swift"
                else:
                    # Compile the exact production models without starting a
                    # Module (which would create status items and real readers).
                    declaration = "Network" if module == "Net" else module
                    source = (module_path / "main.swift").read_text()
                    models = build / (module + "Models.swift")
                    models.write_text(source.split("public class " + declaration + ": Module", 1)[0])
                    if module == "Net":
                        reader = (module_path / "readers.swift").read_text()
                        mode = re.search(r"    public enum ConnectivityMode: String \{.*?\n    \}", reader, re.DOTALL)
                        if not mode:
                            raise RuntimeError("Network connectivity mode declaration moved")
                        with models.open("a") as output:
                            output.write("\nenum ConnectivityReader {\n" + mode.group(0) + "\n}\n")
                sources = [models, TESTS / "NotificationViewSupport.swift", TESTS / "ModuleViewFixtures.swift"]
                sources += [module_path / (name + ".swift") for name in ["popup", "preview", "settings", "notifications"]
                            if (module_path / (name + ".swift")).is_file()]
                execute(TESTS / "ModuleViewTests.swift", "ModuleViewTests", sources,
                        ["-DTEST_" + module.upper(), "-F", str(products), "-framework", "Kit",
                         "-Xcc", "-I" + str(ROOT / "Kit/lldb"),
                         "-Xlinker", "-rpath", "-Xlinker", str(products)], app=True, label=module)
                if module in ("GPU", "Disk"):
                    suite = "GPUSettingsTests" if module == "GPU" else "DiskViewTests"
                    execute(TESTS / (suite + ".swift"), suite,
                            [models, module_path / "popup.swift", module_path / "settings.swift"],
                            ["-F", str(products), "-framework", "Kit", "-Xcc", "-I" + str(ROOT / "Kit/lldb"),
                             "-Xlinker", "-rpath", "-Xlinker", str(products)], app=True)
            disk_sources = [ROOT / "Modules/Disk" / name for name in ["models.swift", "discovery.swift", "discoveryHelpers.swift"]]
            disk_options = ["-F", str(products), "-framework", "Kit", "-framework", "DiskArbitration",
                            "-Xcc", "-I" + str(ROOT / "Kit/lldb"), "-Xlinker", "-rpath", "-Xlinker", str(products)]
            for module in ("Clock", "Remote"):
                source = (ROOT / "Modules" / module / "main.swift").read_text()
                models = build / (module + "Models.swift")
                tail = "extension Clock {" if module == "Clock" else "extension SystemStats {"
                models.write_text(source.split("public class " + module + ": Module", 1)[0] +
                                  ("enum Clock {}\n" if module == "Clock" else "") + tail + source.split(tail, 1)[1])
                execute(TESTS / (module + "DeferredTests.swift"), module + "DeferredTests", [models] +
                        [ROOT / "Modules" / module / (name + ".swift") for name in ("popup", "settings")],
                        disk_options, app=True)
            execute(TESTS / "SensorDeferredTests.swift", "SensorDeferredTests", [
                ROOT / "Modules/Sensors/settings.swift", ROOT / "Modules/Sensors/notifications.swift",
                ROOT / "Modules/Sensors/values.swift", TESTS / "SensorViewSupport.swift", TESTS / "NotificationViewSupport.swift",
            ], disk_options, app=True)
            env["STATS_DISK_TEST_DIR"] = str(build)
            env["STATS_DISK_TEST_NAME"] = "StatsDiscovery-" + uuid.uuid4().hex[:10]
            try:
                execute(TESTS / "DiskDiscoveryTests.swift", "DiskDiscoveryTests", disk_sources,
                        disk_options, app=True, timeout=90)
            finally:
                # Also detach our own image if a test executable crashes.
                for suffix in ("", "-renamed"):
                    mount = Path("/Volumes") / (env["STATS_DISK_TEST_NAME"] + suffix)
                    if mount.exists():
                        subprocess.run(["/usr/bin/hdiutil", "detach", str(mount)], check=True, timeout=20)
            reader = (ROOT / "Modules/Disk/readers.swift").read_text()
            activity = build / "ActivityReader.swift"
            activity.write_text("import Cocoa\nimport Kit\nimport IOKit.storage\n" +
                                "internal class ActivityReader" + reader.split("internal class ActivityReader", 1)[1].split("\nstruct io", 1)[0])
            rates = build / "DiskRateTests.swift"
            rates.write_text((ROOT / "Tests/Disk.swift").read_text().replace("@testable import Disk", "import Kit"))
            execute(rates, "DiskTests", disk_sources + [activity], disk_options, app=True)
        if not executed_tests:
            raise RuntimeError("No matching test suites")
        print(f"Passed {executed_tests} tests", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--products", type=Path)
    parser.add_argument("--only", help="Run comma-separated suites or modules while iterating")
    args = parser.parse_args()
    run(args.products, args.only)
