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
4. tar 头、每个对象的 512 字节对齐填充、结束块和 10240 字节记录对齐都计入预算。若 tar 开销将超过 30 片的总容量，窗口也会提前结束。因此大量小对象可能导致窗口明显小于 990MB。
5. 每个窗口写成一个只包含对象数据的未压缩 tar，直接流式切成恰好 **30 个近似等大的字节分片**，各片严格 **≤100MB**。文件夹名由 `uuid.uuid4()` 生成，文件夹中另写 `manifest.json`，保存对象和分片清单。
6. `--max-folders` 默认 10，达到上限立即停止下载。它限制的是**本次运行新建的文件夹数**，不包含以前的运行结果。最后不足一个窗口的对象也归档，计作一个文件夹；空桶不会创建 UUID 文件夹。

所有 MB 都是十进制：1MB = 1,000,000 字节。本脚本通过实际头大小和填充预算保证 30 片均 ≤100MB，写完后再验证大小。

腾讯 COS 列表提供的 `LastModified` 是**最后修改时间**，本脚本按你的选择把它作为目标时间。如果某个 key 被覆盖过，它不是该 key 第一次创建的时间。[腾讯 SDK 对象列表实现](https://github.com/tencentyun/cos-python-sdk-v5/blob/master/qcloud_cos/cos_client.py)；[腾讯时间字段说明](https://intl.cloud.tencent.com/ko/document/product/436/44066)。

## 输出内容

```text
cos_archives/
└── 7f7b3481-0bb6-4d67-8752-4ce7a9ddf217/
    ├── archive.tar.part01
    ├── archive.tar.part02
    ├── ...
    ├── archive.tar.part30
    └── manifest.json
```

`manifest.json` 的 `objects` 数组保存完整 COS key、tar 中的文件路径、大小、原始 LastModified、ETag 和对象 SHA256。例如，其中的对象记录如下：

```json
{
  "id": "images/a.jpg",
  "archive_path": "objects/<完整 COS key 的 SHA256>",
  "size": 1234,
  "last_modified": "2026-09-01T08:00:00.000Z",
  "etag": "<COS ETag>",
  "sha256": "<对象内容的 SHA256>"
}
```

tar 内文件名为 `objects/<完整 key 的 SHA256>`。这种命名可保存 `../`、中文、特殊字符、目录占位对象等 key，避免本地路径冲突和跨平台文件名问题。`manifest.json` 的 `part_count` 为 30，`parts` 数组按顺序保存每个分片的名称、大小和 SHA256。清单位于 UUID 文件夹中，不写入 tar；tar 中没有额外的根目录文件，`tar_root_files` 为空数组。

这些是**一个 tar 的 30 个字节分片**，单片不能独立解压。按 `part01` 到 `part30` 顺序合并后才是完整 tar。

Linux / macOS 合并、解包：

```bash
cd cos_archives/某个UUID文件夹
cat archive.tar.part{01..30} > archive.tar
mkdir restored
tar -xf archive.tar -C restored
```

跨平台用 Python 合并，在 UUID 文件夹执行：

```python
from pathlib import Path
import shutil

with Path("archive.tar").open("wb") as target:
    for number in range(1, 31):
        with Path(f"archive.tar.part{number:02d}").open("rb") as source:
            shutil.copyfileobj(source, target, 1024 * 1024)
```

随后可使用系统 tar 或 Python `tarfile` 解包。tar 内部结构如下；解包得到的文件名与 COS key 的对应关系见 UUID 文件夹中的 `manifest.json`。

```text
objects/
└── <完整 COS key 的 SHA256>
```

## 边界与资源

- 单个对象大于窗口，或单对象 tar 大小无法放进 30 片总容量时，默认报错。可显式传 `--skip-oversized` 跳过并记录警告；默认不会静默漏对象。可用 `--window-mb` 把窗口调小，范围 1～990。
- 下载使用条件 GET（ETag 和最后修改时间），并校验响应头、实际字节数，避免列表和下载之间对象变化后混入错误时间。HTTP 400/401/403/404/412/416 立即失败；其他非磁盘错误最多尝试 `--attempts` 次，默认 3。
- 下载保留原始字节，即便对象设置了 `Content-Encoding: gzip` 也不会自动解压。
- 网络读取和 tar 拷贝缓冲为 1MiB；对象内容不会把 990MB 全部放到内存。对象清单在磁盘 SQLite 中排序，当前窗口的元数据仍占用内存。
- 下载缓存最多约 990MB，另有 SQLite 索引；不另写整份中间 tar，直接生成分片。`--temp-dir` 可指定缓存所在磁盘。每个窗口 tar 总大小最多 30×100MB，默认最多创建 10 个文件夹，输出磁盘最多约 30GB tar 数据，另外需要清单空间。
- 文件夹完整写好后才改名为 UUID；中途出错时保留此前完成的文件夹，删除本次尚未完成的缓存。没有断点续传：重新运行会从头收集、下载，产生新的 UUID 文件夹。
- 操作仅列举和读取 COS 当前对象，不收集历史版本，不执行上传或删除。归档存储对象需要已可读取，脚本不会自动恢复冷归档对象。

## 发布到 GitHub Pages

`publish.sh` 接收一个包含 `archive.tar.part01` 到 `archive.tar.part30` 的 UUID 文件夹，创建同名公开 GitHub 仓库，通过 GitHub Actions 构建和部署 Pages。需要 Bash、Git、GitHub CLI（`gh`）、curl、tar、tee，以及 Python 3.9 及以上（`python3` 或 `python`）；Python 只使用标准库。本地文件夹不需要 `index.html`。

```bash
export GH_TOKEN='你的 GitHub PAT'
bash publish.sh ./cos_archives/某个UUID文件夹
# 可选：发布到指定账号或组织
bash publish.sh ./cos_archives/某个UUID文件夹 my-organization
```

PAT 需要创建公开仓库、推送内容和工作流、管理 Pages 设置、触发及读取 Actions 的权限。使用 classic PAT 时，需要相应的仓库权限和 `workflow` scope。不提供环境变量时，脚本会在交互终端中隐藏输入 PAT。

脚本每次在目标文件夹生成 `.github/workflows/deploy-pages.yml`，默认覆盖同名旧工作流，使新模板生效。工作流会按 `01` 到 `30` 的顺序合并 tar 切片，解压到仓库根目录，再创建内容为 `ok` 的根目录 `index.html`。归档和发布流程均不再生成 `meta.json` 或 `.nojekyll`。运行环境中的切片会在解压后移除，部署包包含解压后的文件、`manifest.json` 及其他站点文件，本地切片保持完整。

上传时，每个文件单独提交：先按顺序上传 30 个切片，再上传其他文件，最后上传 `.github/workflows/` 中的文件。默认通过 curl 调用 GitHub 的 Git 数据库 API，逐个写入文件对象、目录和提交，再更新 `main`，大文件不再通过 `git push` 发送。`gh` 负责账号、仓库、Pages 和 Actions 设置。使用同一个 PAT 即可；API 请求中的二进制内容使用 Base64 编码，网络数据量约增加三分之一。参见 [GitHub 文件对象 API](https://docs.github.com/en/rest/git/blobs)。空仓库先通过一个不含文件的 Git 提交建立 `main`；已有部分上传的仓库直接继续。Git 仅推送这个很小的初始化提交，并读取远程提交和目录元数据。

API 上传使用 curl 的 HTTP/1.1，明确设置 JSON 的 `Content-Type` 和请求文件的 `Content-Length`，禁用分块传输和 `Expect: 100-continue`。连接超时为 30 秒，单次请求总超时默认 900 秒；沿用代理环境变量和 VPN 网络。PAT 通过标准输入传给 curl，不写入文件或命令参数。上传前后核对文件的 Git 哈希，并校验服务器返回的目录哈希，只允许快进更新分支。更新成功后如果响应丢失，重试时会确认远程提交，避免再次发送该文件。同一次运行中，已成功写入的文件对象、目录和提交也会复用。写请求之间至少间隔 1 秒；若触发 API 限流，脚本停止并保留进度，待限制重置后可重新执行。参见 [GitHub API 限流说明](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api)。HTTP 400、413、422 会打印失败接口、请求大小和 GitHub 请求 ID（若响应提供）后停止，避免反复发送同一个被拒绝的请求。

上传提交带有 `[skip ci]`，避免尚未上传完整时启动构建；所有文件上传完成后，脚本再手动触发部署工作流。参见 [GitHub 跳过工作流的说明](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/skip-workflow-runs)。每个文件默认最多尝试上传 8 次，重试间隔依次为 5、10、20、40、60、60、60 秒。再次运行会跳过已提交到远程的相同文件，可以直接接着原来的 Git 上传进度继续。

`PUBLISH_UPLOAD_METHOD` 默认是 `api`。设为 `git` 可使用原来的逐文件 Git 推送；设为 `auto` 则先使用 Git，连续两次 HTTP 408 后切换为 API，当前和后续文件均使用 API。Git 连接使用 HTTP/1.1、并发 1，POST 缓冲按文件大小加 8MiB 计算、最大 128MiB；打包使用单线程、压缩等级 1，并关闭差量搜索。连续低于 1 字节/秒达 600 秒才中止传输。这些 Git 参数不会延长服务器或代理自身的请求期限，也不作用于 API 请求，含义见 [Git 配置文档](https://git-scm.com/docs/git-config)。

```bash
export PUBLISH_UPLOAD_METHOD=api      # 默认 api；可选 git、auto
export PUBLISH_PUSH_ATTEMPTS=12       # 1～20，默认 8，适用于 API 和 Git
export PUBLISH_API_TIMEOUT=900       # 1～7200 秒，默认 900，只影响 API 上传
export PUBLISH_LOW_SPEED_TIME=900     # 1～3600 秒，默认 600，只影响 Git
bash publish.sh ./cos_archives/某个UUID文件夹
```

Pages 使用 `build_type: workflow`，由 `configure-pages`、`upload-pages-artifact` 和 `deploy-pages` 部署，详情见 [GitHub 自定义 Pages 工作流文档](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages)。脚本启用 Pages 后触发工作流，最多等待 30 分钟，仅在当前提交的工作流部署成功后，在本地目标文件夹写入空 `SUCCESS` 标记。失败、取消或等待超时都不会生成该标记；再次执行时，如果已有 `SUCCESS`，会直接跳过，不需要凭据或发布工具。

脚本默认创建新仓库。同名仓库已存在但尚无 Git 引用（空仓库）时，会直接继续推送。已有部分文件时，脚本检查远程 `main`：已上传的数据文件必须与本地对应文件一致，随后跳过这些文件，只继续上传缺少的文件。脚本生成的 `deploy-pages.yml` 允许替换为当前模板；本地旧的根目录 `meta.json` 和 `.nojekyll` 不再上传，远程的对应旧文件会被清理。检查时仅获取提交和目录元数据，避免重新下载切片内容。其他远程文件缺少本地对应文件或内容不同，则报错，不覆盖这些文件。工作流也支持推送到 `main` 或手动触发。
