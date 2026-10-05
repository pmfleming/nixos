"""Evaluation-only integration test; never edits live worktrees or deploys.

Usage: python3 rust-cache-identity.py PROJECTS_DIR NIXPKGS_SOURCE CRANE_SOURCE
Pass the resolved, pinned input source directories (no flake resolution/update
is performed here). Run outside a Nix build sandbox: this test invokes Nix.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def snapshot(source, target):
    target.mkdir()
    files = subprocess.check_output(["git", "-C", str(source), "ls-files", "-z"])
    for name in set(os.fsdecode(files).split("\0")) - {""}:
        src, dst = source / name, target / name
        if not src.exists() and not src.is_symlink():
            continue
        dst.parent.mkdir(parents=True, exist_ok=True)
        if src.is_symlink():
            dst.symlink_to(os.readlink(src))
        else:
            shutil.copy2(src, dst)


def evaluate(projects, nixpkgs, crane):
    expression = """
      let
        system = "x86_64-linux";
        projects = builtins.toPath PROJECTS;
        nixpkgsPath = builtins.toPath NIXPKGS;
        pkgs = import nixpkgsPath { inherit system; };
        nixpkgs = {
          inherit (pkgs) lib;
          outPath = nixpkgsPath;
          legacyPackages.${system} = pkgs;
        };
        crane = (import (builtins.toPath CRANE + "/flake.nix")).outputs { self = crane; };
        framework = (import (projects + "/daemon-framework/flake.nix")).outputs {
          self = framework;
          inherit nixpkgs crane;
        };
        daemon = name: let
          result = (import (projects + "/${name}/flake.nix")).outputs {
            self = result;
            inherit nixpkgs;
            daemonFramework = framework;
          };
        in result.packages.${system}.default;
        scratchpad = (import (projects + "/scratchpad/flake.nix")).outputs {
          inherit nixpkgs crane;
        };
        packages = {
          app = daemon "app-daemon";
          bar = daemon "bar-daemon";
          bt = daemon "bt-daemon";
          clip = daemon "clip-daemon";
          nm = daemon "nm-daemon";
          scratchpad = scratchpad.packages.${system}.default;
          framework = framework.checks.${system}.workspace;
          localBuild = framework.packages.${system}.localBuild;
          protocol = framework.packages.${system}.protocolBindings;
        };
      in builtins.mapAttrs (_: package: {
        drv = package.drvPath;
        src = toString package.src;
        cache = map (dependency: dependency.drvPath) package.rebuildCache;
      }) packages
    """
    for key, path in (("PROJECTS", projects), ("NIXPKGS", nixpkgs), ("CRANE", crane)):
        expression = expression.replace(key, json.dumps(str(path)))
    return json.loads(subprocess.check_output([
        "nix", "eval", "--impure", "--json", "--expr", expression,
    ]))


def append(path, text):
    with path.open("a") as output:
        output.write(text)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("projects", type=Path)
    parser.add_argument("nixpkgs", type=Path)
    parser.add_argument("crane", type=Path)
    args = parser.parse_args()
    names = ["daemon-framework", "app-daemon", "bar-daemon", "bt-daemon",
             "clip-daemon", "nm-daemon", "scratchpad"]
    with tempfile.TemporaryDirectory(prefix="rust-cache-identity-") as temporary:
        root = Path(temporary) / "first"
        root.mkdir()
        for name in names:
            snapshot(args.projects.resolve() / name, root / name)
        def current():
            return evaluate(root, args.nixpkgs.resolve(), args.crane.resolve())
        before = current()
        other = Path(temporary) / "second"
        shutil.copytree(root, other, symlinks=True)
        assert evaluate(other, args.nixpkgs.resolve(), args.crane.resolve()) == before, \
            "temporary snapshot paths invalidate packages"
        for name in names:
            append(root / name / "README.md", "\nDocumentation-only cache test\n")
            append(root / name / "flake.lock", "\n")
        assert current() == before, "documentation or flake locks invalidate packages"
        append(root / "app-daemon/src/lib.rs", "\n// Application cache test\n")
        edited = current()
        assert edited["app"]["drv"] != before["app"]["drv"]
        assert edited["app"]["cache"] == before["app"]["cache"], \
            "application code invalidates compiled dependencies"
        assert all(edited[key] == before[key] for key in before if key != "app")
        append(root / "daemon-framework/crates/shelllist-local-build/src/main.rs",
               "\n// Unrelated framework tool edit\n")
        tool = current()
        assert all(tool[key] == edited[key] for key in ["app", "bar", "bt", "clip", "nm", "scratchpad"]), \
            "framework deployment tooling invalidates daemon packages"
        assert tool["framework"]["drv"] != edited["framework"]["drv"]
        assert tool["framework"]["cache"] == edited["framework"]["cache"]
        assert before["framework"]["cache"] == before["localBuild"]["cache"] == before["protocol"]["cache"], \
            "framework tools must share compiled dependencies"
        append(root / "daemon-framework/crates/shelllist-daemon-core/src/lib.rs",
               "\n// Shared library edit\n")
        core = current()
        assert all(core[key]["drv"] != tool[key]["drv"] for key in ["app", "bar", "bt", "clip", "nm"]), \
            "shared library changes must invalidate all consumers"
        assert core["scratchpad"] == tool["scratchpad"]
        manifest = root / "app-daemon/Cargo.toml"
        manifest.write_text(manifest.read_text().replace(
            "[features]", '[features]\ndefault = ["benchmarks"]', 1,
        ))
        assert current()["app"]["cache"] != core["app"]["cache"], \
            "Cargo feature/dependency changes must invalidate compiled dependencies"
    print("Rust source isolation, dependency reuse, and snapshot identity tests passed")


if __name__ == "__main__":
    main()
