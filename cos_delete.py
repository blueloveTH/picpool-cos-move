#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""并发批量删除 COS 中已归档且已发布的对象。

读取归档父目录（默认 ./tmp）中各文件夹 manifest.json 的 objects[].id，
只处理有 SUCCESS 标记、且清单 bucket 与 --bucket 相同的文件夹。
删除前完整列举存储桶，只删除大小和 LastModified 仍与清单一致的对象；
每批最多 1000 个 key，多批并发调用 COS 批量删除接口。
文件夹的 key 全部删除后写入空的 COS_DELETED 标记，再次运行时跳过。
Python >=3.9。首次运行缺少 SDK 时自动安装 cos-python-sdk-v5。
凭据从 COS_SECRET_ID / COS_SECRET_KEY / COS_TOKEN 环境变量读取。
示例：python cos_delete.py --bucket example-1250000000 --region ap-shanghai --dry-run
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import logging
import os
import subprocess
import sys
import time
from collections.abc import Iterator
from concurrent.futures import FIRST_COMPLETED, Future, ThreadPoolExecutor, wait
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

BATCH_SIZE = 1000  # COS 批量删除接口单次最多 1000 个对象。
DONE_MARKER = "COS_DELETED"
MANIFEST_FORMAT = "tar-byte-split-v1"
SDK_REQUIREMENT = "cos-python-sdk-v5==1.9.44"
LOG = logging.getLogger("cos_delete")


def parse_time(value: str) -> datetime:
    """接受 COS 返回的带时区 ISO 8601 时间，转换为 UTC。"""
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError(f"时间缺少时区：{value!r}")
    return parsed.astimezone(timezone.utc)


@dataclass
class Folder:
    """一个已发布文件夹的删除计划和结果。"""

    path: Path
    total: int
    to_delete: list[str] = field(default_factory=list)
    absent: int = 0
    changed: int = 0
    deleted: int = 0
    failed: int = 0
    batches: int = 0  # 尚未完成的删除批次数
    done: bool = False

    @property
    def name(self) -> str:
        return self.path.name


def load_folders(
    output_dir: Path, bucket: str
) -> tuple[list[Folder], dict[str, tuple[int, int, datetime]]]:
    """读取已发布文件夹的清单，返回文件夹和 key ->（文件夹序号, 大小, LastModified）。"""
    folders: list[Folder] = []
    expected: dict[str, tuple[int, int, datetime]] = {}
    finished = 0
    for path in sorted(output_dir.iterdir()):
        # 与 publish.sh --all 一样忽略 .cos-pending-* 等以 . 开头的目录和普通文件。
        if path.name.startswith(".") or not path.is_dir():
            continue
        if (path / DONE_MARKER).exists():
            finished += 1
            continue
        if not (path / "SUCCESS").is_file():
            LOG.warning("%s 尚未发布成功（缺少 SUCCESS），不删除其中的对象", path.name)
            continue
        manifest_path = path / "manifest.json"
        try:
            with manifest_path.open(encoding="utf-8") as file:
                manifest = json.load(file)
            if manifest["format"] != MANIFEST_FORMAT:
                raise ValueError(f"未知的清单格式 {manifest['format']!r}")
            manifest_bucket = manifest["bucket"]
            objects = []
            for item in manifest["objects"]:
                key, size, modified = item["id"], item["size"], item["last_modified"]
                if not isinstance(key, str) or not key:
                    raise ValueError("objects[].id 必须是非空字符串")
                if type(size) is not int or size < 0:
                    raise ValueError(f"{key!r} 的 size 必须是非负整数")
                if not isinstance(modified, str):
                    raise ValueError(f"{key!r} 的 last_modified 必须是字符串")
                objects.append((key, size, parse_time(modified)))
        except (OSError, ValueError, LookupError, TypeError) as exc:
            raise RuntimeError(f"无法读取清单 {manifest_path}：{exc!r}") from exc
        if manifest_bucket != bucket:
            LOG.info("%s 属于存储桶 %r，跳过", path.name, manifest_bucket)
            continue
        folder = Folder(path, total=len(objects))
        folders.append(folder)
        for key, size, modified in objects:
            if key in expected:
                other = folders[expected[key][0]].name
                raise RuntimeError(f"key {key!r} 同时记录在 {other} 和 {folder.name} 的清单中，请人工确认")
            expected[key] = (len(folders) - 1, size, modified)
    if finished:
        LOG.info("跳过已有 %s 的 %d 个文件夹", DONE_MARKER, finished)
    return folders, expected


def match_objects(
    client: Any, bucket: str, folders: list[Folder],
    expected: dict[str, tuple[int, int, datetime]],
) -> int:
    """完整列举存储桶，把清单中的 key 分为待删除、已不存在和归档后已变化；返回列举数。"""
    marker = ""
    listed = matched = pages = 0
    while True:
        response = client.list_objects(
            Bucket=bucket, Prefix="", Delimiter="", Marker=marker, MaxKeys=1000
        )
        contents = response.get("Contents", [])
        for item in contents:
            record = expected.pop(item["Key"], None)
            if record is None:
                continue  # 不在待处理清单中的对象不删除。
            index, size, modified = record
            folder = folders[index]
            current_size, current_time = int(item["Size"]), item["LastModified"]
            if current_size == size and parse_time(current_time) == modified:
                folder.to_delete.append(item["Key"])
                matched += 1
            else:
                # 覆盖后的新内容不在归档中，删除会丢失数据。
                folder.changed += 1
                LOG.warning("%s 中的 %r 归档后已变化（清单 %d 字节、%s；现在 %d 字节、%s），保留不删",
                            folder.name, item["Key"], size, modified.isoformat(),
                            current_size, current_time)
        listed += len(contents)
        pages += 1
        if pages % 10 == 0:
            LOG.info("已列举 %d 个对象，其中 %d 个待删除", listed, matched)
        if str(response.get("IsTruncated", "false")).lower() != "true":
            break
        next_marker = response.get("NextMarker") or (
            contents[-1]["Key"] if contents else ""
        )
        if not next_marker or next_marker <= marker:
            raise RuntimeError("COS 分页游标没有前进，停止以避免死循环")
        marker = next_marker
    # 列举中没有出现的 key 已不在 COS 中，无需删除。
    for index, _, _ in expected.values():
        folders[index].absent += 1
    expected.clear()
    LOG.info("列举完成：%d 个对象，其中 %d 个待删除", listed, matched)
    return listed


def delete_batch(
    client: Any, bucket: str, keys: list[str], attempts: int
) -> tuple[int, dict[str, str]]:
    """删除一批 key，返回删除数和最终失败的 key 及原因；权限等错误直接抛出。"""
    remaining = keys
    failures: dict[str, str] = {}
    for attempt in range(1, attempts + 1):
        try:
            response = client.delete_objects(Bucket=bucket, Delete={
                "Quiet": "true",  # 只返回删除失败的 key。
                "Object": [{"Key": key} for key in remaining],
            })
        except Exception as exc:
            status_getter = getattr(exc, "get_status_code", None)
            status = str(status_getter()) if callable(status_getter) else ""
            # 4xx 是请求本身的问题（凭据、权限、存储桶不存在等），重试无效。
            if attempt == attempts or (status.startswith("4") and status not in {"408", "429"}):
                raise RuntimeError(f"批量删除请求失败（{len(remaining)} 个 key）：{exc}") from exc
            LOG.warning("批量删除请求失败，准备重试 %d/%d：%s", attempt + 1, attempts, exc)
            time.sleep(min(2 ** (attempt - 1), 8))
            continue
        requested = set(remaining)
        failures = {}
        for error in response.get("Error", []):
            key, code = error.get("Key"), error.get("Code")
            if code == "NoSuchKey":
                continue  # 不存在的 key 等同于已删除。
            if code == "AccessDenied":
                raise RuntimeError(f"没有删除 {key!r} 的权限：{error.get('Message')}")
            reason = f"{code}：{error.get('Message')}"
            if key not in requested:
                # 无法确认哪些 key 已删除时整批按失败重试；重复删除没有副作用。
                failures = dict.fromkeys(remaining, f"响应中的 {key!r} 不在本批请求中（{reason}）")
                break
            failures[key] = reason
        if not failures:
            break
        remaining = [key for key in remaining if key in failures]
        if attempt < attempts:
            LOG.warning("%d 个 key 删除失败，准备重试 %d/%d，例如 %r：%s", len(failures),
                        attempt + 1, attempts, remaining[0], failures[remaining[0]])
            time.sleep(min(2 ** (attempt - 1), 8))
    return len(keys) - len(failures), failures


def delete_folders(
    client: Any, bucket: str, folders: list[Folder], *, workers: int, attempts: int,
) -> None:
    """限制同时进行的删除请求数；文件夹的批次全部完成后立即写入标记。"""
    total = sum(len(folder.to_delete) for folder in folders)
    deleted = 0

    def finish(folder: Folder) -> None:
        if folder.failed or folder.changed:
            LOG.warning("完成 %s：删除 %d 个，失败 %d 个，归档后变化 %d 个；不写入 %s",
                        folder.name, folder.deleted, folder.failed, folder.changed, DONE_MARKER)
            return
        (folder.path / DONE_MARKER).touch()
        folder.done = True
        LOG.info("完成 %s：删除 %d 个，已不存在 %d 个；累计删除 %d/%d，已写入 %s",
                 folder.name, folder.deleted, folder.absent, deleted, total, DONE_MARKER)

    def batches() -> Iterator[tuple[Folder, list[str]]]:
        for folder in folders:
            for start in range(0, len(folder.to_delete), BATCH_SIZE):
                yield folder, folder.to_delete[start:start + BATCH_SIZE]

    for folder in folders:
        folder.batches = -(-len(folder.to_delete) // BATCH_SIZE)
        if folder.batches == 0:
            finish(folder)  # 对象都已不存在，或只剩归档后变化的对象。
    jobs = batches()
    pending: dict[Future[tuple[int, dict[str, str]]], Folder] = {}
    with ThreadPoolExecutor(max_workers=workers, thread_name_prefix="cos-delete") as executor:

        def fill_slots() -> None:
            while len(pending) < workers:
                try:
                    folder, keys = next(jobs)
                except StopIteration:
                    return
                pending[executor.submit(delete_batch, client, bucket, keys, attempts)] = folder

        try:
            fill_slots()
            while pending:
                done, _ = wait(pending, return_when=FIRST_COMPLETED)
                # 先处理本轮完成的批次再补任务；出现致命错误后不再发起新请求。
                for future in done:
                    folder = pending.pop(future)
                    count, failures = future.result()
                    for key, reason in failures.items():
                        LOG.error("%s 中的 %r 删除失败：%s", folder.name, key, reason)
                    folder.deleted += count
                    folder.failed += len(failures)
                    folder.batches -= 1
                    deleted += count
                    LOG.debug("%s：本批删除 %d 个，累计删除 %d/%d", folder.name, count, deleted, total)
                    if folder.batches == 0:
                        finish(folder)
                fill_slots()
        except BaseException:
            for future in pending:
                future.cancel()
            # 等待已发出的请求结束，避免退出后仍有线程在删除。
            wait(pending)
            raise


def purge(
    client: Any, bucket: str, folders: list[Folder],
    expected: dict[str, tuple[int, int, datetime]], *,
    workers: int = 8, attempts: int = 3, dry_run: bool = False,
) -> int:
    """列举核对后并发删除，返回进程退出码。"""
    if min(workers, attempts) <= 0:
        raise ValueError("并发数和尝试次数必须为正数")
    match_objects(client, bucket, folders, expected)
    for folder in folders:
        LOG.info("%s：清单 %d 个，待删除 %d 个，已不存在 %d 个，归档后变化 %d 个",
                 folder.name, folder.total, len(folder.to_delete), folder.absent, folder.changed)
    planned = sum(len(folder.to_delete) for folder in folders)
    absent = sum(folder.absent for folder in folders)
    changed = sum(folder.changed for folder in folders)
    LOG.info("合计 %d 个文件夹：待删除 %d 个，已不存在 %d 个，归档后变化 %d 个",
             len(folders), planned, absent, changed)
    if dry_run:
        LOG.info("预览结束：没有删除对象，也没有写入 %s", DONE_MARKER)
        return 0
    LOG.info("开始删除：每批最多 %d 个 key，并发请求数 %d", BATCH_SIZE, workers)
    delete_folders(client, bucket, folders, workers=workers, attempts=attempts)
    deleted = sum(folder.deleted for folder in folders)
    failed = sum(folder.failed for folder in folders)
    marked = sum(folder.done for folder in folders)
    LOG.info("结束：删除 %d 个，已不存在 %d 个，失败 %d 个，归档后变化保留 %d 个；%d/%d 个文件夹写入 %s",
             deleted, absent, failed, changed, marked, len(folders), DONE_MARKER)
    if changed:
        LOG.warning("%d 个对象归档后被覆盖，新内容不在归档中，已保留在 COS，请人工确认", changed)
    if failed:
        LOG.error("%d 个 key 删除失败，仍保留在 COS；重新运行即可重试", failed)
    return 1 if failed else 0


def connect(
    region: str, secret_id: str, secret_key: str, *,
    timeout: int, workers: int, install_sdk: bool,
) -> Any:
    """创建 COS 客户端；当前环境缺少 SDK 时按需安装。"""
    if importlib.util.find_spec("qcloud_cos") is None:
        if not install_sdk:
            raise RuntimeError(f"缺少 SDK：请运行 {sys.executable} -m pip install {SDK_REQUIREMENT}")
        LOG.info("当前 Python 环境缺少 SDK，正在安装 %s", SDK_REQUIREMENT)
        subprocess.check_call([
            sys.executable, "-m", "pip", "install", "--disable-pip-version-check",
            "--timeout", "60", SDK_REQUIREMENT,
        ])
    from qcloud_cos import CosConfig, CosS3Client

    return CosS3Client(CosConfig(
        Region=region, SecretId=secret_id, SecretKey=secret_key,
        Token=os.environ.get("COS_TOKEN") or None, Scheme="https", Timeout=timeout,
        PoolConnections=max(10, workers), PoolMaxSize=max(10, workers),
    ), retry=3)


def positive_int(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("必须为正整数")
    return parsed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--bucket", default=os.environ.get("COS_BUCKET"), help="存储桶名，含 APPID；也可设置 COS_BUCKET；只处理清单 bucket 与之相同的文件夹")
    parser.add_argument("--region", default=os.environ.get("COS_REGION"), help="如 ap-shanghai；也可设置 COS_REGION")
    parser.add_argument("--output-dir", type=Path, default=Path("tmp"), help="归档父目录，默认 ./tmp")
    parser.add_argument("--workers", type=positive_int, default=8, help=f"并发删除请求数，默认 8；每个请求最多 {BATCH_SIZE} 个 key")
    parser.add_argument("--attempts", type=positive_int, default=3, help="每批删除的最多尝试次数，默认 3")
    parser.add_argument("--timeout", type=positive_int, default=60, help="COS 请求超时秒数，默认 60")
    parser.add_argument("--dry-run", action="store_true", help="只列举核对并显示待删除数量，不删除、不写标记")
    parser.add_argument("--no-install-sdk", action="store_true", help="缺少 SDK 时不自动安装")
    parser.add_argument("--verbose", action="store_true", help="显示每批删除进度和异常堆栈")
    args = parser.parse_args(argv)
    if not args.bucket or not args.region:
        parser.error("需要 --bucket 和 --region，或对应的 COS_BUCKET / COS_REGION 环境变量")
    secret_id = os.environ.get("COS_SECRET_ID")
    secret_key = os.environ.get("COS_SECRET_KEY")
    if not secret_id or not secret_key:
        parser.error("请设置 COS_SECRET_ID 和 COS_SECRET_KEY 环境变量")
    if not args.output_dir.is_dir():
        parser.error(f"归档父目录不存在或不是目录：{args.output_dir.resolve()}")
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    LOG.setLevel(logging.DEBUG if args.verbose else logging.INFO)
    logging.getLogger("qcloud_cos").setLevel(logging.WARNING)
    try:
        # 先检查本地清单，发现问题时不连接 COS。
        folders, expected = load_folders(args.output_dir, args.bucket)
        if not folders:
            LOG.info("没有需要删除的文件夹")
            return 0
        LOG.info("待处理 %d 个已发布文件夹，清单共 %d 个 key", len(folders), len(expected))
        client = connect(
            args.region, secret_id, secret_key, timeout=args.timeout,
            workers=args.workers, install_sdk=not args.no_install_sdk,
        )
        return purge(
            client, args.bucket, folders, expected,
            workers=args.workers, attempts=args.attempts, dry_run=args.dry_run,
        )
    except KeyboardInterrupt:
        LOG.error("已中断；已写入 %s 的文件夹会被跳过，重新运行即可继续", DONE_MARKER)
        return 130
    except Exception as exc:
        LOG.error("任务失败：%s；重新运行即可继续", exc, exc_info=args.verbose)
        return 1


if __name__ == "__main__":
    sys.exit(main())
