# COS 按时间分窗口归档

脚本：`cos_archive.py`。需要 Python 3.9 及以上。

## 安装与运行

第一次实际运行时，如果当前 Python 环境没有 SDK，脚本会自动通过 pip 安装腾讯 `cos-python-sdk-v5`。也可提前安装：

```bash
python -m pip install -r requirements.txt
```

Linux / macOS：

```bash
export COS_SECRET_ID='你的 SecretId'
export COS_SECRET_KEY='你的 SecretKey'
# 临时凭据还需要：export COS_TOKEN='你的 Token'

python cos_archive.py \
  --bucket example-1250000000 \
  --region ap-shanghai \
  --output-dir ./cos_archives \
  --max-folders 10
```

PowerShell：

```powershell
$env:COS_SECRET_ID = '你的 SecretId'
$env:COS_SECRET_KEY = '你的 SecretKey'
# 临时凭据还需要：$env:COS_TOKEN = '你的 Token'

python .\cos_archive.py --bucket example-1250000000 --region ap-shanghai --output-dir .\cos_archives --max-folders 10
```

`--bucket` 包含 APPID；桶和地域也可用 `COS_BUCKET`、`COS_REGION` 环境变量提供。
`python cos_archive.py --help` 可查看完整参数，不需要 SDK 或凭据。

## 收集规则

1. 第一次遍历使用 `list_objects` 完整分页收集 key、`LastModified`、大小、ETag，存入临时 SQLite 数据库。
2. 数据库按 `LastModified` 从旧到新排序，相同时间按完整 key 排序；第二次依此顺序下载。默认包含零字节对象和目录占位对象。
3. 使用不重叠的窗口积累完整对象，原始对象大小合计最多 990MB。如果下一对象放不下，先归档当前窗口，再下载下一对象。
4. tar 头、每个对象的 512 字节对齐填充、根目录 `meta.json` 的内容、空 `.nojekyll`、结束块和 10240 字节记录对齐都计入预算。若 tar 开销将超过十片的总容量，窗口也会提前结束。因此大量小对象可能导致窗口明显小于 990MB。
5. 每个窗口写成一个未压缩 tar，直接流式切成恰好 **10 个近似等大的字节分片**，各片严格 **≤100MB**。tar 根目录包含 `meta.json` 和空文件 `.nojekyll`。文件夹名由 `uuid.uuid4()` 生成，文件夹中另写一份相同的 `meta.json` 和 `manifest.json`。
6. `--max-folders` 默认 10，达到上限立即停止下载。它限制的是**本次运行新建的文件夹数**，不包含以前的运行结果。最后不足一个窗口的对象也归档，计作一个文件夹；空桶不会创建 UUID 文件夹。

所有 MB 都是十进制：1MB = 1,000,000 字节。990MB 对象数据加 tar 开销并不天然保证十片均 ≤100MB；本脚本通过实际头大小和填充预算保证上限，写完后再验证大小。

腾讯 COS 列表提供的 `LastModified` 是**最后修改时间**，本脚本按你的选择把它作为目标时间。如果某个 key 被覆盖过，它不是该 key 第一次创建的时间。[腾讯 SDK 对象列表实现](https://github.com/tencentyun/cos-python-sdk-v5/blob/master/qcloud_cos/cos_client.py)；[腾讯时间字段说明](https://intl.cloud.tencent.com/ko/document/product/436/44066)。

## 输出内容

```text
cos_archives/
└── 7f7b3481-0bb6-4d67-8752-4ce7a9ddf217/
    ├── archive.tar.part01
    ├── archive.tar.part02
    ├── ...
    ├── archive.tar.part10
    ├── meta.json
    └── manifest.json
```

`meta.json` 为 **完整 COS key → 原始 LastModified 字符串**，例如：

```json
{
  "images/a.jpg": "2026-09-01T08:00:00.000Z",
  "images/b.jpg": "2026-09-02T08:00:00.000Z"
}
```

tar 内文件名为 `objects/<完整 key 的 SHA256>`。这种命名可保存 `../`、中文、特殊字符、目录占位对象等 key，避免本地路径冲突和跨平台文件名问题。完整 key、tar 路径、原始大小、时间、ETag、对象 SHA256 和每个分片的 SHA256 都在 `manifest.json` 中保存。

这些是**一个 tar 的十个字节分片**，单片不能独立解压。按 `part01` 到 `part10` 顺序合并后才是完整 tar。

Linux / macOS 合并、解包：

```bash
cd cos_archives/某个UUID文件夹
cat archive.tar.part{01..10} > archive.tar
mkdir restored
tar -xf archive.tar -C restored
```

跨平台用 Python 合并，在 UUID 文件夹执行：

```python
from pathlib import Path
import shutil

with Path("archive.tar").open("wb") as target:
    for number in range(1, 11):
        with Path(f"archive.tar.part{number:02d}").open("rb") as source:
            shutil.copyfileobj(source, target, 1024 * 1024)
```

随后可使用系统 tar 或 Python `tarfile` 解包。tar 内部结构如下；解包得到的文件名与 COS key 的对应关系见 UUID 文件夹中的 `manifest.json`。

```text
meta.json
.nojekyll
objects/
└── <完整 COS key 的 SHA256>
```

## 边界与资源

- 单个对象大于窗口，或单对象 tar 大小无法放进十片总容量时，默认报错。可显式传 `--skip-oversized` 跳过并记录警告；默认不会静默漏对象。可用 `--window-mb` 把窗口调小，范围 1～990。
- 下载使用条件 GET（ETag 和最后修改时间），并校验响应头、实际字节数，避免列表和下载之间对象变化后混入错误时间。HTTP 400/401/403/404/412/416 立即失败；其他非磁盘错误最多尝试 `--attempts` 次，默认 3。
- 下载保留原始字节，即便对象设置了 `Content-Encoding: gzip` 也不会自动解压。
- 网络读取和 tar 拷贝缓冲为 1MiB；对象内容不会把 990MB 全部放到内存。对象清单在磁盘 SQLite 中排序，当前窗口的元数据仍占用内存。
- 下载缓存最多约 990MB，另有 SQLite 索引；不另写整份中间 tar，直接生成分片。`--temp-dir` 可指定缓存所在磁盘。输出磁盘最多约 10GB tar 数据，另外需要 JSON 元数据空间。
- 文件夹完整写好后才改名为 UUID；中途出错时保留此前完成的文件夹，删除本次尚未完成的缓存。没有断点续传：重新运行会从头收集、下载，产生新的 UUID 文件夹。
- 操作仅列举和读取 COS 当前对象，不收集历史版本，不执行上传或删除。归档存储对象需要已可读取，脚本不会自动恢复冷归档对象。

本地已在当前工作目录的虚拟环境安装 `cos-python-sdk-v5==1.9.44`。16 项自动测试全部通过，另用真实腾讯 SDK 连接本地模拟 HTTP 服务，验证了 3 页对象列表、中文 key、时间排序、原始 gzip 字节下载、分片合并，以及 tar 根目录的 `meta.json` 和空 `.nojekyll`。依赖检查也通过。尚未连接实际 COS 桶；实际运行需要你提供环境变量和桶配置。
