#!/usr/bin/env python3
"""Tests for the Apple Notes launcher plugin. None of them start BetterTouchTool.

  run-tests.py                     engine unit tests on synthetic notes
  run-tests.py --live              read the local Notes library read-only and
                                   print aggregate statistics (no note content)
  run-tests.py --plugin [HEADER]   compile the plugin the way BetterTouchTool does
  run-tests.py --e2e [HEADER] [--screenshots DIR]
                                   compile the plugin, load it in a minimal host
                                   against a synthetic Notes library, exercise the
                                   launcher API and save browser screenshots

HEADER is BetterTouchTool's BTTSwiftPluginHeader.h. It defaults to
$BTT_PLUGIN_HEADER, then to the copy inside /Applications/BetterTouchTool.app.
"""
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile

directory = Path(__file__).resolve().parent
plugin = directory.parent / "AppleNotesLauncherPlugin.swift"
source = plugin.read_text()
engine = source[source.index("// MARK: - Apple Notes Engine"):source.index("// MARK: - End Apple Notes Engine")]


def compile_and_run(fixture_name):
    fixture = (directory / fixture_name).read_text()
    with tempfile.TemporaryDirectory(prefix="btt-applenotes-tests-") as temporary:
        temporary = Path(temporary)
        generated = temporary / fixture_name
        generated.write_text(fixture.replace("// PRODUCTION_ENGINE", engine))
        binary = temporary / generated.stem
        subprocess.run(["xcrun", "swiftc", "-O", "-swift-version", "5", "-parse-as-library",
                        "-module-cache-path", str(temporary / "ModuleCache"),
                        str(generated), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True, timeout=300)


def header_argument(flag):
    index = sys.argv.index(flag)
    if len(sys.argv) > index + 1 and not sys.argv[index + 1].startswith("--"):
        return sys.argv[index + 1]
    return os.environ.get("BTT_PLUGIN_HEADER",
                          "/Applications/BetterTouchTool.app/Contents/Resources/BTTSwiftPluginHeader.h")


def compile_plugin(header, output):
    """Same swiftc invocation as BTTSwiftPluginCompiler.m."""
    sdk = subprocess.run(["xcrun", "--show-sdk-path"], check=True, capture_output=True, text=True).stdout.strip()
    result = subprocess.run([
        "xcrun", "swiftc", "-emit-library", "-module-name", "AppleNotesLauncherPlugin", "-sdk", sdk,
        "-import-objc-header", header,
        "-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup",
        "-Xlinker", "-install_name", "-Xlinker", "@rpath/AppleNotesLauncherPlugin",
        "-module-cache-path", str(output.parent / "ModuleCache"),
        "-o", str(output), str(plugin),
    ], capture_output=True, text=True)
    diagnostics = result.stdout + result.stderr
    # BetterTouchTool rejects bundles whose optional callbacks only nearly match.
    if result.returncode != 0 or "nearly matches optional requirement" in diagnostics:
        print(diagnostics)
        sys.exit("Plugin compilation failed")
    warnings = [line for line in diagnostics.splitlines() if "warning:" in line]
    if warnings:
        print("\n".join(warnings))
    print(f"Plugin compiled ({len(warnings)} warnings)")


def run_end_to_end(header):
    screenshots = None
    if "--screenshots" in sys.argv:
        screenshots = Path(sys.argv[sys.argv.index("--screenshots") + 1]).resolve()
        screenshots.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="btt-applenotes-e2e-") as temporary:
        temporary = Path(temporary)
        dylib = temporary / "AppleNotesLauncherPlugin"
        compile_plugin(header, dylib)

        constants = re.findall(r"extern NSString \* const (\w+);", Path(header).read_text())
        (temporary / "GeneratedPluginConstants.inc").write_text(
            "".join(f'NSString * const {name} = @"{name}";\n' for name in constants))
        host = temporary / "PluginHost"
        subprocess.run(["xcrun", "clang", "-fobjc-arc", "-fmodules", "-framework", "Cocoa", "-Wno-nullability-completeness",
                        "-I", str(Path(header).parent), "-I", str(temporary),
                        str(directory / "PluginHost.m"), "-o", str(host)], check=True)

        home = temporary / "home"
        subprocess.run([sys.executable, str(directory / "make_fixture_library.py"), str(home)], check=True,
                       capture_output=True)
        environment = dict(os.environ, CFFIXED_USER_HOME=str(home))
        subprocess.run([str(host), str(dylib), str(screenshots or temporary)], check=True, env=environment, timeout=120)


if "--plugin" in sys.argv:
    with tempfile.TemporaryDirectory(prefix="btt-applenotes-plugin-") as temporary:
        compile_plugin(header_argument("--plugin"), Path(temporary) / "AppleNotesLauncherPlugin")
elif "--e2e" in sys.argv:
    run_end_to_end(header_argument("--e2e"))
elif "--live" in sys.argv:
    compile_and_run("AppleNotesLiveProbe.swift")
else:
    compile_and_run("AppleNotesEngineTests.swift")
