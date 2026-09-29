#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""精简已有归档清单，并删除同级 .github 目录，保留分片和 SUCCESS 标记。

默认处理 ./tmp/*/manifest.json；以 . 开头的暂存目录会被跳过。
仅移除 objects 中的 etag、sha256、archive_path，保留 parts 中的 SHA256。
需要 Python >=3.9，仅使用标准库。
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path

REMOVED_FIELDS = ("etag", "sha256", "archive_path")


def replace_manifest(path: Path, manifest: dict) -> None:
    """先在同一目录写完整临时文件，再原子替换，避免中断截断原清单。"""
    temporary_path = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", newline="\n", dir=path.parent,
            prefix=".manifest-", suffix=".tmp", delete=False,
        ) as output:
            temporary_path = Path(output.name)
            json.dump(manifest, output, ensure_ascii=False, indent=2)
            output.write("\n")
        os.replace(temporary_path, path)
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def cleanup_manifest(path: Path, *, dry_run: bool = False) -> tuple[int, bool]:
    """返回移除的对象字段数、是否清理 .github；路径必须位于原归档目录内。"""
    path = Path(os.path.abspath(path))
    if path.resolve() != path:
        raise ValueError("清单或其父目录是符号链接/目录联接，跳过以免修改其他目录")
    github_dir = path.parent / ".github"
    if github_dir.is_symlink() or github_dir.resolve() != github_dir:
        raise ValueError(".github 是符号链接/目录联接，跳过以免删除其他目录")
    if github_dir.exists() and not github_dir.is_dir():
        raise ValueError(".github 不是目录")
    has_github = github_dir.is_dir()

    with path.open(encoding="utf-8-sig") as source:
        manifest = json.load(source)
    if not isinstance(manifest, dict) or not isinstance(manifest.get("objects"), list):
        raise ValueError("清单必须包含 objects 数组")
    if not all(isinstance(item, dict) for item in manifest["objects"]):
        raise ValueError("objects 数组的每一项必须是对象")

    removed = 0
    for item in manifest["objects"]:
        for field in REMOVED_FIELDS:
            if field in item:
                del item[field]
                removed += 1

    if not dry_run:
        if removed:
            replace_manifest(path, manifest)
        if has_github:
            shutil.rmtree(github_dir)
    return removed, has_github


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--output-dir", type=Path, default=Path("tmp"), help="归档父目录，默认 ./tmp")
    parser.add_argument("--dry-run", action="store_true", help="仅预览要清理的字段和目录")
    args = parser.parse_args(argv)
    output_dir = args.output_dir.resolve()
    if not output_dir.is_dir():
        parser.error(f"归档父目录不存在或不是目录：{output_dir}")

    processed = removed_fields = removed_dirs = saved_bytes = errors = 0
    action = "预览" if args.dry_run else "完成"
    for path in sorted(output_dir.glob("*/manifest.json")):
        if path.parent.name.startswith("."):
            continue
        try:
            old_size = path.stat().st_size
            fields, directory = cleanup_manifest(path, dry_run=args.dry_run)
            saved_bytes += old_size - path.stat().st_size
        except (OSError, ValueError, RuntimeError) as exc:
            print(f"失败 {path}：{exc}", file=sys.stderr)
            errors += 1
            continue
        processed += 1
        removed_fields += fields
        removed_dirs += int(directory)
        print(f"{action} {path.parent.name}：移除 {fields} 个字段，清理 {int(directory)} 个 .github 目录")

    print(f"{action}：处理 {processed} 份清单，移除 {removed_fields} 个字段，清理 {removed_dirs} 个 .github 目录，失败 {errors} 个")
    if not args.dry_run:
        print(f"清单合计减少 {saved_bytes:,} 字节")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
