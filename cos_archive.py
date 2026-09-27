#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""按 COS LastModified 分窗口并发下载，归档为 10 个 <=100MB 的 tar 分片。

Python >=3.9。首次运行缺少 SDK 时自动安装 cos-python-sdk-v5。
凭据从 COS_SECRET_ID / COS_SECRET_KEY / COS_TOKEN 环境变量读取。
示例：python cos_archive.py --bucket example-1250000000 --region ap-shanghai
"""

from __future__ import annotations

import argparse
import errno
import hashlib
import importlib.util
import io
import json
import logging
import os
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid
from contextlib import closing
from concurrent.futures import FIRST_COMPLETED, Future, ThreadPoolExecutor, wait
from dataclasses import dataclass
from datetime import datetime, timezone
from email.utils import format_datetime, parsedate_to_datetime
from pathlib import Path
from typing import Any

MB = 1_000_000  # MB，不是 MiB。
WINDOW_BYTES = 990 * MB
PART_COUNT = 10
PART_MAX_BYTES = 100 * MB
IO_CHUNK = 1024 * 1024
SDK_REQUIREMENT = "cos-python-sdk-v5==1.9.44"
LOG = logging.getLogger("cos_archive")


def parse_time(value: str) -> datetime:
    """接受 COS 返回的带时区 ISO 8601 时间，转换为 UTC。"""
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError(f"时间缺少时区：{value!r}")
    return parsed.astimezone(timezone.utc)


@dataclass(frozen=True)
class ObjectInfo:
    key: str
    last_modified: str
    size: int
    etag: str

    @property
    def archive_path(self) -> str:
        # 原始 key 可以包含 ../、绝对路径、中文、Windows 保留字符等。
        # 用完整 key 的 SHA256 作为安全文件名，manifest.json 保存反向映射。
        return "objects/" + hashlib.sha256(self.key.encode("utf-8")).hexdigest()

    def tar_info(self) -> tarfile.TarInfo:
        info = tarfile.TarInfo(self.archive_path)
        info.size = self.size
        info.mtime = int(parse_time(self.last_modified).timestamp())
        info.mode = 0o644
        return info

    def tar_bytes(self) -> int:
        # 用实际 USTAR 头计算，避免忘记 tar 开销；也验证头字段可编码。
        header = self.tar_info().tobuf(format=tarfile.USTAR_FORMAT)
        return len(header) + round_up(self.size, tarfile.BLOCKSIZE)

    def meta_entry_bytes(self) -> int:
        # 与 json.dumps(..., ensure_ascii=False, indent=2) 的 UTF-8 字节数一致。
        key = json.dumps(self.key, ensure_ascii=False).encode("utf-8")
        modified = json.dumps(self.last_modified, ensure_ascii=False).encode("utf-8")
        return 6 + len(key) + len(modified)


@dataclass(frozen=True)
class Downloaded:
    obj: ObjectInfo
    path: Path
    sha256: str


def round_up(value: int, multiple: int) -> int:
    return ((value + multiple - 1) // multiple) * multiple


def archive_bytes(member_bytes: int, meta_size: int = 3) -> int:
    # tar 根目录 meta.json（含内容）、空 .nojekyll 的头、两个结束块，
    # 并补齐 tarfile 的 10240 字节记录。
    root_files = 2 * tarfile.BLOCKSIZE + round_up(meta_size, tarfile.BLOCKSIZE)
    return round_up(member_bytes + root_files + 2 * tarfile.BLOCKSIZE, tarfile.RECORDSIZE)


def collect_objects(client: Any, bucket: str, prefix: str, db: sqlite3.Connection) -> int:
    """第一次遍历：分页收集到 SQLite，避免全部 key 常驻内存。"""
    db.execute("""CREATE TABLE objects (
        key TEXT PRIMARY KEY, last_modified TEXT NOT NULL,
        sort_time TEXT NOT NULL, size INTEGER NOT NULL, etag TEXT NOT NULL
    )""")
    marker = ""
    count = 0
    while True:
        response = client.list_objects(
            Bucket=bucket, Prefix=prefix, Delimiter="", Marker=marker, MaxKeys=1000
        )
        contents = response.get("Contents", [])
        rows = []
        for item in contents:
            key = item["Key"]
            modified = item["LastModified"]
            size = int(item["Size"])
            etag = item["ETag"]
            if not isinstance(key, str) or not key or size < 0 or not etag:
                raise ValueError(f"COS 列表中的对象信息不完整：{key!r}")
            sort_time = parse_time(modified).isoformat(timespec="microseconds")
            rows.append((key, modified, sort_time, size, etag))
        db.executemany("INSERT INTO objects VALUES (?, ?, ?, ?, ?)", rows)
        db.commit()
        count += len(rows)
        LOG.info("已收集 %d 个对象", count)
        if str(response.get("IsTruncated", "false")).lower() != "true":
            break
        next_marker = response.get("NextMarker") or (
            contents[-1]["Key"] if contents else ""
        )
        if not next_marker or next_marker <= marker:
            raise RuntimeError("COS 分页游标没有前进，停止以避免死循环")
        marker = next_marker
    db.execute("CREATE INDEX objects_by_time ON objects(sort_time, key)")
    db.commit()
    return count


def download_object(
    client: Any, bucket: str, obj: ObjectInfo, path: Path, attempts: int
) -> Downloaded:
    """流式保存原始字节；条件 GET 避免列表收集后对象被覆盖。"""
    LOG.debug("下载 %r（%d 字节）", obj.key, obj.size)
    for attempt in range(1, attempts + 1):
        try:
            response = client.get_object(
                Bucket=bucket,
                Key=obj.key,
                IfMatch=obj.etag,
                IfUnmodifiedSince=format_datetime(
                    parse_time(obj.last_modified).replace(microsecond=0), usegmt=True
                ),
            )
            raw = response["Body"].get_raw_stream()
            with closing(raw):
                headers = {str(k).lower(): v for k, v in response.items() if k != "Body"}
                if int(headers.get("content-length", obj.size)) != obj.size:
                    raise RuntimeError(f"下载的 Content-Length 与列表不一致：{obj.key!r}")
                if headers.get("etag", obj.etag) != obj.etag:
                    raise RuntimeError(f"对象 ETag 已变化：{obj.key!r}")
                if "last-modified" in headers:
                    downloaded_time = parsedate_to_datetime(headers["last-modified"])
                    if int(downloaded_time.timestamp()) != int(parse_time(obj.last_modified).timestamp()):
                        raise RuntimeError(f"对象 LastModified 已变化：{obj.key!r}")
                digest = hashlib.sha256()
                written = 0
                with path.open("wb") as output:
                    while True:
                        # requests.iter_content 会自动解压 Content-Encoding:gzip；
                        # 这里保留 COS 对象原始字节，以免改变内容和大小。
                        chunk = raw.read(IO_CHUNK, decode_content=False)
                        if not chunk:
                            break
                        written += len(chunk)
                        if written > obj.size:
                            raise RuntimeError(f"下载字节数超过列表记录：{obj.key!r}")
                        output.write(chunk)
                        digest.update(chunk)
                if written != obj.size:
                    raise RuntimeError(f"下载不完整：{obj.key!r}，{written}/{obj.size} 字节")
                return Downloaded(obj, path, digest.hexdigest())
        except Exception as exc:
            path.unlink(missing_ok=True)
            # requests 的网络异常也可能继承 OSError；只把明确的本地错误
            # 视为不可重试，避免误伤连接失败的重试。
            if isinstance(exc, OSError) and (
                exc.filename is not None or exc.errno in {errno.ENOSPC, errno.EACCES, errno.EROFS}
            ):
                raise
            status_getter = getattr(exc, "get_status_code", None)
            status = str(status_getter()) if callable(status_getter) else ""
            if attempt == attempts or status in {"400", "401", "403", "404", "412", "416"}:
                raise RuntimeError(f"无法下载对象 {obj.key!r}：{exc}") from exc
            LOG.warning("下载 %r 失败，准备重试 %d/%d：%s", obj.key, attempt + 1, attempts, exc)
            time.sleep(min(2 ** (attempt - 1), 8))
    raise AssertionError("attempts 必须为正数")


def download_window(
    client: Any, bucket: str, window: list[tuple[ObjectInfo, Path]],
    executor: ThreadPoolExecutor, *, workers: int, attempts: int,
) -> list[Downloaded]:
    """限制未完成的任务数，并按输入时间顺序返回下载结果。"""
    jobs = iter(enumerate(window))
    pending: dict[Future[Downloaded], int] = {}
    results: dict[int, Downloaded] = {}

    def fill_slots() -> None:
        while len(pending) < workers:
            try:
                index, (obj, path) = next(jobs)
            except StopIteration:
                return
            future = executor.submit(download_object, client, bucket, obj, path, attempts)
            pending[future] = index

    try:
        fill_slots()
        while pending:
            done, _ = wait(pending, return_when=FIRST_COMPLETED)
            # 先检查本轮完成的所有任务，再补任务；发现错误后不再发起新下载。
            for future in done:
                index = pending.pop(future)
                results[index] = future.result()
            fill_slots()
    except BaseException:
        for future in pending:
            future.cancel()
        # 运行中的线程结束前不能删除缓存，否则 Windows 会遇到文件占用，
        # 或者下载线程在清理后继续写出文件。
        wait(pending)
        raise
    return [results[index] for index in range(len(window))]


class SplitTarWriter:
    """将一个 tar 字节流均分为恰好 10 片，直接写入最终分片。"""

    def __init__(self, folder: Path, total_bytes: int, part_max: int):
        quotient, remainder = divmod(total_bytes, PART_COUNT)
        self.lengths = [quotient + (i < remainder) for i in range(PART_COUNT)]
        if min(self.lengths) <= 0 or max(self.lengths) > part_max:
            raise ValueError("tar 总大小无法分为 10 个符合大小限制的非空分片")
        self.folder = folder
        self.expected = total_bytes
        self.written = 0
        self.part_written = 0
        self.index = 0
        self.file = None
        self.digest = hashlib.sha256()
        self.parts: list[dict[str, Any]] = []

    def write(self, data: bytes) -> int:
        if self.written + len(data) > self.expected:
            raise RuntimeError("tar 实际大小超过预算，停止写入")
        view = memoryview(data)
        offset = 0
        while offset < len(view):
            if self.file is None:
                self.file = (self.folder / f"archive.tar.part{self.index + 1:02d}").open("xb")
                self.digest = hashlib.sha256()
            length = min(len(view) - offset, self.lengths[self.index] - self.part_written)
            chunk = view[offset:offset + length]
            self.file.write(chunk)
            self.digest.update(chunk)
            self.written += length
            self.part_written += length
            offset += length
            if self.part_written == self.lengths[self.index]:
                self.file.close()
                self.file = None
                self.parts.append({
                    "name": f"archive.tar.part{self.index + 1:02d}",
                    "size": self.part_written,
                    "sha256": self.digest.hexdigest(),
                })
                self.index += 1
                self.part_written = 0
        return len(data)

    def verify(self) -> None:
        if self.written != self.expected or len(self.parts) != PART_COUNT:
            raise RuntimeError("tar 分片数量或总大小与预算不符")
        for part in self.parts:
            if (self.folder / part["name"]).stat().st_size != part["size"]:
                raise RuntimeError("tar 分片实际大小与记录不符")

    def close(self) -> None:
        if self.file is not None:
            self.file.close()
            self.file = None


def write_json(path: Path, value: Any) -> None:
    with path.open("w", encoding="utf-8", newline="\n") as file:
        json.dump(value, file, ensure_ascii=False, indent=2)
        file.write("\n")


def publish_window(
    items: list[Downloaded], output_dir: Path, bucket: str,
    window_limit: int, part_max: int,
) -> Path:
    meta = {item.obj.key: item.obj.last_modified for item in items}
    meta_content = (json.dumps(meta, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    total_bytes = archive_bytes(sum(item.obj.tar_bytes() for item in items), len(meta_content))
    folder_id = str(uuid.uuid4())
    # 全部完成后才改名为 UUID 文件夹；失败不会留下看似完整的结果。
    with tempfile.TemporaryDirectory(prefix=".cos-pending-", dir=output_dir) as pending:
        staging = Path(pending)
        with closing(SplitTarWriter(staging, total_bytes, part_max)) as writer:
            with tarfile.open(
                mode="w|", fileobj=writer, format=tarfile.USTAR_FORMAT,
                bufsize=IO_CHUNK, copybufsize=IO_CHUNK,
            ) as archive:
                meta_info = tarfile.TarInfo("meta.json")
                meta_info.size = len(meta_content)
                meta_info.mode = 0o644
                archive.addfile(meta_info, io.BytesIO(meta_content))
                nojekyll_info = tarfile.TarInfo(".nojekyll")
                nojekyll_info.mode = 0o644
                archive.addfile(nojekyll_info)
                for item in items:
                    with item.path.open("rb") as source:
                        archive.addfile(item.obj.tar_info(), source)
            writer.verify()
            parts = writer.parts
        (staging / "meta.json").write_bytes(meta_content)
        write_json(staging / "manifest.json", {
            "format": "tar-byte-split-v1",
            "folder_id": folder_id,
            "bucket": bucket,
            "time_source": "LastModified",
            "order": "LastModified ASC, key ASC",
            "mb_bytes": MB,
            "window_limit_bytes": window_limit,
            "payload_bytes": sum(item.obj.size for item in items),
            "tar_bytes": total_bytes,
            "tar_root_files": ["meta.json", ".nojekyll"],
            "part_max_bytes": part_max,
            "parts": parts,
            "objects": [{
                "id": item.obj.key,
                "archive_path": item.obj.archive_path,
                "size": item.obj.size,
                "last_modified": item.obj.last_modified,
                "etag": item.obj.etag,
                "sha256": item.sha256,
            } for item in items],
        })
        final = output_dir / folder_id
        staging.rename(final)
    return final


def export_bucket(
    client: Any, bucket: str, prefix: str, output_dir: Path, *,
    max_folders: int = 10, window_limit: int = WINDOW_BYTES,
    part_max: int = PART_MAX_BYTES, temp_dir: Path | None = None,
    attempts: int = 3, skip_oversized: bool = False, workers: int = 8,
) -> list[Path]:
    """按时间分配窗口，在单个窗口内并发下载；对象不跨文件夹切割。"""
    if min(max_folders, window_limit, part_max, attempts, workers) <= 0:
        raise ValueError("数量、大小限制、尝试次数和并发数必须为正数")
    if temp_dir is not None:
        temp_dir.mkdir(parents=True, exist_ok=True)
    output_dir.mkdir(parents=True, exist_ok=True)
    completed: list[Path] = []
    with tempfile.TemporaryDirectory(prefix="cos-download-", dir=temp_dir) as scratch:
        scratch_path = Path(scratch)
        with ThreadPoolExecutor(max_workers=workers, thread_name_prefix="cos-download") as executor, \
                closing(sqlite3.connect(scratch_path / "index.sqlite3")) as db:
            count = collect_objects(client, bucket, prefix, db)
            LOG.info("收集完成：%d 个对象，按时间分窗口，并发下载数 %d", count, workers)
            window: list[tuple[ObjectInfo, Path]] = []
            payload = 0
            tar_members = 0
            meta_size = 3  # 空 JSON 映射与结尾换行。

            def flush() -> None:
                nonlocal payload, tar_members, meta_size
                LOG.info("下载窗口 %d：%d 个对象，%.3f MB，并发数 %d",
                         len(completed) + 1, len(window), payload / MB, workers)
                downloaded_items = download_window(
                    client, bucket, window, executor, workers=workers, attempts=attempts
                )
                folder = publish_window(downloaded_items, output_dir, bucket, window_limit, part_max)
                completed.append(folder)
                LOG.info("完成文件夹 %d/%d：%s；%d 个对象，%.3f MB",
                         len(completed), max_folders, folder.name, len(window), payload / MB)
                for downloaded in downloaded_items:
                    downloaded.path.unlink()
                window.clear()
                payload = 0
                tar_members = 0
                meta_size = 3

            # 显式关闭尚未读完的游标，Windows 才能在提前返回时删除 SQLite 文件。
            with closing(db.execute(
                "SELECT key, last_modified, size, etag FROM objects ORDER BY sort_time, key"
            )) as rows:
                for index, row in enumerate(rows):
                    obj = ObjectInfo(*row)
                    cost = obj.tar_bytes()
                    meta_cost = obj.meta_entry_bytes()
                    # 先结束上一窗口，再决定是否处理当前对象。到达上限时不下载下一对象。
                    if window and (payload + obj.size > window_limit or
                                   archive_bytes(tar_members + cost, meta_size + meta_cost) > PART_COUNT * part_max):
                        flush()
                        if len(completed) >= max_folders:
                            return completed
                    if obj.size > window_limit or archive_bytes(cost, 3 + meta_cost) > PART_COUNT * part_max:
                        message = f"对象 {obj.key!r}（{obj.size} 字节）无法装入一个窗口"
                        if skip_oversized:
                            LOG.warning("%s，按 --skip-oversized 跳过", message)
                            continue
                        raise ValueError(message + "；可显式使用 --skip-oversized")
                    # 只分配当前窗口的对象；先按列表大小预留容量，再并发下载。
                    window.append((obj, scratch_path / f"object-{index:012d}"))
                    payload += obj.size
                    tar_members += cost
                    meta_size += meta_cost
                    if payload == window_limit or archive_bytes(tar_members, meta_size) == PART_COUNT * part_max:
                        flush()
                        if len(completed) >= max_folders:
                            return completed
            # COS 遍历结束：下载并保存最后一个未满窗口。
            if window:
                flush()
    return completed


def positive_int(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("必须为正整数")
    return parsed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--bucket", default=os.environ.get("COS_BUCKET"), help="存储桶名，含 APPID；也可设置 COS_BUCKET")
    parser.add_argument("--region", default=os.environ.get("COS_REGION"), help="如 ap-shanghai；也可设置 COS_REGION")
    parser.add_argument("--prefix", default="", help="仅收集此 key 前缀下的对象；默认整个桶")
    parser.add_argument("--output-dir", type=Path, default=Path("cos_archives"), help="输出父目录，默认 ./cos_archives")
    parser.add_argument("--temp-dir", type=Path, help="下载缓存和 SQLite 临时目录，默认系统临时目录")
    parser.add_argument("--max-folders", type=positive_int, default=10, help="本次运行最多创建的文件夹数量，默认 10")
    parser.add_argument("--window-mb", type=positive_int, default=990, help="对象原始字节窗口上限，1~990 MB，默认 990")
    parser.add_argument("--workers", type=positive_int, default=8, help="并发下载对象数，默认 8；设为 1 使用串行下载")
    parser.add_argument("--attempts", type=positive_int, default=3, help="完整下载的最多尝试次数，默认 3")
    parser.add_argument("--timeout", type=positive_int, default=60, help="COS 请求超时秒数，默认 60")
    parser.add_argument("--skip-oversized", action="store_true", help="显式跳过无法装入单个窗口的对象；默认报错")
    parser.add_argument("--no-install-sdk", action="store_true", help="缺少 SDK 时不自动安装")
    parser.add_argument("--verbose", action="store_true", help="显示每个对象的下载进度和异常堆栈")
    args = parser.parse_args(argv)
    if args.window_mb > 990:
        parser.error("--window-mb 必须在 1~990 之间")
    if not args.bucket or not args.region:
        parser.error("需要 --bucket 和 --region，或对应的 COS_BUCKET / COS_REGION 环境变量")
    secret_id = os.environ.get("COS_SECRET_ID")
    secret_key = os.environ.get("COS_SECRET_KEY")
    if not secret_id or not secret_key:
        parser.error("请设置 COS_SECRET_ID 和 COS_SECRET_KEY 环境变量")
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    LOG.setLevel(logging.DEBUG if args.verbose else logging.INFO)
    logging.getLogger("qcloud_cos").setLevel(logging.WARNING)
    try:
        if importlib.util.find_spec("qcloud_cos") is None:
            if args.no_install_sdk:
                raise RuntimeError(f"缺少 SDK：请运行 {sys.executable} -m pip install {SDK_REQUIREMENT}")
            LOG.info("当前 Python 环境缺少 SDK，正在安装 %s", SDK_REQUIREMENT)
            subprocess.check_call([
                sys.executable, "-m", "pip", "install", "--disable-pip-version-check",
                "--timeout", "60", SDK_REQUIREMENT,
            ])
        from qcloud_cos import CosConfig, CosS3Client

        client = CosS3Client(CosConfig(
            Region=args.region, SecretId=secret_id, SecretKey=secret_key,
            Token=os.environ.get("COS_TOKEN") or None, Scheme="https", Timeout=args.timeout,
            PoolConnections=max(10, args.workers), PoolMaxSize=max(10, args.workers),
        ), retry=3)
        folders = export_bucket(
            client, args.bucket, args.prefix, args.output_dir,
            max_folders=args.max_folders, window_limit=args.window_mb * MB,
            temp_dir=args.temp_dir, attempts=args.attempts, skip_oversized=args.skip_oversized,
            workers=args.workers,
        )
        LOG.info("结束，本次创建 %d 个文件夹；输出目录：%s", len(folders), args.output_dir.resolve())
        return 0
    except KeyboardInterrupt:
        LOG.error("已中断；已完成的 UUID 文件夹保留")
        return 130
    except Exception as exc:
        LOG.error("任务失败：%s；已完成的 UUID 文件夹保留", exc, exc_info=args.verbose)
        return 1


if __name__ == "__main__":
    sys.exit(main())
