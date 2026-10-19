#!/usr/bin/env python3
"""Exercise the real liberime/librime-lua bridge in a disposable Rime home."""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--module", required=True, type=Path)
    parser.add_argument("--avy-directory", required=True, type=Path)
    parser.add_argument("--emacs", default="emacs")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix="liberime-segment-") as directory:
        home = Path(directory)

        def config(name, value):
            # JSON is a YAML subset; avoid a test-only PyYAML dependency.
            (home / name).write_text(json.dumps(value, ensure_ascii=False))

        backend_id = "liberime_regexp_segment_toy"
        engine = {"processors": ["speller"], "segmentors": ["abc_segmentor"],
                  "translators": ["script_translator"]}
        translator = {"dictionary": "toy", "prism": backend_id,
                      "packs": ["extra"],
                      "enable_user_dict": False, "enable_completion": False}
        config(backend_id + ".schema.yaml", {
            "schema": {"schema_id": backend_id, "name": "Canonical", "version": "1"},
            "translator": translator, "speller": {"delimiter": " '", "algebra": []}})
        for name in ("full", "double"):
            config(name + ".schema.yaml", {
                "schema": {"schema_id": name, "name": name, "version": "1"},
                "engine": engine, "translator": dict(translator, prism=name),
                "speller": {"alphabet": "abcdefghijklmnopqrstuvwxyz", "delimiter": " '",
                            "algebra": [] if name == "full" else ["xform/^yan$/y/", "xform/^jiu$/j/"]}})
        config("missing.schema.yaml", {
            "schema": {"schema_id": "missing", "name": "No dictionary", "version": "1"},
            "engine": {"processors": ["speller"], "segmentors": ["abc_segmentor"], "translators": []}})
        config("unmapped.schema.yaml", {
            "schema": {"schema_id": "unmapped", "name": "Unmapped", "version": "1"},
            "translator": {"dictionary": "unmapped"}})
        config("liberime_regexp_segment.schema.yaml", {
            "schema": {"schema_id": "liberime_regexp_segment", "name": "Gateway", "version": "1",
                       "dependencies": [backend_id]},
            "engine": dict(engine, translators=["lua_translator@*liberime_regexp_segment"]),
            "speller": {"alphabet": "abcdefghijklmnopqrstuvwxyz0123456789"},
            "segment": {"backends": {"toy": backend_id}}})
        config("default.yaml", {"config_version": "1", "schema_list": [
            {"schema": name} for name in ("double", "full", "missing", "liberime_regexp_segment")]})
        (home / "toy.dict.yaml").write_text(
            "---\nname: toy\nversion: '1'\nsort: by_weight\n...\n"
            "研\tyan\t1000\n究\tjiu\t1000\n生\tsheng\t1000\n命\tming\t1000\n"
            "研究\tyan jiu\t1000000\n研究生\tyan jiu sheng\t1\n生命\tsheng ming\t1000000\n"
            "重\tzhong\t1000\n重\tchong\t1000\n庆\tqing\t1000\n重庆\tchong qing\t1000000\n"
            "词\tci\t1000\n典\tdian\t1000\n"
            "𠀀\text\t1000\n𠀀研\text yan\t1000000\n形码词\txmc\t1000000\n",
            encoding="utf-8")
        (home / "extra.dict.yaml").write_text(
            "---\nname: extra\nversion: '1'\nsort: by_weight\n...\n"
            "词典\tci dian\t1000000\n", encoding="utf-8")
        (home / "lua").mkdir()
        shutil.copyfile(repo / "rime/liberime_regexp_segment.lua", home / "lua/liberime_regexp_segment.lua")
        env = dict(os.environ, LIBERIME_TEST_HOME=str(home), LIBERIME_TEST_MODULE=str(args.module.resolve()))
        result = subprocess.run([
            args.emacs, "--batch", "-Q", "-L", str(args.avy_directory.resolve()), "-L", str(repo),
            "-l", str(repo / "test/liberime-regexp-segment-integration.el")],
            env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        print(result.stdout)
        raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
