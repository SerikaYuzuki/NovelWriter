#!/usr/bin/env python3
"""Run only the checks that the current change can affect (D-086 中ぐらいの検証).

The changed files are the diff from the merge base with the base branch plus
uncommitted and untracked files.  Each path selects the narrowest checks that
cover it; `./Scripts/check.sh` stays the 重たい検証 for shared foundations.

    ./Scripts/check-changed.py --dry-run        # show the plan only
    ./Scripts/check-changed.py                  # run it
    ./Scripts/check-changed.py --base HEAD~1    # compare with another base
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
import time
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent

# Retired copies kept beside the repository root (AGENTS.md) are never inputs.
IGNORED_PREFIXES = ("NovelApp 20",)
DOC_SUFFIXES = (".md", ".png", ".jpg", ".jpeg", ".gif", ".svg")
# Paths that change the v2 wire / canonical fixtures and need the conformance gate.
CONFORMANCE_PREFIXES = (
    "docs/sync/v2/",
    "SyncServerV2/",
    "NovelKit/Sources/NovelSyncV2/",
    "NovelKit/Sources/NovelSyncV2Store/",
    "NovelKit/Sources/NovelWritingSupport/",
    "Scripts/conformance-v2",
)
STATIC_CHECKS = {
    "Scripts/check-code-structure.sh",
    "Scripts/check-sync-target-dependencies.sh",
    "Scripts/check-test-network-boundary.sh",
    "Scripts/check-ai-target-separation.sh",
    "Scripts/check-sync-v2-boundary.sh",
}


def run(cmd: list[str], cwd: Path = REPO) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=cwd, check=True, text=True, capture_output=True)


def changed_files(base: str) -> list[str]:
    merge_base = run(["git", "merge-base", base, "HEAD"]).stdout.strip()
    tracked = run(["git", "diff", "--name-only", merge_base]).stdout.splitlines()
    untracked = run(["git", "ls-files", "--others", "--exclude-standard"]).stdout.splitlines()
    files = sorted(set(tracked) | set(untracked))
    return [f for f in files if not f.startswith(IGNORED_PREFIXES)]


def package_graph() -> tuple[dict[str, set[str]], set[str]]:
    """Return target -> direct dependencies, and the set of test targets."""
    dump = json.loads(run(["swift", "package", "dump-package"], cwd=REPO / "NovelKit").stdout)
    deps: dict[str, set[str]] = {}
    tests: set[str] = set()
    for target in dump["targets"]:
        names = set()
        for dep in target.get("dependencies", []):
            for key in ("byName", "target", "product"):
                if key in dep and dep[key]:
                    names.add(dep[key][0])
        deps[target["name"]] = names
        if target["type"] == "test":
            tests.add(target["name"])
    return deps, tests


def affected_package_tests(changed_targets: set[str], all_tests: bool) -> list[str]:
    deps, tests = package_graph()
    if all_tests:
        return sorted(tests)
    # A test target is affected when it (transitively) depends on a changed target.
    closure: dict[str, set[str]] = {}

    def reach(name: str) -> set[str]:
        if name not in closure:
            closure[name] = set()
            for dep in deps.get(name, ()):
                closure[name] |= {dep} | reach(dep)
        return closure[name]

    return sorted(t for t in tests if t in changed_targets or reach(t) & changed_targets)


def target_sources(*names: str) -> list[str]:
    """Source paths that the named XcodeGen targets compile."""
    targets = yaml.safe_load((REPO / "project.yml").read_text())["targets"]
    paths: list[str] = []
    for name in names:
        for source in targets[name].get("sources", []):
            paths.append(source["path"] if isinstance(source, dict) else source)
    return paths


def is_under(path: str, roots: list[str]) -> bool:
    return any(path == root or path.startswith(root.rstrip("/") + "/") for root in roots)


def simulator_id() -> str:
    if os.environ.get("FUMINIWA_IOS_SIMULATOR_ID"):
        return os.environ["FUMINIWA_IOS_SIMULATOR_ID"]
    devices = json.loads(run(["xcrun", "simctl", "list", "devices", "available", "-j"]).stdout)["devices"]
    for runtime in devices.values():
        for device in runtime:
            if device.get("isAvailable") and device["name"].startswith("iPhone"):
                return device["udid"]
    sys.exit("error: an available iPhone Simulator is required (set FUMINIWA_IOS_SIMULATOR_ID)")


class Plan:
    def __init__(self) -> None:
        self.steps: list[tuple[str, list[str], Path]] = []
        self.notes: list[str] = []

    def add(self, title: str, cmd: list[str], cwd: Path = REPO) -> None:
        if all(existing[1] != cmd for existing in self.steps):
            self.steps.append((title, cmd, cwd))


def build_plan(files: list[str]) -> Plan:
    plan = Plan()
    swift = [f for f in files if f.endswith(".swift") and (REPO / f).exists()]
    package_targets: set[str] = set()
    package_all = False
    package_sources_changed = False
    mac_app_test = ios_app_test = editor_ios = conformance = False
    project_changed = "project.yml" in files
    ios_sources = target_sources("FUMINIWAIOS", "FUMINIWAIOSTests")
    mac_sources = target_sources("NovelApp", "NovelAppTests")
    unclassified: list[str] = []

    for f in files:
        if f.startswith("NovelKit/Sources/"):
            target = f.split("/")[2]
            package_targets.add(target)
            package_sources_changed = True
            editor_ios |= target == "EditorKit"
        elif f.startswith("NovelKit/Tests/"):
            package_targets.add(f.split("/")[2])
        elif f in ("NovelKit/Package.swift", "NovelKit/Package.resolved"):
            package_all = package_sources_changed = True
        elif f.startswith(("NovelApp/", "NovelAppTests/")):
            mac_app_test = True
            ios_app_test |= is_under(f, ios_sources)
        elif f.startswith(("NovelAppIOS/", "NovelAppIOSTests/")):
            ios_app_test = True
        elif f == "project.yml" or f.startswith("Config/") or f.startswith("Assets/"):
            mac_app_test = ios_app_test = True
        elif f == "Scripts/check-changed.py":
            plan.add("planner self-check", ["./Scripts/check-changed.py", "--dry-run"])
        elif f in STATIC_CHECKS:
            plan.add(f"static check: {f}", [f"./{f}"])
        elif f.startswith(("SyncServer/", "Experiments/")):
            plan.notes.append(f"{f}: 対象外（旧同期／試作）。必要なら個別に確認する")
        elif not f.endswith(DOC_SUFFIXES):
            unclassified.append(f)
        conformance |= f.startswith(CONFORMANCE_PREFIXES)
        # NovelKit test files that the app test bundles also compile run there too.
        if f.startswith("NovelKit/Tests/"):
            mac_app_test |= is_under(f, mac_sources)
            ios_app_test |= is_under(f, ios_sources)

    if swift:
        plan.add("SwiftFormat (changed files)", ["swiftformat", "--lint", "--cache", "ignore", *swift])
        plan.add("SwiftLint (changed files)",
                 ["swiftlint", "lint", "--quiet", "--no-cache", "--baseline", ".swiftlint.baseline.yml", *swift])
        plan.add("D-076 source structure", ["./Scripts/check-code-structure.sh"])
    if package_sources_changed or project_changed:
        plan.add("sync target dependencies", ["./Scripts/check-sync-target-dependencies.sh"])

    if package_targets or package_all:
        tests = affected_package_tests(package_targets, package_all)
        if tests:
            pattern = "^(" + "|".join(tests) + r")\."
            plan.add(f"swift test ({len(tests)} test targets)", ["swift", "test", "--filter", pattern],
                     REPO / "NovelKit")

    if conformance:
        plan.add("Snapshot Sync v2 conformance", ["./Scripts/conformance-v2.sh"])

    # Apps link every NovelKit product they import: rebuild them when package
    # sources change so public API breaks surface without running UI tests.
    app_build_mac = package_sources_changed and not mac_app_test
    app_build_ios = package_sources_changed and not ios_app_test
    needs_project = mac_app_test or ios_app_test or app_build_mac or app_build_ios
    unsigned = ["CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO"]
    if needs_project:
        plan.add("generate Xcode project", ["./Scripts/generate-project.sh"])
        if mac_app_test or ios_app_test or project_changed:
            plan.add("test network boundary", ["./Scripts/check-test-network-boundary.sh"])
            plan.add("AI target separation", ["./Scripts/check-ai-target-separation.sh"])
            plan.add("sync v2 boundary", ["./Scripts/check-sync-v2-boundary.sh"])
    xcode = ["xcodebuild", "-project", "FUMINIWA.xcodeproj", "-quiet"]
    if mac_app_test:
        plan.add("macOS app test", [*xcode, "test", "-scheme", "FUMINIWA", "-destination", "platform=macOS",
                                    *unsigned])
    elif app_build_mac:
        plan.add("macOS app build-for-testing", [*xcode, "build-for-testing", "-scheme", "FUMINIWA",
                                                 "-destination", "platform=macOS", *unsigned])
    if editor_ios or ios_app_test:
        sim = simulator_id()
        if editor_ios:
            plan.add("EditorKit test (iOS Simulator)",
                     ["xcodebuild", "test", "-quiet", "-scheme", "NovelKit-Package", "-destination",
                      f"platform=iOS Simulator,id={sim}", "-only-testing:EditorKitTests", *unsigned],
                     REPO / "NovelKit")
        if ios_app_test:
            plan.add("iOS app test", [*xcode, "test", "-scheme", "FUMINIWAIOS", "-destination",
                                      f"platform=iOS Simulator,id={sim}", *unsigned])
    if app_build_ios and not ios_app_test:
        plan.add("iOS app build-for-testing", [*xcode, "build-for-testing", "-scheme", "FUMINIWAIOS",
                                               "-destination", "generic/platform=iOS Simulator", *unsigned])

    if unclassified:
        plan.notes.append("分類できない変更があります。影響に応じて ./Scripts/check.sh を選んでください: "
                          + ", ".join(unclassified))
    return plan


def wait_for_simulator(cmd: list[str]) -> None:
    match = next((a for a in cmd if a.startswith("platform=iOS Simulator,id=")), None)
    if not match:
        return
    udid = match.split("id=", 1)[1]
    while subprocess.run(["pgrep", "-f", f"xcodebuild.*{udid}"], capture_output=True).returncode == 0:
        print("==> Selected Simulator is in use; waiting", flush=True)
        time.sleep(5)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base", default="origin/main", help="比較元（既定: origin/main とのmerge base）")
    parser.add_argument("--dry-run", action="store_true", help="実行せず計画だけ表示する")
    parser.add_argument("files", nargs="*", help="差分の代わりに対象ファイルを直接指定する")
    args = parser.parse_args()

    files = args.files or changed_files(args.base)
    print(f"==> {len(files)} changed file(s)")
    for f in files:
        print(f"    {f}")
    plan = build_plan(files)
    for note in plan.notes:
        print(f"note: {note}")
    if not plan.steps:
        print("==> No checks selected (docs-only or out-of-scope change)")
        return 0
    print("==> Plan")
    for title, cmd, cwd in plan.steps:
        where = "" if cwd == REPO else f"(cd {cwd.relative_to(REPO)}) "
        print(f"    - {title}: {where}{shlex.join(cmd[:8])}{' …' if len(cmd) > 8 else ''}")
    if args.dry_run:
        return 0

    started = time.monotonic()
    for title, cmd, cwd in plan.steps:
        print(f"==> {title}", flush=True)
        wait_for_simulator(cmd)
        step_started = time.monotonic()
        if subprocess.run(cmd, cwd=cwd).returncode != 0:
            print(f"error: {title} failed", file=sys.stderr)
            return 1
        print(f"    ({time.monotonic() - step_started:.0f}s)", flush=True)
    print(f"==> Changed-area checks passed ({time.monotonic() - started:.0f}s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
