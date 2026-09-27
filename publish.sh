#!/usr/bin/env bash
# Upload a static directory to a NEW public GitHub repository and enable Pages.
# Usage: bash publish-pages.sh DIRECTORY [OWNER]
# Authentication: GH_TOKEN / GITHUB_TOKEN, or a hidden interactive PAT prompt.
# Requires: Bash, git, gh, tar. The directory must contain index.html.
# All files (including dotfiles and ignored files) are uploaded, except .git.
set +x
set -Eeuo pipefail

usage() {
  printf 'Usage: bash %s DIRECTORY [OWNER]\n' "${0##*/}"
  printf 'Example: bash %s ./my-site my-organization\n' "${0##*/}"
}
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then usage; exit 0; fi
[[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 1; }
for command_name in git gh tar mktemp; do
  command -v "$command_name" >/dev/null || die "Missing dependency: $command_name"
done
[[ -d "$1" ]] || die "Directory does not exist: $1"
source_dir=$(cd -- "$1" && pwd -P)
repo_name=${source_dir##*/}
[[ "$repo_name" =~ ^[A-Za-z0-9._-]+$ && ${#repo_name} -le 100 && "$repo_name" != . && "$repo_name" != .. ]] ||
  die 'Folder name must be a valid repository name: 1-100 ASCII letters, digits, dots, underscores or hyphens.'
[[ -f "$source_dir/index.html" ]] || die 'The directory must contain index.html; pass the built static output directory.'
owner=${2:-}
[[ -z "$owner" || "$owner" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || die 'Invalid owner name.'

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

# Work on a copy; do not alter the source directory or its Git history.
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
tar -C "$source_dir" --exclude='.git' -cf - . | tar -C "$workdir/site" -xf -
cd "$workdir/site"
# Empty .nojekyll tells GitHub Pages to serve the static files directly.
[[ ! -L .nojekyll ]] || die '.nojekyll must not be a symbolic link.'
touch .nojekyll
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
printf 'Enabling GitHub Pages from main:/ ...\n'
# JSON via stdin also avoids Git Bash converting a path field of / to a Windows path.
api --method POST "repos/$repo/pages" --input - >/dev/null <<'JSON'
{"build_type":"legacy","source":{"branch":"main","path":"/"}}
JSON
site_url=$(api "repos/$repo/pages" --jq '.html_url')
printf 'Site URL: %s\nWaiting up to 10 minutes for deployment...\n' "$site_url"
# Enabling Pages starts its initial build. Query the build for this exact commit.
for ((attempt=1; attempt<=60; attempt++)); do
  build=$(api "repos/$repo/pages/builds" --jq \
    "[.[] | select(.commit == \"$commit_sha\")][0] | if . == null then \"pending\" else [.status, (.error.message // \"\")] | @tsv end")
  IFS=$'\t' read -r status message <<< "$build"
  case "$status" in
    built)
      printf '\nDeployment complete!\nRepository: %s\nWebsite: %s\n' "$repo_url" "$site_url"
      exit 0
      ;;
    errored)
      die "Pages deployment failed: ${message:-see $repo_url/actions}"
      ;;
  esac
  sleep 10
done
printf 'Deployment is still pending. Check: %s/actions\n' "$repo_url" >&2
exit 2