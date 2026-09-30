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
  --output-dir ./tmp \
  --max-folders 10
```

PowerShell：

```powershell
$env:COS_SECRET_ID = '你的 SecretId'
$env:COS_SECRET_KEY = '你的 SecretKey'
# 临时凭据还需要：$env:COS_TOKEN = '你的 Token'

python .\cos_archive.py --bucket example-1250000000 --region ap-shanghai --output-dir .\tmp --max-folders 10
```

`--bucket` 包含 APPID；桶和地域也可用 `COS_BUCKET`、`COS_REGION` 环境变量提供。`--output-dir` 默认为 `./tmp`。
`python cos_archive.py --help` 可查看完整参数，不需要 SDK 或凭据。

## 收集规则

1. 第一次遍历使用 `list_objects` 完整分页收集 key、`LastModified`、大小、ETag，存入临时 SQLite 数据库。
2. 读取输出目录（默认 `./tmp`）中每个子文件夹的 `manifest.json`，其中同一存储桶的 key 视为已归档，本次跳过。已发布（有 `SUCCESS`、切片已删除）和尚未发布的文件夹都计入；清单的 `bucket` 与本次 `--bucket` 不同时不计入。以 `.` 开头的目录（如中断后残留的 `.cos-pending-*`）和普通文件与 `publish.sh --all` 一样忽略。其他子文件夹缺少 `manifest.json` 或清单无法解析时报错退出，不猜测哪些 key 已归档。
3. 数据库按 `LastModified` 从旧到新排序，相同时间按完整 key 排序；第二次依此顺序下载。默认包含零字节对象和目录占位对象。
4. 使用不重叠的窗口积累完整对象，原始对象大小合计最多 990MB。如果下一对象放不下，先归档当前窗口，再下载下一对象。
5. tar 头、每个对象的 512 字节对齐填充、结束块和 10240 字节记录对齐都计入预算。若 tar 开销将超过 10 片的总容量，窗口也会提前结束。因此大量小对象可能导致窗口明显小于 990MB。
6. 每个窗口写成一个只包含对象数据的未压缩 tar，直接流式切成恰好 **10 个近似等大的字节分片**，各片严格 **≤100MB**。文件夹名由 `uuid.uuid4()` 生成，文件夹中另写 `manifest.json`，保存对象和分片清单。
7. `--max-folders` 默认 10，达到上限立即停止下载。它限制的是**本次运行新建的文件夹数**，不包含以前的运行结果。最后不足一个窗口的对象也归档，计作一个文件夹；空桶或所有对象都已归档时不会创建 UUID 文件夹。

所有 MB 都是十进制：1MB = 1,000,000 字节。本脚本通过实际头大小和填充预算保证 10 片均 ≤100MB，写完后再验证大小。

腾讯 COS 列表提供的 `LastModified` 是**最后修改时间**，本脚本按你的选择把它作为目标时间。如果某个 key 被覆盖过，它不是该 key 第一次创建的时间。[腾讯 SDK 对象列表实现](https://github.com/tencentyun/cos-python-sdk-v5/blob/master/qcloud_cos/cos_client.py)；[腾讯时间字段说明](https://intl.cloud.tencent.com/ko/document/product/436/44066)。

## 输出内容

```text
tmp/
└── 7f7b3481-0bb6-4d67-8752-4ce7a9ddf217/
    ├── archive.tar.part01
    ├── archive.tar.part02
    ├── ...
    ├── archive.tar.part10
    └── manifest.json
```

`manifest.json` 的 `objects` 数组只保存完整 COS key、大小和原始 LastModified，不再写入 `archive_path`、`etag` 和对象 `sha256`。例如，其中的对象记录如下：

```json
{
  "id": "images/a.jpg",
  "size": 1234,
  "last_modified": "2026-09-01T08:00:00.000Z"
}
```

tar 内文件路径直接使用完整 COS key，不加前缀，也不做转换，与 `id` 相同。`manifest.json` 的 `part_count` 为 10，`parts` 数组按顺序保存每个分片的名称、大小和 SHA256。清单位于 UUID 文件夹中，不写入 tar；tar 中没有额外的根目录文件，`tar_root_files` 为空数组。

已有清单可用 `cleanup_manifests.py` 批量精简。脚本默认处理 `./tmp/*/manifest.json`，移除 `objects` 中的上述三个字段，同时删除清单所在目录的 `.github` 文件夹，保留分片、`SUCCESS` 标记、对象顺序和其他清单信息（包括分片 SHA256）。以 `.` 开头的暂存目录会被跳过；清单通过同目录临时文件原子替换，可重复执行。

```bash
python cleanup_manifests.py --dry-run
python cleanup_manifests.py
# 指定其他归档父目录
python cleanup_manifests.py --output-dir ./other-tmp
```

这些是**一个 tar 的 10 个字节分片**，单片不能独立解压。按 `part01` 到 `part10` 顺序合并后才是完整 tar。

Linux / macOS 合并、解包：

```bash
cd tmp/某个UUID文件夹
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

随后可使用系统 tar 或 Python `tarfile` 解包。解包得到的文件路径就是 COS key，例如 key 为 `images/a.jpg` 的对象：

```text
images/
└── a.jpg
```

## 边界与资源

- 单个对象大于窗口，或单对象 tar 大小无法放进 10 片总容量时，默认报错。可显式传 `--skip-oversized` 跳过并记录警告；默认不会静默漏对象。可用 `--window-mb` 把窗口调小，范围 1～990。
- 下载使用条件 GET（ETag 和最后修改时间），并校验响应头、实际字节数，避免列表和下载之间对象变化后混入错误时间。HTTP 400/401/403/404/412/416 立即失败；其他非磁盘错误最多尝试 `--attempts` 次，默认 3。
- 下载保留原始字节，即便对象设置了 `Content-Encoding: gzip` 也不会自动解压。
- 网络读取和 tar 拷贝缓冲为 1MiB；对象内容不会把 990MB 全部放到内存。对象清单在磁盘 SQLite 中排序，当前窗口的元数据仍占用内存。
- 下载缓存最多约 990MB，另有 SQLite 索引；不另写整份中间 tar，直接生成分片。`--temp-dir` 可指定缓存所在磁盘。每个窗口 tar 总大小最多 10×100MB，默认最多创建 10 个文件夹，输出磁盘最多约 10GB tar 数据，另外需要清单空间。
- 文件夹完整写好后才改名为 UUID；中途出错时保留此前完成的文件夹，删除本次尚未完成的缓存。重新运行会重新列举整个桶，跳过输出目录中已有文件夹记录的 key，从最早的未归档对象继续，产生新的 UUID 文件夹；中断时未完成的窗口会重新下载。
- 是否跳过只按 key 判断：已归档的 key 之后在 COS 中被覆盖，也不会重新归档，站点保留归档时的内容。发布后请把 UUID 文件夹留在输出目录中（`publish.sh` 删除切片和 `.github`，保留 `manifest.json` 与 `SUCCESS`）；删除或移走文件夹后，其中的 key 会在下次运行时重新归档。换用其他 `--output-dir` 时，只跳过该目录中记录的 key。
- 操作仅列举和读取 COS 当前对象，不收集历史版本，不执行上传或删除。归档存储对象需要已可读取，脚本不会自动恢复冷归档对象。

## 发布到 GitHub Pages

`publish.sh` 接收一个包含 `archive.tar.part01` 到 `archive.tar.part10` 的 UUID 文件夹，创建同名公开 GitHub 仓库，通过 GitHub Actions 构建和部署 Pages。发布需要 Bash、Git、GitHub CLI（`gh`）、tar、mktemp 和 ssh。本地文件夹不需要 `index.html`。

```bash
export GH_TOKEN='你的 GitHub PAT'
bash publish.sh ./tmp/某个UUID文件夹
# 可选：发布到指定账号或组织
bash publish.sh ./tmp/某个UUID文件夹 my-organization
# 依次发布 ./tmp 中的所有文件夹
bash publish.sh --all
# 指定父目录和账号或组织
bash publish.sh --all ./tmp my-organization
```

`--all` 依次发布父目录（默认 `./tmp`）中的每个子文件夹，已有 `SUCCESS` 的文件夹直接跳过，PAT 只需输入一次。某个文件夹失败时立即停止，重新执行同一命令即可从该文件夹接续。

分批迁移时，反复执行下面两步，直到 `cos_archive.py` 显示本次创建 0 个文件夹。归档会跳过 `./tmp` 中已有文件夹记录的 key，发布只处理没有 `SUCCESS` 的文件夹，因此已归档的 key 不会再次归档或发布：

```bash
python cos_archive.py --bucket example-1250000000 --region ap-shanghai
bash publish.sh --all
```

PAT 需要创建公开仓库、推送内容和工作流、管理 Pages 设置、触发及读取 Actions 的权限。使用 classic PAT 时，需要相应的仓库权限和 `workflow` scope。不提供环境变量时，脚本会在交互终端中隐藏输入 PAT。

Git 数据默认通过 SSH 传输，远程地址为 `ssh://git@ssh.github.com:443/OWNER/REPO.git`，不需要额外设置环境变量。需要 `ssh` 命令及具有仓库写入权限的 SSH 密钥，脚本沿用现有 SSH 配置和 agent；密钥有口令时，建议先加入 ssh-agent，避免每次推送都输入口令。PAT 仍供 `gh` 创建仓库、管理 Pages 和触发部署使用。账户还没有 SSH 公钥时，可用 `bash add_public_key.sh -k ~/.ssh/id_ed25519.pub` 添加，所需 PAT 权限见该脚本开头的注释。如需改用 HTTPS，设置 `PUBLISH_GIT_PROTOCOL=https`。

首次发布前，先在 Git Bash 中验证 SSH，并确认 `ssh.github.com:443` 的主机密钥：

```bash
ssh -T -p 443 git@ssh.github.com
# 看到 Hi USERNAME! You've successfully authenticated 即表示验证成功
```

GitHub 的 SSH 验证命令成功时也返回退出码 1，应根据认证提示判断；详见 [GitHub SSH 验证说明](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/testing-your-ssh-connection)和 [SSH 使用 443 端口的说明](https://docs.github.com/en/authentication/troubleshooting-ssh/using-ssh-over-the-https-port)。中途按 `Ctrl+C` 停止或发布失败后，用原来的命令重新执行即可；如果原来指定了 `OWNER`，重跑时继续使用同一个 `OWNER`。脚本会检查并接续同一个远程仓库：已提交成功且内容相同的文件会跳过，尚未提交成功的当前分片会重新传输。目标目录中的 Git remote 不参与上传，实际上传使用脚本创建的临时仓库。

脚本每次在目标文件夹生成 `.github/workflows/deploy-pages.yml`，默认覆盖同名旧工作流，使新模板生效。工作流会按 `01` 到 `10` 的顺序合并 tar 切片，解压到仓库根目录，再创建内容为 `ok` 的根目录 `index.html`。归档和发布流程均不再生成 `meta.json` 或 `.nojekyll`。运行环境中的切片会在解压后移除，部署包包含解压后的文件、`manifest.json` 及其他站点文件。对象按 COS key 路径部署，例如 `<网站地址>/images/a.jpg`。

上传时，每个文件单独提交并通过 `git push` 推送：先按顺序上传 10 个切片，再上传其他文件，最后上传 `.github/workflows/` 中的文件。文件上传固定使用 Git；`gh` 负责认证、创建仓库、Pages 和 Actions 设置。空仓库直接从第一个文件开始提交和推送。只允许快进推送；如果推送报错，脚本会检查远程提交是否已经接收成功，确认成功后继续下一个文件。

上传提交带有 `[skip ci]`，避免尚未上传完整时启动构建；所有文件上传完成后，脚本再手动触发部署工作流。参见 [GitHub 跳过工作流的说明](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/skip-workflow-runs)。每个文件默认最多尝试上传 8 次，重试间隔依次为 5、10、20、40、60、60、60 秒。再次运行会跳过已提交到远程的相同文件，此前通过 Git 或 API 提交成功的文件都可以继续复用。

HTTPS 模式下，Git 连接使用 HTTP/1.1、并发 1，POST 缓冲按文件大小加 8MiB 计算、最大 128MiB；打包使用单线程、压缩等级 1，并关闭差量搜索。连续低于 1 字节/秒达 600 秒才中止传输。这些参数不会延长服务器或代理自身的请求期限，含义见 [Git 配置文档](https://git-scm.com/docs/git-config)。旧的 `PUBLISH_UPLOAD_METHOD` 和 `PUBLISH_API_TIMEOUT` 环境变量不再生效。

```bash
export PUBLISH_PUSH_ATTEMPTS=12      # 1～20，默认 8
export PUBLISH_LOW_SPEED_TIME=900    # 1～3600 秒，默认 600，仅 HTTPS 模式
bash publish.sh ./tmp/某个UUID文件夹
```

Pages 使用 `build_type: workflow`，由 `configure-pages`、`upload-pages-artifact` 和 `deploy-pages` 部署，详情见 [GitHub 自定义 Pages 工作流文档](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages)。脚本启用 Pages 后触发工作流，最多等待 30 分钟，仅在当前提交的工作流部署成功后，在本地目标文件夹写入空 `SUCCESS` 标记，并删除本地的 `archive.tar.part01` 到 `archive.tar.part10` 和 `.github` 文件夹以释放空间，标准归档目录中只留下 `manifest.json` 与 `SUCCESS`。失败、取消或等待超时都不会生成该标记，也不会删除切片或 `.github`，重新执行即可接续；再次执行时，如果已有 `SUCCESS`，会直接跳过，不需要凭据或发布工具。

脚本默认创建新仓库。同名仓库已存在但尚无 Git 引用（空仓库）时，会直接继续推送。已有部分文件时，脚本检查远程 `main`：已上传的数据文件必须与本地对应文件一致，随后跳过这些文件，只继续上传缺少的文件。脚本生成的 `deploy-pages.yml` 允许替换为当前模板；本地旧的根目录 `meta.json` 和 `.nojekyll` 不再上传，远程的对应旧文件会被清理。检查时仅获取提交和目录元数据，避免重新下载切片内容。其他远程文件缺少本地对应文件或内容不同，则报错，不覆盖这些文件。工作流也支持推送到 `main` 或手动触发。

## 从 COS 删除已发布的对象

`cos_delete.py` 读取归档父目录（默认 `./tmp`）中各文件夹 `manifest.json` 的 `objects[].id`，通过 COS 批量删除接口并发删除这些对象。凭据、`--bucket`、`--region` 的用法与 `cos_archive.py` 相同，缺少 SDK 时同样自动安装；密钥需要列举存储桶和删除对象的权限。删除无法撤销，建议先用 `--dry-run` 预览：

```bash
python cos_delete.py --bucket example-1250000000 --region ap-shanghai --dry-run
python cos_delete.py --bucket example-1250000000 --region ap-shanghai
```

1. 只处理有 `SUCCESS`（`publish.sh` 已部署成功）的文件夹；没有 `SUCCESS` 的文件夹给出警告并跳过，其中的对象不删除。清单 `bucket` 与 `--bucket` 不同的文件夹跳过；以 `.` 开头的目录和普通文件忽略。已发布的文件夹缺少 `manifest.json`、清单无法解析，或同一 key 记录在多份清单中时，在连接 COS 之前报错退出，不删除任何对象。
2. 删除前用 `list_objects` 完整列举一次存储桶。只有大小和 `LastModified` 仍与清单一致的对象才删除；归档后被覆盖的对象，新内容不在归档中，逐个警告并保留；清单中有、COS 中已没有的 key 视为已删除。清单以外的对象不受影响。
3. 每个请求最多删除 1000 个 key（Quiet 模式的 `delete_objects`），`--workers` 控制同时进行的请求数，默认 8。请求出错或个别 key 删除失败时，每批最多尝试 `--attempts` 次，默认 3；HTTP 4xx（408、429 除外）或 `AccessDenied` 立即停止。
4. 文件夹的 key 全部删除（或本就不存在）后，在其中写入空的 `COS_DELETED` 标记，以后运行直接跳过该文件夹。有删除失败或归档后变化对象的文件夹不写标记，下次运行重新核对。`--dry-run` 只列举核对，输出每个文件夹待删除、已不存在、已变化的数量，不删除也不写标记。

有 key 删除失败时退出码为 1，重新执行同一命令即可继续。分批迁移时，可在每轮 `publish.sh --all` 之后运行；`tmp` 已纳入仓库，记得提交新写入的 `COS_DELETED` 标记。核对与删除之间不是原子操作，核对后才被覆盖的对象仍会被删除。存储桶开启版本控制时，删除只会添加删除标记，历史版本仍保留并计费。
