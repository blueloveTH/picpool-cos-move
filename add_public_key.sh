#!/usr/bin/env bash
#
# 使用 GitHub CLI (gh) 为当前账户添加 SSH 公钥（账户级，非仓库 deploy key）
# 认证：读取环境变量中的 PAT（GH_TOKEN 或 GITHUB_TOKEN）
# PAT 所需权限：classic token 需 admin:public_key（签名密钥需 admin:ssh_signing_key）；
#              fine-grained token 需 "Git SSH keys"（或 "SSH signing keys"）读写权限
#
# 用法：
#   ./add_ssh_key.sh -k ~/.ssh/id_ed25519.pub [-t "标题"] [-T authentication|signing]
#   ./add_ssh_key.sh -k "ssh-ed25519 AAAAC3Nz... user@host" -t "my-laptop"
#   cat key.pub | ./add_ssh_key.sh -k -

set -euo pipefail

KEY_INPUT=""
TITLE="$(whoami)@$(hostname)-$(date +%Y%m%d)"
KEY_TYPE="authentication"

usage() {
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

log()  { echo -e "\033[32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[33m[WARN]\033[0m $*" >&2; }
die()  { echo -e "\033[31m[ERROR]\033[0m $*" >&2; exit 1; }

while getopts ":k:t:T:h" opt; do
    case "$opt" in
        k) KEY_INPUT="$OPTARG" ;;
        t) TITLE="$OPTARG" ;;
        T) KEY_TYPE="$OPTARG" ;;
        h|*) usage ;;
    esac
done

[[ -z "$KEY_INPUT" ]] && usage
[[ "$KEY_TYPE" =~ ^(authentication|signing)$ ]] || die "-T 只能是 authentication 或 signing"

# 1. 检查 gh 与认证
command -v gh >/dev/null 2>&1 || die "未找到 gh，请先安装：https://cli.github.com/"

if [[ -z "${GH_TOKEN:-}" && -z "${GITHUB_TOKEN:-}" ]]; then
    die "环境变量 GH_TOKEN / GITHUB_TOKEN 均未设置"
fi
# gh 会优先读取 GH_TOKEN；若只有 GITHUB_TOKEN 则同步过去
export GH_TOKEN="${GH_TOKEN:-$GITHUB_TOKEN}"

USER_LOGIN="$(gh api user --jq .login 2>/dev/null)" \
    || die "PAT 认证失败，请检查 token 是否有效"
log "已认证为 GitHub 用户：$USER_LOGIN"

# 2. 读取公钥内容（支持文件路径、直接字符串、stdin）
if [[ "$KEY_INPUT" == "-" ]]; then
    PUBKEY="$(cat)"
elif [[ -f "$KEY_INPUT" ]]; then
    PUBKEY="$(cat "$KEY_INPUT")"
else
    PUBKEY="$KEY_INPUT"
fi
PUBKEY="$(echo "$PUBKEY" | tr -d '\r' | sed '/^[[:space:]]*$/d' | head -n1)"

# 3. 校验公钥格式，防止误传私钥
if echo "$PUBKEY" | grep -q "PRIVATE KEY"; then
    die "检测到私钥！请提供 .pub 公钥文件"
fi
if ! echo "$PUBKEY" | grep -Eq '^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com) [A-Za-z0-9+/=]+'; then
    die "公钥格式无效：$PUBKEY"
fi
if command -v ssh-keygen >/dev/null 2>&1; then
    FP="$(ssh-keygen -lf - <<<"$PUBKEY" 2>/dev/null)" || die "ssh-keygen 无法解析该公钥"
    log "公钥指纹：$FP"
fi

# 4. 检查是否已存在（按密钥本体比较，忽略注释）
KEY_BODY="$(echo "$PUBKEY" | awk '{print $1" "$2}')"
if [[ "$KEY_TYPE" == "signing" ]]; then
    ENDPOINT="user/ssh_signing_keys"
else
    ENDPOINT="user/keys"
fi

if gh api --paginate "$ENDPOINT" --jq '.[].key' 2>/dev/null \
    | awk '{print $1" "$2}' | grep -qxF "$KEY_BODY"; then
    warn "该公钥已作为 $KEY_TYPE 密钥存在于账户 $USER_LOGIN 中，跳过添加"
    exit 0
fi

# 5. 添加公钥
log "正在添加公钥（标题：$TITLE，类型：$KEY_TYPE）..."
echo "$PUBKEY" | gh ssh-key add - --title "$TITLE" --type "$KEY_TYPE" \
    || die "添加失败，请确认 PAT 具备相应的 SSH key 写权限"

log "添加成功！当前账户下的 SSH 密钥："
gh ssh-key list