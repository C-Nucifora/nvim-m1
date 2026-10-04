#!/usr/bin/env python3
"""Offline tests for release validation and atomic proposal preparation."""

import importlib.util
import json
import re
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("sync", Path(__file__).with_name("sync-toolchain.py"))
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)


def source_fixture():
    source = Path(__file__).resolve().parents[1].joinpath("lua/nvim-m1/install.lua").read_text()
    for tool in sync.TOOLS:
        source = re.sub(rf'(\["{re.escape(tool)}"\]\s*=\s*)"v[^"]+"',
                        lambda match: match[1] + '"v1.0.0"', source)
    return source


def release(tool, tag="v1.2.3"):
    names = [f"{tool}-{target}{suffix}" for target, suffix in sync.TARGETS]
    assets = [{"name": name, "state": "uploaded", "size": 1} for name in names + ["SHA256SUMS"]]
    checksums = "".join("a" * 64 + "  " + name + "\n" for name in names)
    return {"tagName": tag, "isDraft": False, "isPrerelease": False, "assets": assets}, checksums


class SyncTests(unittest.TestCase):
    def test_complete_release(self):
        sync.validate_release("m1-lsp", *release("m1-lsp"))

    def test_unsafe_tag(self):
        for tag in ("v1.2.3-rc.1", "v1$(bad).2.3", "v1.2.3\n", "latest", "v01.2.3"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                sync.semver(tag)

    def test_incomplete_release(self):
        for mutation in ("draft", "prerelease", "missing", "uploading", "empty"):
            data, manifest = release("m1-lsp")
            if mutation == "draft": data["isDraft"] = True
            if mutation == "prerelease": data["isPrerelease"] = True
            if mutation == "missing": data["assets"].pop(0)
            if mutation == "uploading": data["assets"][0]["state"] = "new"
            if mutation == "empty": data["assets"][0]["size"] = 0
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                sync.validate_release("m1-lsp", data, manifest)

    def test_invalid_manifest(self):
        data, manifest = release("m1-lsp")
        cases = (manifest.splitlines()[0], manifest + manifest.splitlines()[0] + "\n",
                 manifest.replace("a" * 64, "bad"), manifest.replace("m1-lsp-", "../m1-lsp-"))
        for value in cases:
            with self.subTest(manifest=value), self.assertRaises(ValueError):
                sync.validate_release("m1-lsp", data, value)

    def test_native_digest_mismatch(self):
        for index in (0, 3):
            data, manifest = release("m1-lsp")
            data["assets"][index]["digest"] = "sha256:" + "b" * 64
            with self.subTest(index=index), self.assertRaises(ValueError):
                sync.validate_release("m1-lsp", data, manifest)

    def test_no_downgrade_or_repeat_download(self):
        source = source_fixture().replace('["m1-lsp"] = "v1.0.0"',
                                          '["m1-lsp"] = "v1.10.0"')
        calls = []
        def run(*args):
            calls.append(args)
            tag = "v1.9.99" if "m1-lsp" in args[-1] else "v0.0.1"
            data = release("m1-lsp", tag)[0]
            return json.dumps({"tag_name": data["tagName"], "draft": False,
                               "prerelease": False, "assets": data["assets"]})
        self.assertEqual(sync.entries(source, "versions"), sync.resolve(source, run))
        self.assertEqual(4, len(calls))

    def test_fmt_only_release_updates_without_waiting_for_new_server(self):
        source = source_fixture()
        pinned = sync.entries(source, "versions")
        def run(*args):
            if args[0] == "api":
                tool = args[-1].split("/")[2]
                data = release(tool, "v9.8.7" if tool == "m1-fmt" else pinned[tool])[0]
                return json.dumps({"tag_name": data["tagName"], "draft": False,
                                   "prerelease": False, "assets": data["assets"]})
            self.assertEqual("v9.8.7", args[2])
            Path(args[-1]).write_text(release("m1-fmt")[1])
            return ""
        result = sync.resolve(source, run)
        self.assertEqual("v9.8.7", result["m1-fmt"])
        self.assertEqual(pinned["m1-lsp"], result["m1-lsp"])

    def test_incomplete_later_release_aborts_entire_proposal(self):
        source = source_fixture()
        def run(*args):
            if args[0] == "api":
                tool = args[-1].split("/")[2]
                data = release(tool, "v9.8.7")[0]
                if tool == "m1-project":
                    data["assets"].pop(0)
                return json.dumps({"tag_name": data["tagName"], "draft": False,
                                   "prerelease": False, "assets": data["assets"]})
            repo = args[args.index("--repo") + 1]
            tool = repo.split("/")[1]
            Path(args[-1]).write_text(release(tool)[1])
            return ""
        with self.assertRaises(ValueError):
            sync.resolve(source, run)

    def test_one_release_version_bump_updates_only_version_block(self):
        source = source_fixture()
        versions = sync.entries(source, "versions")
        versions["m1-fmt"] = "v9.8.7"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            root.joinpath("lua/nvim-m1").mkdir(parents=True)
            root.joinpath("VERSION").write_text("1.2.3\n")
            self.assertEqual("1.2.4", sync.apply(root, source, versions))
            updated = root.joinpath("lua/nvim-m1/install.lua").read_text()
            self.assertEqual(versions, sync.entries(updated, "versions"))
            self.assertEqual(sync.entries(source, "repos"), sync.entries(updated, "repos"))


if __name__ == "__main__":
    unittest.main()
