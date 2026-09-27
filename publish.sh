#!/usr/bin/env bash
# Upload a split tar directory to a NEW public GitHub repository and enable Pages.
# Usage: bash publish.sh DIRECTORY [OWNER]
# Authentication: GH_TOKEN / GITHUB_TOKEN, or a hidden interactive PAT prompt.
# Requires: Bash, git, gh, tar. The directory must contain archive.tar.part01..10.
# All files (including dotfiles and ignored files) are uploaded, except .git and SUCCESS.
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
for part in "$source_dir"/archive.tar.part{01..10}; do
  [[ -f "$part" ]] || die "Missing tar slice: $part"
done
owner=${2:-}
[[ -z "$owner" || "$owner" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || die 'Invalid owner name.'

# Keep generated files in the source directory so retries can reuse them.
[[ ! -L "$source_dir/.nojekyll" ]] || die '.nojekyll must not be a symbolic link.'
if [[ ! -e "$source_dir/.nojekyll" ]]; then
  : > "$source_dir/.nojekyll"
fi
[[ -f "$source_dir/.nojekyll" ]] || die '.nojekyll must be a regular file.'
workflow_name=deploy-pages.yml
workflow_file="$source_dir/.github/workflows/$workflow_name"
mkdir -p -- "${workflow_file%/*}"
[[ ! -L "$workflow_file" ]] || die 'The Pages workflow must not be a symbolic link.'
if [[ ! -e "$workflow_file" ]]; then
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
          parts=(archive.tar.part{01..10})
          for part in "${parts[@]}"; do
            if [[ ! -f "$part" ]]; then
              printf 'Missing tar slice: %s\n' "$part" >&2
              exit 1
            fi
          done
          cat -- "${parts[@]}" | tar -xf - -C "$GITHUB_WORKSPACE"
          # Upload the extracted files without duplicating the archive payload.
          rm -- "${parts[@]}"

      - name: Create the status page and disable Jekyll
        shell: bash
        run: |
          printf 'ok\n' > index.html
          touch .nojekyll

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
fi
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
    printf 'Inspect its contents and Pages settings before retrying.\n' >&2
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
tar -C "$source_dir" --exclude='.git' --exclude='./SUCCESS' -cf - . | tar -C "$workdir/site" -xf -
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
# A deployment directory is a complete snapshot; include ignored build assets.
git add --all --force
git commit --quiet -m 'Publish static site'
commit_sha=$(git rev-parse HEAD)

# Creation fails if the name is already occupied; never overwrite another repo.
printf 'Creating repository...\n'
gh repo create "$repo" --public --description 'Static site hosted on GitHub Pages'
created=1
git remote add origin "$repo_url.git"
printf 'Uploading files...\n'
# Clear inherited credential helpers; use this PAT for the Git HTTPS push too.
git -c credential.helper= -c 'credential.helper=!gh auth git-credential' \
  push --set-upstream origin main
# GitHub account defaults can use another default branch.
api --method PATCH "repos/$repo" -f default_branch=main >/dev/null
printf 'Enabling GitHub Pages through GitHub Actions...\n'
api --method POST "repos/$repo/pages" --input - >/dev/null <<'JSON'
{"build_type":"workflow"}
JSON
# Dispatch after Pages is enabled; the initial push may run before setup finishes.
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
