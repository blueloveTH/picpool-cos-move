#!/usr/bin/env bash
# Upload a split tar directory to a public GitHub repository and enable Pages.
# Usage: bash publish.sh DIRECTORY [OWNER]
# Authentication: GH_TOKEN / GITHUB_TOKEN, or a hidden interactive PAT prompt.
# Requires: Bash, git, gh, tar. The directory must contain archive.tar.part01..30.
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
for command_name in git gh tar mktemp; do
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
api() { gh api --hostname github.com -H 'Accept: application/vnd.github+json' "$@"; }
remote_git() { git -c credential.helper= -c 'credential.helper=!gh auth git-credential' "$@"; }
push_commit() {
  local description=$1 push_attempt
  for ((push_attempt=1; push_attempt<=4; push_attempt++)); do
    if remote_git push --set-upstream origin main; then return 0; fi
    if (( push_attempt < 4 )); then
      printf 'Push failed; retrying (%d/3) in 5 seconds...\n' "$push_attempt" >&2
      sleep 5
    fi
  done
  die "Unable to push $description after 3 retries; run the same command again to resume."
}
identity=$(api user --jq '[.login, (.id | tostring)] | @tsv')
IFS=$'\t' read -r login user_id <<< "$identity"
[[ -n "$login" && -n "$user_id" ]] || die 'Unable to identify the authenticated user.'
owner=${owner:-$login}
repo="$owner/$repo_name"
repo_url="https://github.com/$repo"
printf 'Account: %s\nPublic repository: %s\n' "$login" "$repo_url"

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
  push_commit "$file"
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
