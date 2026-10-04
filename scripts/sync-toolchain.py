#!/usr/bin/env python3
"""Propose only complete, published M1 binary releases; never merge or publish."""

import argparse
import hashlib
import json
import re
import subprocess
import tempfile
from pathlib import Path

TOOLS = ("m1-lsp", "m1-fmt", "m1-lint", "m1-project")
TARGETS = (
    ("x86_64-unknown-linux-gnu", ""),
    ("aarch64-apple-darwin", ""),
    ("x86_64-pc-windows-msvc", ".exe"),
)


def semver(value):
    match = re.fullmatch(r"v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", value)
    if not match:
        raise ValueError(f"Expected a vX.Y.Z release tag, got {value!r}")
    return tuple(map(int, match.groups()))


def entries(source, name):
    block = re.search(rf"M\.{name}\s*=\s*\{{(.*?)\n\}}", source, re.S)
    if not block:
        raise ValueError(f"Cannot find M.{name} in install.lua")
    pairs = re.findall(r'\["([^"]+)"\]\s*=\s*"([^"]+)"', block[1])
    if len(pairs) != len(TOOLS) or set(dict(pairs)) != set(TOOLS):
        raise ValueError(f"M.{name} must contain exactly the four bundled tools")
    return dict(pairs)


def gh(*args):
    return subprocess.check_output(["gh", *args], text=True)


def validate_release(tool, release, checksums):
    tag = release["tagName"]
    semver(tag)
    if release.get("isDraft") or release.get("isPrerelease"):
        raise ValueError(f"{tool} {tag} is not a stable published release")
    required = {f"{tool}-{target}{suffix}" for target, suffix in TARGETS}
    assets = release.get("assets", [])
    names = [asset["name"] for asset in assets]
    for name in required | {"SHA256SUMS"}:
        matching = [asset for asset in assets if asset["name"] == name]
        if len(matching) != 1 or matching[0].get("state") != "uploaded":
            raise ValueError(f"{tool} {tag}: missing/incomplete asset {name}")
        if matching[0].get("size", 0) <= 0:
            raise ValueError(f"{tool} {tag}: empty asset {name}")
    if len(names) != len(set(names)):
        raise ValueError(f"{tool} {tag}: duplicate release asset names")
    manifest = {}
    for line in checksums.splitlines():
        if not line.strip():
            continue
        match = re.fullmatch(r"([0-9a-fA-F]{64})[ \t]+\*?([^/\\\s]+)", line)
        if not match or match[2] in manifest:
            raise ValueError(f"{tool} {tag}: malformed/duplicate SHA256SUMS entry")
        manifest[match[2]] = match[1]
    if not required <= manifest.keys():
        raise ValueError(f"{tool} {tag}: SHA256SUMS omits a supported binary")
    for asset in assets:
        if asset["name"] not in required | {"SHA256SUMS"}:
            continue
        digest = asset.get("digest")
        if digest is None:
            continue  # Releases predating GitHub's native digest field still have SHA256SUMS.
        expected = (hashlib.sha256(checksums.encode()).hexdigest()
                    if asset["name"] == "SHA256SUMS" else manifest[asset["name"]])
        if digest.lower() != "sha256:" + expected.lower():
            raise ValueError(f"{tool} {tag}: asset digest disagrees with SHA256SUMS")


def resolve(source, run=gh):
    pinned = entries(source, "versions")
    repos = entries(source, "repos")
    result = dict(pinned)
    for tool in TOOLS:
        semver(pinned[tool])
        repo = repos[tool]
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
            raise ValueError(f"Invalid GitHub repository {repo!r}")
        raw = json.loads(run("api", f"repos/{repo}/releases/latest"))
        release = {"tagName": raw["tag_name"], "isDraft": raw["draft"],
                   "isPrerelease": raw["prerelease"], "assets": raw["assets"]}
        latest = release["tagName"]
        if semver(latest) <= semver(pinned[tool]):
            continue
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "SHA256SUMS"
            run("release", "download", latest, "--repo", repo,
                "--pattern", "SHA256SUMS", "--output", str(manifest))
            validate_release(tool, release, manifest.read_bytes().decode("utf-8"))
        result[tool] = latest
    return result


def apply(root, source, versions):
    pinned = entries(source, "versions")
    block = re.search(r"M\.versions\s*=\s*\{(.*?)\n\}", source, re.S)
    replacement = block[1]
    for tool in TOOLS:
        replacement = re.sub(rf'(\["{re.escape(tool)}"\]\s*=\s*)"[^"]+"',
                             lambda match: match[1] + '"' + versions[tool] + '"', replacement)
    version_path = root / "VERSION"
    old_version = version_path.read_text().strip()
    major, minor, patch = semver("v" + old_version)
    new_version = f"{major}.{minor}.{patch + 1}"
    new_source = source[:block.start(1)] + replacement + source[block.end(1):]
    (root / "lua/nvim-m1/install.lua").write_text(new_source)
    version_path.write_text(new_version + "\n")
    return new_version


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--apply", action="store_true", help="Update pins and VERSION")
    args = parser.parse_args()
    source = (args.root / "lua/nvim-m1/install.lua").read_text()
    versions = resolve(source)
    changed = versions != entries(source, "versions")
    result = {"changed": changed, "versions": versions}
    if changed and args.apply:
        result["version"] = apply(args.root, source, versions)
    print(json.dumps(result))


if __name__ == "__main__":
    main()
