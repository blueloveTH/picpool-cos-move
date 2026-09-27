#!/usr/bin/env bash
# Upload a split tar directory to a public GitHub repository and enable Pages.
# Usage: bash publish.sh DIRECTORY [OWNER]
# Authentication: GH_TOKEN / GITHUB_TOKEN, or a hidden interactive PAT prompt.
# Requires: Bash, git, gh, curl, tar, tee; Python 3.9+ for API uploads (the default).
# The directory must contain archive.tar.part01..30.
# Upload dotfiles and ignored files, except .git, SUCCESS and obsolete metadata.
set +x
set -Eeuo pipefail

usage() {
  printf 'Usage: bash %s DIRECTORY [OWNER]\n' "${0##*/}"
  printf 'Example: bash %s ./my-site my-organization\n' "${0##*/}"
}
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then usage; exit 0; fi
[[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 1; }
[[ -d "$1" ]] || die "Directory does not exist: $1"
source_dir=$(cd -- "$1" && pwd -P)
if [[ -f "$source_dir/SUCCESS" ]]; then
  printf 'Already published (SUCCESS exists), skipping: %s\n' "$source_dir"
  exit 0
fi
for command_name in git gh curl tar mktemp tee; do
  command -v "$command_name" >/dev/null || die "Missing dependency: $command_name"
done
repo_name=${source_dir##*/}
[[ "$repo_name" =~ ^[A-Za-z0-9._-]+$ && ${#repo_name} -le 100 && "$repo_name" != . && "$repo_name" != .. ]] ||
  die 'Folder name must be a valid repository name: 1-100 ASCII letters, digits, dots, underscores or hyphens.'
for part in "$source_dir"/archive.tar.part{01..30}; do
  [[ -f "$part" ]] || die "Missing tar slice: $part"
done
owner=${2:-}
[[ -z "$owner" || "$owner" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || die 'Invalid owner name.'

# Always replace the managed workflow so the current archive format takes effect.
workflow_name=deploy-pages.yml
workflow_file="$source_dir/.github/workflows/$workflow_name"
mkdir -p -- "${workflow_file%/*}"
[[ ! -L "$workflow_file" ]] || die 'The Pages workflow must not be a symbolic link.'
cat > "$workflow_file" <<'YAML'
name: Deploy archive to GitHub Pages

on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read
  pages: write
  id-token: write

concurrency:
  group: pages
  cancel-in-progress: false

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    steps:
      - name: Checkout
        uses: actions/checkout@v6

      - name: Merge and extract tar slices into the repository root
        shell: bash
        run: |
          parts=(archive.tar.part{01..30})
          for part in "${parts[@]}"; do
            if [[ ! -f "$part" ]]; then
              printf 'Missing tar slice: %s\n' "$part" >&2
              exit 1
            fi
          done
          cat -- "${parts[@]}" | tar -xf - -C "$GITHUB_WORKSPACE"
          # Upload the extracted files without duplicating the archive payload.
          rm -- "${parts[@]}"

      - name: Create the status page
        shell: bash
        run: |
          printf 'ok\n' > index.html

      - name: Configure GitHub Pages
        uses: actions/configure-pages@v5

      - name: Upload GitHub Pages artifact
        uses: actions/upload-pages-artifact@v4
        with:
          path: '.'

      - name: Deploy to GitHub Pages
        id: deployment
        uses: actions/deploy-pages@v4
YAML
[[ -f "$workflow_file" ]] || die 'The Pages workflow must be a regular file.'

# gh supports PAT authentication through GH_TOKEN without persisting a login.
export GH_HOST=github.com GH_PROMPT_DISABLED=1 GIT_TERMINAL_PROMPT=0
export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
if [[ -z "$GH_TOKEN" ]]; then
  [[ -t 0 ]] || die 'Set GH_TOKEN when running non-interactively.'
  read -r -s -p 'GitHub PAT: ' GH_TOKEN
  printf '\n'
fi
[[ -n "$GH_TOKEN" ]] || die 'PAT must not be empty.'
push_attempt_limit=${PUBLISH_PUSH_ATTEMPTS:-8}
push_low_speed_time=${PUBLISH_LOW_SPEED_TIME:-600}
api_timeout=${PUBLISH_API_TIMEOUT:-900}
upload_method=${PUBLISH_UPLOAD_METHOD:-api}
[[ "$push_attempt_limit" =~ ^[1-9][0-9]*$ && ${#push_attempt_limit} -le 2 && "$push_attempt_limit" -le 20 ]] ||
  die 'PUBLISH_PUSH_ATTEMPTS must be an integer from 1 to 20.'
[[ "$push_low_speed_time" =~ ^[1-9][0-9]*$ && ${#push_low_speed_time} -le 4 && "$push_low_speed_time" -le 3600 ]] ||
  die 'PUBLISH_LOW_SPEED_TIME must be an integer from 1 to 3600 seconds.'
[[ "$api_timeout" =~ ^[1-9][0-9]*$ && ${#api_timeout} -le 4 && "$api_timeout" -le 7200 ]] ||
  die 'PUBLISH_API_TIMEOUT must be an integer from 1 to 7200 seconds.'
[[ "$upload_method" == auto || "$upload_method" == git || "$upload_method" == api ]] ||
  die 'PUBLISH_UPLOAD_METHOD must be auto, git or api.'
active_upload_method=git
[[ "$upload_method" != api ]] || active_upload_method=api
api_python=''
ensure_api_python() {
  [[ -z "$api_python" ]] || return 0
  local candidate
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null &&
        "$candidate" -c 'import sys; sys.exit(sys.version_info < (3, 9))' >/dev/null 2>&1; then
      api_python=$candidate
      return 0
    fi
  done
  printf 'GitHub API uploads require Python 3.9 or newer (python3 or python).\n' >&2
  return 1
}
if [[ "$upload_method" == api ]]; then
  ensure_api_python || die 'Unable to enable API uploads.'
fi
api() {
  # Raw --input bodies are streams, so gh does not infer JSON headers. Keep
  # both API and Git traffic on HTTP/1.1 for proxy compatibility.
  GODEBUG="${GODEBUG:+$GODEBUG,}http2client=0" \
    gh api --hostname github.com -H 'Accept: application/vnd.github+json' \
      -H 'Content-Type: application/json; charset=utf-8' "$@"
}
api_write() {
  local request_method=$1 request_path=$2 input_file=$3 body_bytes http_status
  body_bytes=$("$api_python" -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).stat().st_size)' \
    "$input_file") || return 1
  # Space content-creating requests to reduce secondary API rate limits.
  sleep 1
  : > "$workdir/api-error.log" || return 1
  # Pass the PAT through stdin, not process arguments or a file. Send a known
  # length JSON body with curl, independently of gh's Go HTTP transport.
  if ! http_status=$(
    "$api_python" -c 'import json, os; token = os.environ["GH_TOKEN"]; assert "\r" not in token and "\n" not in token, "Invalid PAT"; print("header = " + json.dumps("Authorization: Bearer " + token))' |
      curl --disable --config - --http1.1 --proto '=https' \
        --silent --show-error --connect-timeout 30 --max-time "$api_timeout" \
        --keepalive-time 30 --request "$request_method" \
        --user-agent 'picpool-cos-move' \
        --header 'Accept: application/vnd.github+json' \
        --header 'Content-Type: application/json; charset=utf-8' \
        --header "Content-Length: $body_bytes" --header 'Transfer-Encoding:' --header 'Expect:' \
        --data-binary "@$input_file" --output "$workdir/api-response.json" \
        --dump-header "$workdir/api-response.headers" --write-out '%{http_code}' \
        "https://api.github.com/$request_path" 2>"$workdir/api-error.log"
  ); then
    printf 'API %s /%s transfer failed (request body: %s bytes):\n' \
      "$request_method" "$request_path" "$body_bytes" >&2
    cat "$workdir/api-error.log" >&2
    return 1
  fi
  "$api_python" - "$workdir" "$http_status" "$request_method" "$request_path" "$body_bytes" <<'RESPONSE_PYTHON'
import json
from pathlib import Path
import re
import sys

directory = Path(sys.argv[1])
status, method, endpoint, body_bytes = sys.argv[2:]
text = (directory / "api-response.json").read_text(encoding="utf-8", errors="replace")
try:
    result = json.loads(text)
except ValueError:
    result = {}
if status.startswith("2") and isinstance(result, dict):
    sha = result.get("sha") or result.get("object", {}).get("sha")
    if isinstance(sha, str) and re.fullmatch(r"[0-9a-f]{40}", sha):
        print(sha)
        sys.exit(0)
message = result.get("message", "Invalid API response") if isinstance(result, dict) else "Invalid API response"
if not result:
    message = text[:500] or "Empty response"
request_id = ""
for line in (directory / "api-response.headers").read_text(encoding="utf-8", errors="replace").splitlines():
    if line.lower().startswith("x-github-request-id:"):
        request_id = line.split(":", 1)[1].strip()
error = f"API {method} /{endpoint} failed (HTTP {status}, request body: {body_bytes} bytes): {message}"
if request_id:
    error += f"\nGitHub request ID: {request_id}"
(directory / "api-error.log").write_text(error + "\n", encoding="utf-8")
print(error, file=sys.stderr)
sys.exit(1)
RESPONSE_PYTHON
}
remote_git() {
  # Apply these settings to this process only, including inherited low-speed
  # environment overrides. HTTP/1.1 avoids HTTP/2 issues on some proxy paths.
  GIT_HTTP_MAX_REQUESTS=1 GIT_HTTP_LOW_SPEED_LIMIT=1 GIT_HTTP_LOW_SPEED_TIME="$push_low_speed_time" \
    git -c credential.helper= -c 'credential.helper=!gh auth git-credential' \
      -c http.version=HTTP/1.1 -c http.maxRequests=1 \
      -c http.lowSpeedLimit=1 -c "http.lowSpeedTime=$push_low_speed_time" \
      -c pack.threads=1 -c pack.window=0 -c pack.compression=1 "$@"
}
prepare_api_commit() {
  "$api_python" - "$1" <<'PYTHON'
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import sys

destination = Path(sys.argv[1])

def git(*args):
    return subprocess.check_output(["git", *args])

parent = git("rev-parse", "HEAD^1").decode("ascii").strip()
tree_sha = git("rev-parse", "HEAD^{tree}").decode("ascii").strip()
changes = git("diff-tree", "--no-commit-id", "--no-abbrev", "--no-renames",
              "--raw", "-r", "-z", "HEAD").split(b"\0")
entries = []
blobs = set()
for offset in range(0, len(changes) - 1, 2):
    old_mode, new_mode, old_sha, new_sha, status = changes[offset][1:].split()
    path = changes[offset + 1].decode("utf-8")
    entry = {"path": path, "type": "blob"}
    if status == b"D":
        entry.update(mode=old_mode.decode("ascii"), sha=None)
    else:
        if new_mode not in (b"100644", b"100755", b"120000"):
            raise ValueError(f"Unsupported file mode for API upload: {path}")
        sha = new_sha.decode("ascii")
        entry.update(mode=new_mode.decode("ascii"), sha=sha)
        blobs.add(sha)
    entries.append(entry)

def write_json(name, value):
    (destination / name).write_text(json.dumps(value, ensure_ascii=True), encoding="utf-8")

write_json("tree.json", {"base_tree": git("rev-parse", "HEAD^1^{tree}").decode("ascii").strip(),
                         "tree": entries})
identity = git("show", "-s", "--format=%an%x00%ae%x00%cn%x00%ce", "HEAD").decode("utf-8").rstrip("\n").split("\0")
message = git("cat-file", "commit", "HEAD").split(b"\n\n", 1)[1].decode("utf-8")
write_json("commit.json", {"message": message, "tree": tree_sha, "parents": [parent],
                           "author": {"name": identity[0], "email": identity[1]},
                           "committer": {"name": identity[2], "email": identity[3]}})

# Stream Base64 to disk; large binary slices never enter shell arguments or
# require loading the whole file and encoded JSON into Python memory.
for sha in sorted(blobs):
    size = int(git("cat-file", "-s", sha))
    digest = hashlib.sha1(f"blob {size}\0".encode("ascii"))
    read_bytes = 0
    with (destination / f"{sha}.blob.json").open("wb") as output:
        output.write(b'{"encoding":"base64","content":"')
        with subprocess.Popen(["git", "cat-file", "blob", sha], stdout=subprocess.PIPE) as process:
            while block := process.stdout.read(3 * 256 * 1024):
                digest.update(block)
                read_bytes += len(block)
                output.write(base64.b64encode(block))
            if process.wait() != 0:
                raise RuntimeError(f"Unable to read Git blob {sha}")
        output.write(b'"}')
    if read_bytes != size or digest.hexdigest() != sha:
        raise RuntimeError(f"Incomplete or changed Git blob {sha}")
PYTHON
}
finish_api_commit() {
  local old_head=$1 api_sha=$2 expected_tree=$3 api_dir=$4
  # Only commit/tree metadata is needed. All file contents already exist here.
  remote_git fetch --quiet --no-tags --depth=1 --filter=blob:none origin "$api_sha" || return 1
  [[ "$(git rev-parse 'FETCH_HEAD^{tree}')" == "$expected_tree" ]] ||
    die 'The API upload produced a different snapshot; stopping without a SUCCESS marker.'
  git update-ref refs/heads/main "$api_sha" "$old_head" || return 1
  # The index already contains this exact tree. Removing cached request bodies
  # is best-effort once the verified commit has been saved locally.
  rm -f -- "$api_dir"/*.json || true
  return 0
}
upload_api_commit() {
  local description=$1 old_head parent expected_tree api_dir remote_tip remote_sha api_sha
  local blob_file blob_sha returned_sha tree_sha
  ensure_api_python || return 1
  old_head=$(git rev-parse HEAD) || return 1
  parent=$(git rev-parse --verify HEAD^1 2>/dev/null) || {
    printf 'Initialize the repository through Git before uploading through the API.\n' >&2
    return 1
  }
  expected_tree=$(git rev-parse 'HEAD^{tree}') || return 1
  api_dir="$workdir/api-$old_head"
  remote_tip=$(remote_git ls-remote --refs origin refs/heads/main) || return 1
  remote_sha=${remote_tip%%$'\t'*}
  if [[ "$remote_sha" == "$old_head" ]]; then
    printf 'Server already received %s; continuing.\n' "$description"
    return 0
  fi
  if [[ -f "$api_dir/commit.sha" ]]; then
    api_sha=$(<"$api_dir/commit.sha")
    # A reference update may have succeeded even if its HTTP response was lost.
    if [[ "$remote_sha" == "$api_sha" ]]; then
      finish_api_commit "$old_head" "$api_sha" "$expected_tree" "$api_dir" || return 1
      printf 'Server already received %s through the API; continuing.\n' "$description"
      return 0
    fi
  fi
  [[ "$remote_sha" == "$parent" ]] ||
    die 'Remote main changed during this upload; run again to inspect and resume safely.'
  mkdir -p -- "$api_dir" || return 1
  if [[ ! -f "$api_dir/ready" ]]; then
    prepare_api_commit "$api_dir" || return 1
    : > "$api_dir/ready" || return 1
  fi
  for blob_file in "$api_dir"/*.blob.json; do
    [[ -f "$blob_file" ]] || continue
    blob_sha=${blob_file##*/}
    blob_sha=${blob_sha%.blob.json}
    [[ ! -f "$api_dir/$blob_sha.uploaded" ]] || continue
    returned_sha=$(api_write POST "repos/$repo/git/blobs" "$blob_file") || return 1
    [[ "$returned_sha" == "$blob_sha" ]] || die 'GitHub returned a different file hash.'
    : > "$api_dir/$blob_sha.uploaded" || return 1
  done
  if [[ ! -f "$api_dir/tree.sha" ]]; then
    tree_sha=$(api_write POST "repos/$repo/git/trees" "$api_dir/tree.json") || return 1
    [[ "$tree_sha" == "$expected_tree" ]] || die 'GitHub returned a different directory hash.'
    printf '%s\n' "$tree_sha" > "$api_dir/tree.sha" || return 1
  fi
  if [[ ! -f "$api_dir/commit.sha" ]]; then
    api_sha=$(api_write POST "repos/$repo/git/commits" "$api_dir/commit.json") || return 1
    [[ "$api_sha" =~ ^[0-9a-f]{40}$ ]] || die 'GitHub returned an invalid commit hash.'
    printf '%s\n' "$api_sha" > "$api_dir/commit.sha" || return 1
  fi
  api_sha=$(<"$api_dir/commit.sha")
  # Fast-forward only: another writer's changes must never be force-overwritten.
  printf '{"sha":"%s","force":false}\n' "$api_sha" > "$api_dir/reference.json" || return 1
  api_write PATCH "repos/$repo/git/refs/heads/main" "$api_dir/reference.json" >/dev/null || return 1
  finish_api_commit "$old_head" "$api_sha" "$expected_tree" "$api_dir" || return 1
  printf 'Uploaded through GitHub API: %s\n' "$description"
}
push_commit() {
  local description=$1 data_bytes=${2:-0} push_attempt retry_delay
  local post_buffer_bytes expected_sha remote_tip remote_sha remote_ref push_output api_error
  local timeout_count=0 git_failed
  # Each push adds one file. Buffer that file plus modest pack overhead, up to
  # 128 MiB, to avoid chunked POSTs for slices without allocating a huge buffer
  # for every small-file push. This helps proxies that mishandle chunked data.
  post_buffer_bytes=$((data_bytes + 8 * 1024 * 1024))
  if (( post_buffer_bytes > 128 * 1024 * 1024 )); then
    post_buffer_bytes=$((128 * 1024 * 1024))
  fi
  expected_sha=$(git rev-parse HEAD)
  for ((push_attempt=1; push_attempt<=push_attempt_limit; push_attempt++)); do
    git_failed=0
    if [[ "$active_upload_method" == api ]]; then
      if upload_api_commit "$description"; then return 0; fi
      if [[ -s "$workdir/api-error.log" ]]; then
        api_error=$(<"$workdir/api-error.log")
        if [[ "$api_error" == *'HTTP 429'* || "${api_error,,}" == *'rate limit'* ]]; then
          die 'GitHub API rate limit reached; resume after the limit resets. Uploaded files have been kept.'
        fi
        if [[ "$api_error" == *'HTTP 400'* || "$api_error" == *'HTTP 413'* || "$api_error" == *'HTTP 422'* ]]; then
          die 'GitHub rejected this API request; see its endpoint, size and error above. Uploaded files have been kept.'
        fi
      fi
    else
      if remote_git -c "http.postBuffer=$post_buffer_bytes" \
          push --progress --no-follow-tags --set-upstream origin HEAD:refs/heads/main \
          2>&1 | tee "$workdir/push.log"; then
        return 0
      fi
      git_failed=1
      push_output=$(<"$workdir/push.log")
    fi
    # The server may accept a commit even when its response is lost. Confirm
    # the exact commit before sending the same slice again.
    if remote_tip=$(remote_git ls-remote --refs origin refs/heads/main \
        2>"$workdir/check-push.log"); then
      IFS=$'\t' read -r remote_sha remote_ref <<< "$remote_tip"
      if [[ "$remote_sha" == "$expected_sha" && "$remote_ref" == refs/heads/main ]]; then
        printf 'Server already received %s; continuing.\n' "$description"
        return 0
      fi
    fi
    if (( git_failed == 1 )) && [[ "$upload_method" == auto && "$push_output" == *'HTTP 408'* ]]; then
      timeout_count=$((timeout_count + 1))
      if (( timeout_count >= 2 )) && git rev-parse --verify HEAD^1 >/dev/null 2>&1 && ensure_api_python; then
        active_upload_method=api
        printf 'Repeated HTTP 408; switching this and remaining files to GitHub API uploads.\n' >&2
      fi
    elif (( git_failed == 1 )); then
      timeout_count=0
    fi
    if (( push_attempt < push_attempt_limit )); then
      retry_delay=$((5 * (1 << (push_attempt - 1))))
      if (( retry_delay > 60 )); then retry_delay=60; fi
      printf 'Upload failed (%d/%d); retrying %s in %d seconds...\n' \
        "$push_attempt" "$push_attempt_limit" "$description" "$retry_delay" >&2
      sleep "$retry_delay"
    fi
  done
  die "Unable to upload $description after $push_attempt_limit attempts; run the same command again to resume."
}
identity=$(api user --jq '[.login, (.id | tostring)] | @tsv')
IFS=$'\t' read -r login user_id <<< "$identity"
[[ -n "$login" && -n "$user_id" ]] || die 'Unable to identify the authenticated user.'
owner=${owner:-$login}
repo="$owner/$repo_name"
repo_url="https://github.com/$repo"
printf 'Account: %s\nPublic repository: %s\n' "$login" "$repo_url"
printf 'Upload method: %s; up to %s attempts per file.\n' "$upload_method" "$push_attempt_limit"
if [[ "$upload_method" != git ]]; then
  printf 'API transport: curl, HTTP/1.1, fixed Content-Length, timeout %ss.\n' "$api_timeout"
fi
if [[ "$upload_method" != api ]]; then
  printf 'Git settings: HTTP/1.1, adaptive buffer up to 128 MiB, low-speed timeout %ss.\n' "$push_low_speed_time"
fi

# Upload a copy; leave the source archive slices and Git history intact.
workdir=''
created=0
cleanup() {
  result=$?
  trap - EXIT
  if (( result != 0 && created == 1 )); then
    printf 'The repository was created and has been kept: %s\n' "$repo_url" >&2
    printf 'Run the same command again to resume files already uploaded.\n' >&2
  fi
  if [[ -n "$workdir" && "$workdir" == "$temp_base"/gh-pages.* && -d "$workdir" ]]; then
    rm -rf -- "$workdir"
  fi
  exit "$result"
}
temp_base=$(cd -- "${TMPDIR:-/tmp}" && pwd -P)
[[ "$temp_base/" != "$source_dir/"* ]] || die 'Temporary directory must be outside the source directory; set TMPDIR.'
trap cleanup EXIT
workdir=$(mktemp -d "$temp_base/gh-pages.XXXXXXXX")
mkdir "$workdir/site"
tar -C "$source_dir" --exclude='.git' --exclude='./SUCCESS' \
  --exclude='./.nojekyll' --exclude='./meta.json' -cf - . | tar -C "$workdir/site" -xf -
cd "$workdir/site"
# Avoid inheriting an enclosing repository, hooks, or a configured Git template.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
unset GIT_AUTHOR_DATE GIT_COMMITTER_DATE
git init --quiet --template= .
git symbolic-ref HEAD refs/heads/main
git config --local user.name "$login"
git config --local user.email "$user_id+$login@users.noreply.github.com"
git config --local core.hooksPath /dev/null
git config --local commit.gpgsign false
git config --local core.autocrlf false
# Record the desired snapshot, including ignored build assets, without committing
# all files together. Only each file's own commit will be sent by its push.
git add --all --force
desired_tree=$(git write-tree)
git ls-files -z > "$workdir/files.list"
git read-tree --empty
git remote add origin "$repo_url.git"

# Existing uploads may be a matching subset of the desired snapshot.
printf 'Creating repository...\n'
if gh repo create "$repo" --public --description 'Static site hosted on GitHub Pages' \
    2>"$workdir/create-repo.log"; then
  created=1
else
  if ! remote_refs=$(remote_git ls-remote origin 2>"$workdir/check-repo.log"); then
    cat "$workdir/create-repo.log" "$workdir/check-repo.log" >&2
    die 'Unable to create the repository or inspect its existing contents.'
  fi
  if [[ -z "$remote_refs" ]]; then
    printf 'Found an empty existing repository; continuing with upload: %s\n' "$repo_url"
  else
    has_main=0
    while IFS=$'\t' read -r remote_sha remote_ref; do
      if [[ "$remote_ref" == refs/heads/main ]]; then has_main=1; fi
    done <<< "$remote_refs"
    (( has_main == 1 )) || die "Existing repository has no main branch: $repo_url"
    # Fetch commit/tree metadata without downloading the archive blobs again.
    remote_git fetch --quiet --no-tags --depth=1 --filter=blob:none origin main
    # From desired -> remote, deletions are files still awaiting upload. Added,
    # modified, or differently typed data files mean the repository does not
    # match. The managed workflow and obsolete metadata can be updated.
    git --no-literal-pathspecs diff-tree --quiet --no-renames -r --diff-filter=AMT \
      "$desired_tree" FETCH_HEAD -- . ":(top,exclude,literal).github/workflows/$workflow_name" \
      ':(top,exclude,literal).nojekyll' ':(top,exclude,literal)meta.json' ||
      die "Existing repository contains files that differ from this directory; kept unchanged: $repo_url"
    git update-ref refs/heads/main "$(git rev-parse FETCH_HEAD)"
    git read-tree HEAD
    printf 'Resuming the existing upload; identical files will be skipped.\n'
  fi
fi

# Git's empty initial commit establishes main using only a tiny push. GitHub's
# Git database API cannot create references in a repository with no branches.
if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
  git commit --quiet --allow-empty -m 'Initialize archive upload [skip ci]'
  saved_upload_method=$active_upload_method
  active_upload_method=git
  push_commit 'repository initialization'
  active_upload_method=$saved_upload_method
fi

# Remove files generated by older versions from an existing remote snapshot.
if git rev-parse --verify HEAD >/dev/null 2>&1; then
  git --literal-pathspecs rm --quiet --cached --ignore-unmatch -- .nojekyll meta.json
  if ! git diff --cached --quiet; then
    git commit --quiet -m 'Remove obsolete archive metadata [skip ci]'
    push_commit 'obsolete metadata removal'
  fi
fi

# Upload slices first, other files next, and workflows last. NUL-delimited paths
# also support spaces and newlines in filenames.
other_files=()
workflow_files=()
while IFS= read -r -d '' file; do
  case "$file" in
    archive.tar.part0[1-9]|archive.tar.part[12][0-9]|archive.tar.part30) ;;
    .github/workflows/*) workflow_files+=("$file") ;;
    *) other_files+=("$file") ;;
  esac
done < "$workdir/files.list"
upload_files=(archive.tar.part{01..30} "${other_files[@]}" "${workflow_files[@]}")
file_number=0
for file in "${upload_files[@]}"; do
  file_number=$((file_number + 1))
  git --literal-pathspecs add --force -- "$file"
  if git --literal-pathspecs diff --cached --quiet -- "$file"; then
    printf '[%d/%d] Already uploaded: %s\n' "$file_number" "${#upload_files[@]}" "$file"
    continue
  fi
  printf '[%d/%d] Uploading: %s\n' "$file_number" "${#upload_files[@]}" "$file"
  # Suppress push-triggered builds while the upload is incomplete. The final
  # workflow_dispatch still runs after every file has been uploaded.
  git commit --quiet -m "Upload $file [skip ci]"
  push_commit "$file" "$(git cat-file -s "HEAD:$file")"
done
[[ "$(git rev-parse 'HEAD^{tree}')" == "$desired_tree" ]] ||
  die 'The uploaded snapshot does not match the source directory.'
commit_sha=$(git rev-parse HEAD)
# GitHub account defaults can use another default branch.
api --method PATCH "repos/$repo" -f default_branch=main >/dev/null
printf 'Enabling GitHub Pages through GitHub Actions...\n'
pages_method=POST
if (( created == 0 )) && api "repos/$repo/pages" >/dev/null 2>&1; then
  pages_method=PUT
fi
api --method "$pages_method" "repos/$repo/pages" --input - >/dev/null <<'JSON'
{"build_type":"workflow"}
JSON
# Dispatch only after all uploads are complete and Pages is enabled.
api --method POST "repos/$repo/actions/workflows/$workflow_name/dispatches" \
  -f ref=main >/dev/null
site_url=$(api "repos/$repo/pages" --jq '.html_url')
printf 'Site URL: %s\nWaiting up to 30 minutes for deployment...\n' "$site_url"
# Only accept the manually dispatched Pages workflow for this exact commit.
for ((attempt=1; attempt<=180; attempt++)); do
  run=$(api "repos/$repo/actions/workflows/$workflow_name/runs?event=workflow_dispatch&head_sha=$commit_sha&per_page=1" --jq \
    '.workflow_runs[0] | if . == null then "pending" else [.status, (.conclusion // ""), .html_url] | @tsv end')
  IFS=$'\t' read -r status conclusion run_url <<< "$run"
  if [[ "$status" == completed ]]; then
    if [[ "$conclusion" == success ]]; then
      : > "$source_dir/SUCCESS"
      printf '\nDeployment complete!\nRepository: %s\nWebsite: %s\n' "$repo_url" "$site_url"
      exit 0
    fi
    die "Pages deployment failed ($conclusion): ${run_url:-$repo_url/actions}"
  fi
  sleep 10
done
printf 'Deployment is still pending. Check: %s/actions\n' "$repo_url" >&2
exit 2
