#!/bin/bash
#
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║                                                                           ║
# ║   🦞 OpenClaw 一键部署脚本 v1.0.0                                          ║
# ║   智能 AI 助手部署工具 - 支持多平台多模型                                    ║
# ║                                                                           ║
# ║   GitHub: https://github.com/cwj526/OpenClawInstaller                     ║
# ║   官方文档: https://clawd.bot/docs                                         ║
# ║                                                                           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# 使用方法:
#   curl -fsSL https://raw.githubusercontent.com/cwj526/OpenClawInstaller/main/install.sh | bash
#   或本地执行: chmod +x install.sh && ./install.sh
#

set -e

# ================================ TTY 检测 ================================
# 当通过 curl | bash 运行时，stdin 是管道，需要从 /dev/tty 读取用户输入
if [ -t 0 ]; then
    # stdin 是终端
    TTY_INPUT="/dev/stdin"
    RUN_FROM_PIPE="false"
else
    # stdin 是管道，使用 /dev/tty
    TTY_INPUT="/dev/tty"
    RUN_FROM_PIPE="true"
fi

# ================================ 颜色定义 ================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
NC='\033[0m' # 无颜色

# ================================ 配置变量 ================================
OPENCLAW_VERSION="latest"
CONFIG_DIR="$HOME/.openclaw"
CONFIG_MENU_PATH="$CONFIG_DIR/config-menu.sh"
MIN_NODE_VERSION=22
GITHUB_REPO="cwj526/OpenClawInstaller"
GITHUB_RAW_URL="https://raw.githubusercontent.com/$GITHUB_REPO/main"
INSTALL_MODE=""
FORCE_REINSTALL="false"

# ================================ 工具函数 ================================

print_banner() {
    echo -e "${CYAN}"
    cat << 'EOF'
    
     ██████╗ ██████╗ ███████╗███╗   ██╗ ██████╗██╗      █████╗ ██╗    ██╗
    ██╔═══██╗██╔══██╗██╔════╝████╗  ██║██╔════╝██║     ██╔══██╗██║    ██║
    ██║   ██║██████╔╝█████╗  ██╔██╗ ██║██║     ██║     ███████║██║ █╗ ██║
    ██║   ██║██╔═══╝ ██╔══╝  ██║╚██╗██║██║     ██║     ██╔══██║██║███╗██║
    ╚██████╔╝██║     ███████╗██║ ╚████║╚██████╗███████╗██║  ██║╚███╔███╔╝
     ╚═════╝ ╚═╝     ╚══════╝╚═╝  ╚═══╝ ╚═════╝╚══════╝╚═╝  ╚═╝ ╚══╝╚══╝   
                                                                         
              🦞 智能 AI 助手一键部署工具 v1.0.0 🦞
    
EOF
    echo -e "${NC}"
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

run_with_timeout() {
    local timeout_seconds="$1"
    shift

    if command -v timeout >/dev/null 2>&1; then
        timeout "$timeout_seconds" "$@"
        return $?
    fi

    if command -v python3 >/dev/null 2>&1; then
        python3 - "$timeout_seconds" "$@" <<'PY'
import subprocess
import sys

timeout_seconds = int(sys.argv[1])
cmd = sys.argv[2:]

try:
    completed = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=timeout_seconds,
    )
    sys.stdout.write(completed.stdout or "")
    sys.exit(completed.returncode)
except subprocess.TimeoutExpired as exc:
    output = exc.stdout or ""
    if isinstance(output, bytes):
        output = output.decode(errors="replace")
    sys.stdout.write(output)
    sys.exit(124)
PY
        return $?
    fi

    "$@"
}

print_exit_hint() {
    echo -e "${GRAY}输入 q 可安全退出脚本${NC}"
}

safe_exit() {
    echo ""
    echo -e "${CYAN}已安全退出脚本。${NC}"
    exit 0
}

should_exit_input() {
    local value="$1"
    case "$value" in
        [qQ]|[qQ][uU][iI][tT]|[eE][xX][iI][tT]) return 0 ;;
        *) return 1 ;;
    esac
}

shell_quote_value() {
    local value="$1"
    printf '%q' "$value"
}

append_env_kv() {
    local env_file="$1"
    local key="$2"
    local value="$3"
    local escaped_value
    escaped_value=$(shell_quote_value "$value")
    printf 'export %s=%s\n' "$key" "$escaped_value" >> "$env_file"
}

write_env_header() {
    local env_file="$1"
    local source_label="$2"
    cat > "$env_file" << EOF
# OpenClaw 环境变量配置
# 由${source_label}自动生成: $(date '+%Y-%m-%d %H:%M:%S')
EOF
}

get_env_file_value() {
    local env_file="$1"
    local key="$2"
    if [ ! -f "$env_file" ]; then
        return 0
    fi

    local env_line
    env_line=$(grep "^export ${key}=" "$env_file" 2>/dev/null | tail -1)
    if [ -z "$env_line" ]; then
        return 0
    fi

    local env_value="${env_line#*=}"
    bash -c '
eval "value=$1"
printf "%s" "$value"
' _ "$env_value" 2>/dev/null
}

get_openclaw_primary_model_file() {
    local config_file="${1:-$HOME/.openclaw/openclaw.json}"
    if [ ! -f "$config_file" ]; then
        return 0
    fi

    if command -v node &> /dev/null; then
        node -e "
try {
  const config = JSON.parse(require('fs').readFileSync('$config_file', 'utf8'));
  console.log(config?.agents?.defaults?.model?.primary || '');
} catch (e) {
  console.log('');
}
" 2>/dev/null
        return 0
    fi

    if command -v python3 &> /dev/null; then
        python3 -c "
import json
try:
    with open('$config_file', 'r') as f:
        config = json.load(f)
    print(config.get('agents', {}).get('defaults', {}).get('model', {}).get('primary', ''))
except Exception:
    print('')
" 2>/dev/null
    fi
}

get_tuzi_group_from_model_ref() {
    local model_ref="$1"
    case "$model_ref" in
        tuzi-codex/*) printf '%s' "codex" ;;
        tuzi-claude-code/*) printf '%s' "claude-code" ;;
        *) printf '%s' "" ;;
    esac
}

get_tuzi_model_name_from_ref() {
    local model_ref="$1"
    case "$model_ref" in
        */*) printf '%s' "${model_ref#*/}" ;;
        *) printf '%s' "$model_ref" ;;
    esac
}

sanitize_model_display() {
    local value="$1"
    local sanitized=""

    sanitized=$(printf '%s' "$value" \
        | LC_ALL=C tr -cd '[:alnum:]._:/ -' 2>/dev/null \
        | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')

    if [ -n "$sanitized" ]; then
        printf '%s' "$sanitized"
    else
        printf '%s' "(无法识别的模型名)"
    fi
}

get_current_tuzi_group() {
    local config_file="${1:-$HOME/.openclaw/openclaw.json}"
    local primary_model=""
    primary_model=$(get_openclaw_primary_model_file "$config_file")
    get_tuzi_group_from_model_ref "$primary_model"
}

download_latest_config_menu() {
    local target_path="$1"
    mkdir -p "$(dirname "$target_path")"
    if curl --connect-timeout 10 --max-time 30 -fsSL "$GITHUB_RAW_URL/config-menu.sh" -o "$target_path.tmp"; then
        mv "$target_path.tmp" "$target_path"
        chmod +x "$target_path"
        return 0
    fi

    rm -f "$target_path.tmp" 2>/dev/null
    return 1
}

install_local_config_menu() {
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local local_config_menu="$script_dir/config-menu.sh"

    if [ ! -f "$local_config_menu" ]; then
        return 1
    fi

    mkdir -p "$(dirname "$CONFIG_MENU_PATH")"
    cp "$local_config_menu" "$CONFIG_MENU_PATH"
    chmod +x "$CONFIG_MENU_PATH"
}

ensure_config_menu_available() {
    if [ -f "$CONFIG_MENU_PATH" ]; then
        chmod +x "$CONFIG_MENU_PATH" 2>/dev/null || true
        return 0
    fi

    if install_local_config_menu; then
        return 0
    fi

    download_latest_config_menu "$CONFIG_MENU_PATH"
}

spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

# 从 TTY 读取用户输入（支持 curl | bash 模式）
read_input() {
    local prompt="$1"
    local var_name="$2"
    local value=""
    print_exit_hint
    echo -en "$prompt"
    read value < "$TTY_INPUT"
    if should_exit_input "$value"; then
        safe_exit
    fi
    printf -v "$var_name" '%s' "$value"
}

confirm() {
    local message="$1"
    local default="${2:-y}"
    
    if [ "$default" = "y" ]; then
        local prompt="[Y/n]"
    else
        local prompt="[y/N]"
    fi
    
    print_exit_hint
    echo -en "${YELLOW}$message $prompt: ${NC}"
    read response < "$TTY_INPUT"
    response=${response:-$default}
    
    case "$response" in
        [qQ]|[qQ][uU][iI][tT]|[eE][xX][iI][tT]) safe_exit ;;
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

# ================================ 系统检测 ================================

detect_os() {
    log_step "检测操作系统..."
    
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            OS=$ID
            OS_VERSION=$VERSION_ID
        fi
        PACKAGE_MANAGER=""
        if command -v apt-get &> /dev/null; then
            PACKAGE_MANAGER="apt"
        elif command -v yum &> /dev/null; then
            PACKAGE_MANAGER="yum"
        elif command -v dnf &> /dev/null; then
            PACKAGE_MANAGER="dnf"
        elif command -v pacman &> /dev/null; then
            PACKAGE_MANAGER="pacman"
        fi
        log_info "检测到 Linux 系统: $OS $OS_VERSION (包管理器: $PACKAGE_MANAGER)"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        OS="macos"
        OS_VERSION=$(sw_vers -productVersion)
        PACKAGE_MANAGER="brew"
        log_info "检测到 macOS 系统: $OS_VERSION"
    elif [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "cygwin" ]]; then
        OS="windows"
        log_info "检测到 Windows 系统 (Git Bash/Cygwin)"
    else
        log_error "不支持的操作系统: $OSTYPE"
        exit 1
    fi
}

check_root() {
    if [[ $EUID -eq 0 ]]; then
        log_warn "检测到以 root 用户运行"
        if ! confirm "建议使用普通用户运行，是否继续？" "n"; then
            exit 1
        fi
    fi
}

# ================================ 依赖检查与安装 ================================

check_command() {
    command -v "$1" &> /dev/null
}

read_valid_number_choice() {
    local prompt="$1"
    local min_value="$2"
    local max_value="$3"
    local default_value="$4"
    local result_var="$5"
    local choice=""

    while true; do
        print_exit_hint
        echo -en "$prompt"
        read choice < "$TTY_INPUT"
        choice=${choice:-$default_value}
        case "$choice" in
            [qQ]|[qQ][uU][iI][tT]|[eE][xX][iI][tT])
                safe_exit
                ;;
        esac
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge "$min_value" ] && [ "$choice" -le "$max_value" ]; then
            printf -v "$result_var" '%s' "$choice"
            return 0
        fi
        log_error "输入无效，请输入 $min_value-$max_value 之间的数字，或输入 q 退出"
    done
}

read_nonempty_value() {
    local prompt="$1"
    local result_var="$2"
    local value=""

    while true; do
        print_exit_hint
        echo -en "$prompt"
        read value < "$TTY_INPUT"
        if should_exit_input "$value"; then
            safe_exit
        fi
        if [ -n "$value" ]; then
            printf -v "$result_var" '%s' "$value"
            return 0
        fi
        log_error "输入不能为空，请重新输入，或输入 q 退出"
    done
}

read_value_allow_empty() {
    local prompt="$1"
    local result_var="$2"
    local value=""

    print_exit_hint
    echo -en "$prompt"
    read value < "$TTY_INPUT"
    if should_exit_input "$value"; then
        safe_exit
    fi
    printf -v "$result_var" '%s' "$value"
}

read_secret_value() {
    local prompt="$1"
    local result_var="$2"
    read_nonempty_value "$prompt" "$result_var"
}

show_usage() {
    cat << EOF
用法:
  bash install.sh
  bash install.sh --tuzi-only
  bash install.sh --full-install

参数:
  --tuzi-only      强制跳过安装，仅接入或更新 Tuzi API 配置
  --full-install   强制执行完整安装流程
  -h, --help       显示帮助
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --tuzi-only)
                INSTALL_MODE="tuzi-only"
                ;;
            --full-install)
                INSTALL_MODE="full-install"
                FORCE_REINSTALL="true"
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                log_error "未知参数: $1"
                show_usage
                exit 1
                ;;
        esac
        shift
    done
}

is_openclaw_ready() {
    if ! check_command openclaw; then
        return 1
    fi

    if ! openclaw --version >/dev/null 2>&1; then
        return 1
    fi

    if [ ! -d "$CONFIG_DIR" ]; then
        return 1
    fi

    local gateway_mode
    gateway_mode=$(openclaw config get gateway.mode 2>/dev/null || true)
    if [ -n "$gateway_mode" ] && [ "$gateway_mode" != "undefined" ]; then
        return 0
    fi

    if openclaw models status >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

is_tuzi_group_complete() {
    local group="$1"
    local env_file="$HOME/.openclaw/env"
    local key_var=""
    local model_var=""

    case "$group" in
        codex)
            key_var="TUZI_CODEX_API_KEY"
            model_var="TUZI_CODEX_MODEL"
            ;;
        *)
            key_var="TUZI_CLAUDE_CODE_API_KEY"
            model_var="TUZI_CLAUDE_CODE_MODEL"
            ;;
    esac

    local group_key
    local group_model
    group_key=$(get_env_file_value "$env_file" "$key_var")
    group_model=$(get_env_file_value "$env_file" "$model_var")

    [ -n "$group_key" ] && [ -n "$group_model" ]
}

is_tuzi_configured() {
    local env_file="$HOME/.openclaw/env"

    if [ ! -f "$env_file" ]; then
        return 1
    fi

    if is_tuzi_group_complete "claude-code" || is_tuzi_group_complete "codex"; then
        return 0
    fi

    return 1
}

show_current_tuzi_config() {
    local env_file="$HOME/.openclaw/env"
    local openclaw_json="$HOME/.openclaw/openclaw.json"

    if [ ! -f "$env_file" ]; then
        return 0
    fi

    local current_group
    local current_model_ref
    local claude_key
    local claude_model
    local claude_models
    local codex_key
    local codex_model
    local codex_models

    current_model_ref=$(get_openclaw_primary_model_file "$openclaw_json")
    current_group=$(get_tuzi_group_from_model_ref "$current_model_ref")
    claude_key=$(get_env_file_value "$env_file" "TUZI_CLAUDE_CODE_API_KEY")
    claude_model=$(get_env_file_value "$env_file" "TUZI_CLAUDE_CODE_MODEL")
    claude_models=$(get_env_file_value "$env_file" "TUZI_CLAUDE_CODE_MODELS")
    codex_key=$(get_env_file_value "$env_file" "TUZI_CODEX_API_KEY")
    codex_model=$(get_env_file_value "$env_file" "TUZI_CODEX_MODEL")
    codex_models=$(get_env_file_value "$env_file" "TUZI_CODEX_MODELS")

    echo -e "${CYAN}当前 Tuzi 配置:${NC}"
    if [ -n "$current_group" ]; then
        echo -e "  当前 Tuzi Provider: ${WHITE}$current_group${NC}"
        echo -e "  当前 Tuzi 模型: ${WHITE}$(get_tuzi_model_name_from_ref "$current_model_ref")${NC}"
    elif [ -n "$current_model_ref" ]; then
        echo -e "  当前默认模型不属于 Tuzi: ${WHITE}$current_model_ref${NC}"
    fi
    if [ -n "$claude_key" ] && [ -n "$claude_model" ]; then
        echo -e "  Claude-Code: ${GREEN}已配置${NC}"
        echo -e "    主模型: ${WHITE}$claude_model${NC}"
        [ -n "$claude_models" ] && echo -e "    已选模型: ${WHITE}$claude_models${NC}"
    elif [ -n "$claude_key" ]; then
        echo -e "  Claude-Code: ${YELLOW}未完成配置${NC}"
    else
        echo -e "  Claude-Code: ${GRAY}(未配置)${NC}"
    fi
    if [ -n "$codex_key" ] && [ -n "$codex_model" ]; then
        echo -e "  Codex: ${GREEN}已配置${NC}"
        echo -e "    主模型: ${WHITE}$codex_model${NC}"
        [ -n "$codex_models" ] && echo -e "    已选模型: ${WHITE}$codex_models${NC}"
    elif [ -n "$codex_key" ]; then
        echo -e "  Codex: ${YELLOW}未完成配置${NC}"
    else
        echo -e "  Codex: ${GRAY}(未配置)${NC}"
    fi
}

detect_install_mode() {
    if [ -n "$INSTALL_MODE" ]; then
        return 0
    fi

    if is_openclaw_ready; then
        echo -e "${CYAN}检测到本机已经安装 OpenClaw。${NC}"
        echo ""
        echo "  1) 继续完整安装/升级流程"
        echo "  2) 只修改配置，接入或更新 Tuzi API"
        echo ""
        read_valid_number_choice "${YELLOW}请选择 [1-2] (默认: 2): ${NC}" 1 2 2 install_choice
        case "$install_choice" in
            1)
                INSTALL_MODE="full-install"
                FORCE_REINSTALL="true"
                ;;
            *) INSTALL_MODE="tuzi-only" ;;
        esac
    else
        INSTALL_MODE="full-install"
    fi
}

get_shell_rc() {
    if [ -f "$HOME/.zshrc" ]; then
        echo "$HOME/.zshrc"
    elif [ -f "$HOME/.bashrc" ]; then
        echo "$HOME/.bashrc"
    elif [ -f "$HOME/.bash_profile" ]; then
        echo "$HOME/.bash_profile"
    else
        echo "$HOME/.bashrc"
    fi
}

ensure_path_export() {
    local export_line="$1"
    local shell_rc
    shell_rc=$(get_shell_rc)

    if [ -n "$shell_rc" ]; then
        touch "$shell_rc"
        if ! grep -Fq "$export_line" "$shell_rc" 2>/dev/null; then
            echo "" >> "$shell_rc"
            echo "# OpenClaw PATH" >> "$shell_rc"
            echo "$export_line" >> "$shell_rc"
        fi
    fi
}

install_homebrew() {
    if ! check_command brew; then
        log_step "安装 Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        
        # 添加到 PATH
        if [[ -f /opt/homebrew/bin/brew ]]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        elif [[ -f /usr/local/bin/brew ]]; then
            eval "$(/usr/local/bin/brew shellenv)"
        fi
    fi
}

install_nodejs() {
    log_step "检查 Node.js..."
    
    if check_command node; then
        local node_version=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
        if [ "$node_version" -ge "$MIN_NODE_VERSION" ]; then
            log_info "Node.js 版本满足要求: $(node -v)"
            return 0
        else
            log_warn "Node.js 版本过低: $(node -v)，需要 v$MIN_NODE_VERSION+"
        fi
    fi
    
    log_step "安装 Node.js $MIN_NODE_VERSION..."
    
    case "$OS" in
        macos)
            install_homebrew
            brew install node@22
            brew link --overwrite node@22
            ;;
        ubuntu|debian)
            curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
            sudo apt-get install -y nodejs
            ;;
        centos|rhel|fedora)
            curl -fsSL https://rpm.nodesource.com/setup_22.x | sudo bash -
            sudo yum install -y nodejs
            ;;
        arch|manjaro)
            sudo pacman -S nodejs npm --noconfirm
            ;;
        *)
            log_error "无法自动安装 Node.js，请手动安装 v$MIN_NODE_VERSION+"
            exit 1
            ;;
    esac
    
    log_info "Node.js 安装完成: $(node -v)"
}

install_git() {
    if ! check_command git; then
        log_step "安装 Git..."
        case "$OS" in
            macos)
                install_homebrew
                brew install git
                ;;
            ubuntu|debian)
                sudo apt-get update && sudo apt-get install -y git
                ;;
            centos|rhel|fedora)
                sudo yum install -y git
                ;;
            arch|manjaro)
                sudo pacman -S git --noconfirm
                ;;
        esac
    fi
    log_info "Git 版本: $(git --version)"
}

install_dependencies() {
    log_step "检查并安装依赖..."
    
    # 安装基础依赖
    case "$OS" in
        ubuntu|debian)
            sudo apt-get update
            sudo apt-get install -y curl wget jq
            ;;
        centos|rhel|fedora)
            sudo yum install -y curl wget jq
            ;;
        macos)
            install_homebrew
            brew install curl wget jq
            ;;
    esac
    
    install_git
    install_nodejs
}

# ================================ OpenClaw 安装 ================================

create_directories() {
    log_step "创建配置目录..."
    
    mkdir -p "$CONFIG_DIR"
    
    log_info "配置目录: $CONFIG_DIR"
}

install_openclaw() {
    log_step "安装 OpenClaw..."
    
    # 检查是否已安装
    if check_command openclaw; then
        local current_version=$(openclaw --version 2>/dev/null || echo "unknown")
        log_warn "OpenClaw 已安装 (版本: $current_version)"
        if [ "$FORCE_REINSTALL" != "true" ] && ! confirm "是否重新安装/更新？"; then
            init_openclaw_config
            return 0
        fi
    fi
    
    # 优先尝试 npm 全局安装，失败时回退到用户目录安装
    log_info "正在从 npm 安装 OpenClaw..."
    if npm install -g openclaw@$OPENCLAW_VERSION --unsafe-perm; then
        log_info "已完成全局安装"
    else
        log_warn "全局安装失败，正在切换到用户目录安装..."
        local npm_prefix="$HOME/.local/openclaw"
        local npm_bin="$npm_prefix/bin"
        mkdir -p "$npm_prefix"

        if npm install -g openclaw@$OPENCLAW_VERSION --unsafe-perm --prefix "$npm_prefix"; then
            export PATH="$npm_bin:$PATH"
            ensure_path_export "export PATH=\"$npm_bin:\$PATH\""
            hash -r 2>/dev/null || true
            log_info "已安装到用户目录: $npm_prefix"
            log_info "当前会话已自动加入 PATH"
        else
            log_error "OpenClaw 安装失败"
            echo ""
            echo -e "${YELLOW}可尝试以下方案:${NC}"
            echo "  1. 使用 sudo 重新运行安装脚本"
            echo "  2. 手动执行: npm install -g openclaw@$OPENCLAW_VERSION --prefix \"$npm_prefix\""
            echo "  3. 重新打开终端后确认 PATH 包含: $npm_bin"
            exit 1
        fi
    fi

    # 验证安装
    if check_command openclaw; then
        log_info "OpenClaw 安装成功: $(openclaw --version 2>/dev/null || echo 'installed')"
        init_openclaw_config
    else
        log_error "OpenClaw 安装失败"
        exit 1
    fi
}

# 初始化 OpenClaw 配置
init_openclaw_config() {
    log_step "初始化 OpenClaw 配置..."
    
    local OPENCLAW_DIR="$HOME/.openclaw"
    
    # 创建必要的目录
    mkdir -p "$OPENCLAW_DIR/agents/main/sessions"
    mkdir -p "$OPENCLAW_DIR/agents/main/agent"
    mkdir -p "$OPENCLAW_DIR/credentials"
    
    # 修复权限
    chmod 700 "$OPENCLAW_DIR" 2>/dev/null || true
    
    # 设置 gateway.mode 为 local
    if check_command openclaw; then
        openclaw config set gateway.mode local 2>/dev/null || true
        log_info "Gateway 模式已设置为 local"
        
        # 检查 gateway.auth 配置，如果是 token 模式但没有 token，则自动生成
        local auth_mode=$(openclaw config get gateway.auth 2>/dev/null)
        if [ "$auth_mode" = "token" ]; then
            local auth_token=$(openclaw config get gateway.auth.token 2>/dev/null)
            if [ -z "$auth_token" ] || [ "$auth_token" = "undefined" ]; then
                # 自动生成一个随机 token
                local new_token=$(openssl rand -hex 32 2>/dev/null || cat /dev/urandom | head -c 32 | xxd -p 2>/dev/null || date +%s%N | sha256sum | head -c 64)
                openclaw config set gateway.auth.token "$new_token" 2>/dev/null || true
                log_info "已自动生成 Gateway Auth Token"
            fi
        fi
    fi
}

# 配置 OpenClaw 使用的 AI 模型和 API Key
get_tuzi_group_settings() {
    local group="$1"
    case "$group" in
        codex)
            echo "tuzi-codex|https://api.tu-zi.com/v1|openai-responses"
            ;;
        *)
            echo "tuzi-claude-code|https://api.tu-zi.com|anthropic-messages"
            ;;
    esac
}

choose_tuzi_model() {
    local group="$1"
    local result_var="$2"
    local allow_finish="${3:-false}"
    local models=()

    if [ "$group" = "codex" ]; then
        models=(
            "gpt-5.4" "gpt-5.3-codex" "gpt-5.2-medium" "gpt-5.2-high"
            "gpt-5.2-codex" "gpt-5.2" "gpt-5.1-high" "gpt-5.1-medium"
            "gpt-5.1-low" "gpt-5.1-codex-max-high" "gpt-5.1-codex-max"
            "gpt-5.1" "gpt-5-codex" "gpt-5-high" "gpt-5-low" "gpt-5"
        )
    else
        models=(
            "claude-sonnet-4-6" "claude-sonnet-4-6-thinking" "claude-sonnet-4-5-20250929-thinking"
            "claude-sonnet-4-5-20250929" "claude-sonnet-4-20250514-thinking" "claude-sonnet-4-20250514"
            "claude-opus-4-6" "claude-opus-4-5-20251101-thinking" "claude-opus-4-5-20251101"
            "claude-opus-4-5" "claude-opus-4-20250514-thinking" "claude-opus-4-20250514"
        )
    fi

    echo "选择模型:"
    local i=1
    for model in "${models[@]}"; do
        echo "  $i) $model"
        i=$((i + 1))
    done
    echo "  $i) 自定义模型名称"
    if [ "$allow_finish" = "true" ]; then
        echo "  0) 完成选择"
        read_valid_number_choice "${YELLOW}选择模型 [0-$i] (默认: 1): ${NC}" 0 "$i" 1 model_choice
    else
        read_valid_number_choice "${YELLOW}选择模型 [1-$i] (默认: 1): ${NC}" 1 "$i" 1 model_choice
    fi

    local selected_value=""
    if [ "$allow_finish" = "true" ] && [ "$model_choice" = "0" ]; then
        selected_value="__DONE__"
    elif [ "$model_choice" -ge 1 ] 2>/dev/null && [ "$model_choice" -lt "$i" ] 2>/dev/null; then
        selected_value="${models[$((model_choice - 1))]}"
    else
        read_nonempty_value "${YELLOW}输入模型名称: ${NC}" selected_value
    fi

    printf -v "$result_var" '%s' "$selected_value"
}

choose_tuzi_models() {
    local group="$1"
    local result_var="$2"
    local collected_models=()
    local picked_model=""

    while true; do
        local allow_finish="false"
        [ ${#collected_models[@]} -gt 0 ] && allow_finish="true"
        choose_tuzi_model "$group" picked_model "$allow_finish"
        if [ "$picked_model" = "__DONE__" ]; then
            break
        fi
        if [ -z "$picked_model" ]; then
            continue
        fi

        local already_selected=false
        local model
        for model in "${collected_models[@]}"; do
            if [ "$model" = "$picked_model" ]; then
                already_selected=true
                break
            fi
        done

        if [ "$already_selected" = true ]; then
            log_warn "模型已添加: $picked_model"
        else
            collected_models+=("$picked_model")
            log_info "已添加模型: $picked_model"
        fi

        echo ""
    done

    local joined_models=""
    local idx
    for idx in "${!collected_models[@]}"; do
        if [ -n "$joined_models" ]; then
            joined_models="${joined_models},${collected_models[$idx]}"
        else
            joined_models="${collected_models[$idx]}"
        fi
    done

    printf -v "$result_var" '%s' "$joined_models"
}

configure_tuzi_provider() {
    local group="$1"
    local api_key="$2"
    local primary_model="$3"
    local models_csv="$4"
    local config_file="$5"
    local update_default="${6:-false}"

    local settings
    settings=$(get_tuzi_group_settings "$group")
    local provider_id="${settings%%|*}"
    local rest="${settings#*|}"
    local base_url="${rest%%|*}"
    local api_type="${rest#*|}"

    local config_success=false

    if command -v node &> /dev/null; then
        local tmp_vars="/tmp/openclaw_tuzi_install_$$.json"
        cat > "$tmp_vars" << EOFVARS
{
  "config_file": "$config_file",
  "provider_id": "$provider_id",
  "base_url": "$base_url",
  "api_key": "$api_key",
  "api_type": "$api_type",
  "primary_model": "$primary_model",
  "models_csv": "$models_csv",
  "update_default": $update_default
}
EOFVARS
        node -e "
const fs = require('fs');
const vars = JSON.parse(fs.readFileSync('$tmp_vars', 'utf8'));
let config = {};
try {
  config = JSON.parse(fs.readFileSync(vars.config_file, 'utf8'));
} catch (e) {
  config = {};
}
config.auth ??= {};
config.auth.profiles ??= {};
config.auth.profiles[vars.provider_id + ':default'] = { provider: vars.provider_id, mode: 'api_key' };
config.models ??= {};
config.models.providers ??= {};
const modelIds = (vars.models_csv || vars.primary_model)
  .split(',')
  .map((item) => item.trim())
  .filter(Boolean);
const providerModels = modelIds.map((modelId) => ({
  id: modelId,
  name: modelId,
  reasoning: false,
  input: ['text'],
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
  contextWindow: 200000,
  maxTokens: vars.provider_id === 'tuzi-codex' ? 100000 : 8192
}));
config.models.providers[vars.provider_id] = {
  baseUrl: vars.base_url,
  apiKey: vars.api_key,
  api: vars.api_type,
  models: providerModels
};
config.agents ??= {};
config.agents.defaults ??= {};
const fallbackModels = modelIds.slice(1).map((modelId) => vars.provider_id + '/' + modelId);
config.agents.defaults.models ??= {};
modelIds.forEach((modelId) => {
  config.agents.defaults.models[vars.provider_id + '/' + modelId] = {};
});
if (vars.update_default || !config.agents.defaults.model?.primary) {
  config.agents.defaults.model = {
    primary: vars.provider_id + '/' + vars.primary_model,
    fallbacks: fallbackModels
  };
}
fs.writeFileSync(vars.config_file, JSON.stringify(config, null, 2));
" 2>/dev/null
        local node_exit=$?
        rm -f "$tmp_vars" 2>/dev/null
        if [ $node_exit -eq 0 ]; then
            config_success=true
        fi
    fi

    if [ "$config_success" = false ] && command -v python3 &> /dev/null; then
        local tmp_vars="/tmp/openclaw_tuzi_install_$$.json"
        cat > "$tmp_vars" << EOFVARS
{
  "config_file": "$config_file",
  "provider_id": "$provider_id",
  "base_url": "$base_url",
  "api_key": "$api_key",
  "api_type": "$api_type",
  "primary_model": "$primary_model",
  "models_csv": "$models_csv",
  "update_default": $update_default
}
EOFVARS
        python3 -c "
import json
import os
with open('$tmp_vars', 'r') as f:
    vars = json.load(f)
config = {}
if os.path.exists(vars['config_file']):
    try:
        with open(vars['config_file'], 'r') as f:
            config = json.load(f)
    except Exception:
        config = {}
config.setdefault('auth', {}).setdefault('profiles', {})[vars['provider_id'] + ':default'] = {
    'provider': vars['provider_id'],
    'mode': 'api_key'
}
model_ids = [item.strip() for item in (vars.get('models_csv') or vars['primary_model']).split(',') if item.strip()]
provider_models = [{
    'id': model_id,
    'name': model_id,
    'reasoning': False,
    'input': ['text'],
    'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0},
    'contextWindow': 200000,
    'maxTokens': 100000 if vars['provider_id'] == 'tuzi-codex' else 8192
} for model_id in model_ids]
config.setdefault('models', {}).setdefault('providers', {})[vars['provider_id']] = {
    'baseUrl': vars['base_url'],
    'apiKey': vars['api_key'],
    'api': vars['api_type'],
    'models': provider_models
}
defaults = config.setdefault('agents', {}).setdefault('defaults', {})
defaults.setdefault('models', {})
for model_id in model_ids:
    defaults['models'][f\"{vars['provider_id']}/{model_id}\"] = {}
if vars.get('update_default') or not defaults.get('model', {}).get('primary'):
    defaults['model'] = {
        'primary': f\"{vars['provider_id']}/{vars['primary_model']}\",
        'fallbacks': [f\"{vars['provider_id']}/{model_id}\" for model_id in model_ids[1:]]
    }
with open(vars['config_file'], 'w') as f:
    json.dump(config, f, indent=2)
" 2>/dev/null
        local py_exit=$?
        rm -f "$tmp_vars" 2>/dev/null
        if [ $py_exit -eq 0 ]; then
            config_success=true
        fi
    fi

    if [ "$config_success" = false ]; then
        log_error "Tuzi Provider 写入失败（需要 node 或 python3）"
        return 1
    fi

    return 0
}

configure_openclaw_model() {
    log_step "配置 OpenClaw AI 模型..."
    
    local env_file="$HOME/.openclaw/env"
    local openclaw_json="$HOME/.openclaw/openclaw.json"
    local existing_primary_model
    local existing_tuzi_group
    local should_update_default="false"

    local settings
    settings=$(get_tuzi_group_settings "$TUZI_GROUP")
    local provider_id="${settings%%|*}"
    local rest="${settings#*|}"
    local base_url="${rest%%|*}"
    rest="${rest#*|}"
    local api_type="${rest%%|*}"

    local claude_key=""
    local claude_model=""
    local claude_models=""
    local codex_key=""
    local codex_model=""
    local codex_models=""
    if [ -f "$env_file" ]; then
        claude_key=$(get_env_file_value "$env_file" "TUZI_CLAUDE_CODE_API_KEY")
        claude_model=$(get_env_file_value "$env_file" "TUZI_CLAUDE_CODE_MODEL")
        claude_models=$(get_env_file_value "$env_file" "TUZI_CLAUDE_CODE_MODELS")
        codex_key=$(get_env_file_value "$env_file" "TUZI_CODEX_API_KEY")
        codex_model=$(get_env_file_value "$env_file" "TUZI_CODEX_MODEL")
        codex_models=$(get_env_file_value "$env_file" "TUZI_CODEX_MODELS")
    fi

    if [ "$TUZI_GROUP" = "codex" ]; then
        codex_key="$AI_KEY"
        codex_model="$AI_MODEL"
        codex_models="$AI_MODELS"
    else
        claude_key="$AI_KEY"
        claude_model="$AI_MODEL"
        claude_models="$AI_MODELS"
    fi

    existing_primary_model=$(get_openclaw_primary_model_file "$openclaw_json")
    existing_tuzi_group=$(get_tuzi_group_from_model_ref "$existing_primary_model")
    if [ -z "$existing_primary_model" ] || [ "$existing_tuzi_group" = "$TUZI_GROUP" ]; then
        should_update_default="true"
    elif [ -n "$existing_primary_model" ]; then
        local requested_model="$provider_id/$AI_MODEL"
        local display_existing_model
        local display_requested_model
        display_existing_model=$(sanitize_model_display "$existing_primary_model")
        display_requested_model=$(sanitize_model_display "$requested_model")
        if confirm "当前默认模型是 ${display_existing_model}, 是否切换为 ${display_requested_model}?" "n"; then
            should_update_default="true"
        fi
    fi

    write_env_header "$env_file" "安装脚本"
    if [ -n "$claude_key" ]; then
        append_env_kv "$env_file" "TUZI_CLAUDE_CODE_API_KEY" "$claude_key"
    fi
    if [ -n "$claude_model" ]; then
        append_env_kv "$env_file" "TUZI_CLAUDE_CODE_MODEL" "$claude_model"
    fi
    if [ -n "$claude_models" ]; then
        append_env_kv "$env_file" "TUZI_CLAUDE_CODE_MODELS" "$claude_models"
    fi
    if [ -n "$codex_key" ]; then
        append_env_kv "$env_file" "TUZI_CODEX_API_KEY" "$codex_key"
    fi
    if [ -n "$codex_model" ]; then
        append_env_kv "$env_file" "TUZI_CODEX_MODEL" "$codex_model"
    fi
    if [ -n "$codex_models" ]; then
        append_env_kv "$env_file" "TUZI_CODEX_MODELS" "$codex_models"
    fi
    
    chmod 600 "$env_file"
    log_info "环境变量配置已保存到: $env_file"
    
    configure_tuzi_provider "$TUZI_GROUP" "$AI_KEY" "$AI_MODEL" "$AI_MODELS" "$openclaw_json" "$should_update_default"

    if check_command openclaw && [ "$should_update_default" = "true" ]; then
        source "$env_file"
        local openclaw_model="$provider_id/$AI_MODEL"
        local set_result
        set_result=$(openclaw models set "$openclaw_model" 2>&1) || true
        local set_exit=$?

        if [ $set_exit -eq 0 ]; then
            log_info "默认模型已设置为: $openclaw_model"
        else
            log_warn "模型设置可能失败: $openclaw_model"
            echo -e "  ${GRAY}$set_result${NC}" | head -3
            log_info "尝试使用 config set 设置模型..."
            openclaw config set models.default "$openclaw_model" 2>/dev/null || true
        fi
    elif check_command openclaw; then
        log_info "已保留当前默认模型，新增 Provider: $provider_id/$AI_MODEL"
    fi
    
    # 添加到 shell 配置文件
    add_env_to_shell "$env_file"
}

# 配置自定义 provider（用于支持自定义 API 地址）
# 参数: provider api_key model base_url config_file [api_type]
configure_custom_provider() {
    local provider="$1"
    local api_key="$2"
    local model="$3"
    local base_url="$4"
    local config_file="$5"
    local custom_api_type="$6"  # 可选参数，用于覆盖默认 API 类型
    
    # 参数校验
    if [ -z "$model" ]; then
        log_error "模型名称不能为空"
        return 0  # 返回 0 防止 set -e 退出
    fi
    
    if [ -z "$api_key" ]; then
        log_error "API Key 不能为空"
        return 0
    fi
    
    if [ -z "$base_url" ]; then
        log_error "API 地址不能为空"
        return 0
    fi
    
    log_step "配置自定义 Provider..."
    
    # 确保配置目录存在
    local config_dir=$(dirname "$config_file")
    mkdir -p "$config_dir" 2>/dev/null || true
    
    # 确定 API 类型
    # 如果传入了自定义 API 类型，使用传入的值；否则根据 provider 自动判断
    local api_type=""
    if [ -n "$custom_api_type" ]; then
        api_type="$custom_api_type"
    elif [ "$provider" = "anthropic" ]; then
        api_type="anthropic-messages"
    else
        api_type="openai-responses"
    fi
    local provider_id="${provider}-custom"
    
    # 先检查是否存在旧的自定义配置，并询问是否清理
    local do_cleanup="false"
    if [ -f "$config_file" ]; then
        # 检查是否有旧的自定义 provider 配置
        local has_old_config="false"
        if grep -q '"anthropic-custom"' "$config_file" 2>/dev/null || \
           grep -q '"openai-custom"' "$config_file" 2>/dev/null; then
            has_old_config="true"
        fi
        
        if [ "$has_old_config" = "true" ]; then
            echo ""
            echo -e "${CYAN}当前已有自定义 Provider 配置:${NC}"
            # 显示当前配置的 provider 和模型
            if command -v node &> /dev/null; then
                node -e "
const fs = require('fs');
try {
    const config = JSON.parse(fs.readFileSync('$config_file', 'utf8'));
    const providers = config.models?.providers || {};
    for (const [id, p] of Object.entries(providers)) {
        if (id.includes('-custom')) {
            console.log('  - Provider: ' + id);
            console.log('    API 地址: ' + p.baseUrl);
            if (p.models?.length) {
                console.log('    模型: ' + p.models.map(m => m.id).join(', '));
            }
        }
    }
} catch (e) {}
" 2>/dev/null
            fi
            echo ""
            echo -e "${YELLOW}是否清理旧的自定义配置？${NC}"
            echo -e "${GRAY}(清理可避免配置累积，推荐选择 Y)${NC}"
            if confirm "清理旧配置？" "y"; then
                do_cleanup="true"
            fi
        fi
    fi
    
    # 读取现有配置或创建新配置
    local config_json="{}"
    if [ -f "$config_file" ]; then
        config_json=$(cat "$config_file")
    fi
    
    # 使用 node 或 python 来处理 JSON
    local config_success=false
    
    if command -v node &> /dev/null; then
        log_info "使用 node 配置自定义 Provider..."
        
        # 将变量写入临时文件，避免 shell 转义问题
        local tmp_vars="/tmp/openclaw_provider_vars_$$.json"
        cat > "$tmp_vars" << EOFVARS
{
    "config_file": "$config_file",
    "provider_id": "$provider_id",
    "base_url": "$base_url",
    "api_key": "$api_key",
    "model": "$model",
    "api_type": "$api_type",
    "do_cleanup": "$do_cleanup"
}
EOFVARS
        
        node -e "
const fs = require('fs');
const vars = JSON.parse(fs.readFileSync('$tmp_vars', 'utf8'));

let config = {};
try {
    config = JSON.parse(fs.readFileSync(vars.config_file, 'utf8'));
} catch (e) {
    config = {};
}

// 确保 models.providers 结构存在
if (!config.models) config.models = {};
if (!config.models.providers) config.models.providers = {};

// 根据用户选择决定是否清理旧配置
if (vars.do_cleanup === 'true') {
    delete config.models.providers['anthropic-custom'];
    delete config.models.providers['openai-custom'];
    if (config.models.configured) {
        config.models.configured = config.models.configured.filter(m => {
            if (m.startsWith('openai/claude')) return false;
            if (m.startsWith('openrouter/claude') && !m.includes('openrouter.ai')) return false;
            return true;
        });
    }
    if (config.models.aliases) {
        delete config.models.aliases['claude-custom'];
    }
    console.log('Old configurations cleaned up');
}

// 添加自定义 provider
config.models.providers[vars.provider_id] = {
    baseUrl: vars.base_url,
    apiKey: vars.api_key,
    models: [
        {
            id: vars.model,
            name: vars.model,
            api: vars.api_type,
            input: ['text','image'],
            contextWindow: 200000,
            maxTokens: 8192
        }
    ]
};

fs.writeFileSync(vars.config_file, JSON.stringify(config, null, 2));
console.log('Custom provider configured: ' + vars.provider_id);
" 2>&1
        local node_exit=$?
        rm -f "$tmp_vars" 2>/dev/null
        
        if [ $node_exit -eq 0 ]; then
            config_success=true
            log_info "自定义 Provider 已配置: $provider_id"
        else
            log_warn "node 配置失败 (exit: $node_exit)，尝试使用 python3..."
        fi
    fi
    
    # 如果 node 失败或不存在，尝试 python3
    if [ "$config_success" = false ] && command -v python3 &> /dev/null; then
        log_info "使用 python3 配置自定义 Provider..."
        
        # 将变量写入临时文件，避免 shell 转义问题
        local tmp_vars="/tmp/openclaw_provider_vars_$$.json"
        cat > "$tmp_vars" << EOFVARS
{
    "config_file": "$config_file",
    "provider_id": "$provider_id",
    "base_url": "$base_url",
    "api_key": "$api_key",
    "model": "$model",
    "api_type": "$api_type",
    "do_cleanup": "$do_cleanup"
}
EOFVARS
        
        python3 -c "
import json
import os

# 从临时文件读取变量
with open('$tmp_vars', 'r') as f:
    vars = json.load(f)

config = {}
config_file = vars['config_file']
if os.path.exists(config_file):
    try:
        with open(config_file, 'r') as f:
            config = json.load(f)
    except:
        config = {}

if 'models' not in config:
    config['models'] = {}
if 'providers' not in config['models']:
    config['models']['providers'] = {}

# 根据用户选择决定是否清理旧配置
if vars['do_cleanup'] == 'true':
    config['models']['providers'].pop('anthropic-custom', None)
    config['models']['providers'].pop('openai-custom', None)
    if 'configured' in config['models']:
        config['models']['configured'] = [
            m for m in config['models']['configured']
            if not (m.startswith('openai/claude') or 
                    (m.startswith('openrouter/claude') and 'openrouter.ai' not in m))
        ]
    if 'aliases' in config['models']:
        config['models']['aliases'].pop('claude-custom', None)
    print('Old configurations cleaned up')

config['models']['providers'][vars['provider_id']] = {
    'baseUrl': vars['base_url'],
    'apiKey': vars['api_key'],
    'models': [
        {
            'id': vars['model'],
            'name': vars['model'],
            'api': vars['api_type'],
            'input': ['text','image'],
            'contextWindow': 200000,
            'maxTokens': 8192
        }
    ]
}

with open(config_file, 'w') as f:
    json.dump(config, f, indent=2)
print('Custom provider configured: ' + vars['provider_id'])
" 2>&1
        local py_exit=$?
        rm -f "$tmp_vars" 2>/dev/null
        
        if [ $py_exit -eq 0 ]; then
            config_success=true
            log_info "自定义 Provider 已配置: $provider_id"
        else
            log_warn "python3 配置失败 (exit: $py_exit)"
        fi
    fi
    
    if [ "$config_success" = false ]; then
        log_warn "无法配置自定义 Provider（需要 node 或 python3）"
    fi
    
    # 验证配置文件是否正确写入
    if [ -f "$config_file" ]; then
        if grep -q "$provider_id" "$config_file" 2>/dev/null; then
            log_info "配置文件验证通过: $config_file"
        else
            log_warn "配置文件可能未正确写入，请检查: $config_file"
        fi
    fi
}

# 添加环境变量到 shell 配置
add_env_to_shell() {
    local env_file="$1"
    local shell_rc=""
    
    if [ -f "$HOME/.zshrc" ]; then
        shell_rc="$HOME/.zshrc"
    elif [ -f "$HOME/.bashrc" ]; then
        shell_rc="$HOME/.bashrc"
    elif [ -f "$HOME/.bash_profile" ]; then
        shell_rc="$HOME/.bash_profile"
    fi
    
    if [ -n "$shell_rc" ]; then
        # 检查是否已添加
        if ! grep -q "source.*openclaw/env" "$shell_rc" 2>/dev/null; then
            echo "" >> "$shell_rc"
            echo "# OpenClaw 环境变量" >> "$shell_rc"
            echo "[ -f \"$env_file\" ] && source \"$env_file\"" >> "$shell_rc"
            log_info "环境变量已添加到: $shell_rc"
        fi
    fi
}

# ================================ 配置向导 ================================

# create_default_config 已移除 - OpenClaw 使用 openclaw.json 和环境变量

run_onboard_wizard() {
    log_step "运行配置向导..."
    
    echo ""
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}           🧙 OpenClaw 核心配置向导${NC}"
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    # 检查是否已有配置
    local skip_ai_config=false
    local skip_identity_config=false
    local env_file="$HOME/.openclaw/env"
    
    if [ -f "$env_file" ]; then
        echo -e "${YELLOW}检测到已有配置！${NC}"
        echo ""
        
        # 显示当前模型配置
        if check_command openclaw; then
            echo -e "${CYAN}当前 OpenClaw 配置:${NC}"
            openclaw models status 2>/dev/null | head -10 || true
            echo ""
        fi
        
        # 询问是否重新配置 AI
        if ! confirm "是否重新配置 AI 模型提供商？" "n"; then
            skip_ai_config=true
            log_info "使用现有 AI 配置"
            
            if confirm "是否测试现有 API 连接？" "y"; then
                # 获取当前模型
                AI_MODEL=$(openclaw config get models.default 2>/dev/null | sed 's|.*/||')
                local tuzi_group
                local tuzi_api_key
                local tuzi_base_url
                local anthropic_api_key
                local anthropic_base_url
                local openai_api_key
                local openai_base_url
                local google_api_key

                tuzi_group=$(get_current_tuzi_group "$HOME/.openclaw/openclaw.json")
                if [ "$tuzi_group" = "codex" ]; then
                    tuzi_api_key=$(get_env_file_value "$env_file" "TUZI_CODEX_API_KEY")
                    tuzi_base_url="https://api.tu-zi.com/v1"
                elif [ "$tuzi_group" = "claude-code" ]; then
                    tuzi_api_key=$(get_env_file_value "$env_file" "TUZI_CLAUDE_CODE_API_KEY")
                    tuzi_base_url="https://api.tu-zi.com"
                fi
                anthropic_api_key=$(get_env_file_value "$env_file" "ANTHROPIC_API_KEY")
                anthropic_base_url=$(get_env_file_value "$env_file" "ANTHROPIC_BASE_URL")
                openai_api_key=$(get_env_file_value "$env_file" "OPENAI_API_KEY")
                openai_base_url=$(get_env_file_value "$env_file" "OPENAI_BASE_URL")
                google_api_key=$(get_env_file_value "$env_file" "GOOGLE_API_KEY")

                if [ -n "$tuzi_api_key" ]; then
                    AI_PROVIDER="tuzi"
                    AI_KEY="$tuzi_api_key"
                    BASE_URL="$tuzi_base_url"
                elif [ -n "$anthropic_api_key" ]; then
                    AI_PROVIDER="anthropic"
                    AI_KEY="$anthropic_api_key"
                    BASE_URL="$anthropic_base_url"
                elif [ -n "$openai_api_key" ]; then
                    AI_PROVIDER="openai"
                    AI_KEY="$openai_api_key"
                    BASE_URL="$openai_base_url"
                elif [ -n "$google_api_key" ]; then
                    AI_PROVIDER="google"
                    AI_KEY="$google_api_key"
                fi
                test_api_connection
            fi
        fi
        
        echo ""
    else
        echo -e "${CYAN}接下来将引导你完成核心配置，包括:${NC}"
        echo "  1. 配置 Tuzi API"
        echo "  2. 测试 API 连接"
        echo "  3. 设置基本身份信息"
        echo ""
    fi
    
    # AI 配置
    if [ "$skip_ai_config" = false ]; then
        setup_ai_provider
        # 先配置 OpenClaw（设置环境变量和自定义 provider），然后再测试
        configure_openclaw_model
        test_api_connection
    else
        # 即使跳过配置，也可选择测试连接
        if confirm "是否测试现有 API 连接？" "y"; then
            test_api_connection
        fi
    fi
    
    # 身份配置
    if [ "$skip_identity_config" = false ]; then
        setup_identity
    else
        # 初始化渠道配置变量
        TELEGRAM_ENABLED="false"
        DISCORD_ENABLED="false"
        SHELL_ENABLED="false"
        FILE_ACCESS="false"
    fi
    
    log_info "核心配置完成！"
}

# ================================ AI Provider 配置 ================================

setup_ai_provider() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}  第 1 步: 配置 Tuzi API${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${WHITE}当前安装流程仅支持 Tuzi API 快速接入${NC}"
    echo -e "${GRAY}获取 Key: https://api.tu-zi.com/token${NC}"
    echo ""
    echo "  1) 🟣 Claude-Code"
    echo "  2) 🟢 Codex"
    echo ""
    read_valid_number_choice "${YELLOW}请选择 Tuzi 分组 [1-2] (默认: 1): ${NC}" 1 2 1 group_choice
    case "$group_choice" in
        2) TUZI_GROUP="codex" ;;
        *) TUZI_GROUP="claude-code" ;;
    esac

    echo ""
    read_secret_value "${YELLOW}输入 API Key: ${NC}" AI_KEY
    echo ""
    choose_tuzi_models "$TUZI_GROUP" AI_MODELS
    AI_MODEL="${AI_MODELS%%,*}"

    AI_PROVIDER="tuzi"
    BASE_URL=""
    AI_API_TYPE=""
    
    echo ""
    log_info "AI Provider 配置完成"
    echo -e "  提供商: ${WHITE}Tuzi API${NC}"
    echo -e "  Provider: ${WHITE}$TUZI_GROUP${NC}"
    echo -e "  默认模型: ${WHITE}$AI_MODEL${NC}"
    echo -e "  已选模型: ${WHITE}$AI_MODELS${NC}"
}

# ================================ API 连接测试 ================================

test_api_connection() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}  第 2 步: 测试 API 连接${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    local test_passed=false
    local max_retries=3
    local retry_count=0
    
    # 确保环境变量已加载
    local env_file="$HOME/.openclaw/env"
    [ -f "$env_file" ] && source "$env_file"
    
    if ! check_command openclaw; then
        echo -e "${YELLOW}OpenClaw 未安装，跳过测试${NC}"
        return 0
    fi
    
    # 显示当前模型配置
    echo -e "${CYAN}当前模型配置:${NC}"
    openclaw models status 2>&1 | grep -E "Default|Auth|effective" | head -5
    echo ""
    
    while [ "$test_passed" = false ] && [ $retry_count -lt $max_retries ]; do
        echo -e "${YELLOW}运行 openclaw agent --local 测试...${NC}"
        echo ""
        
        # 使用 openclaw agent --local 测试（添加超时）
        local result
        local exit_code
        
        # 真实调用一次本地 agent，验证模型配置是否能完成单轮响应
        set +e
        result=$(run_with_timeout 30 openclaw agent --local --to "+1234567890" --message "回复 OK" 2>&1)
        exit_code=$?
        set -e

        if [ "$exit_code" = "124" ]; then
            result="${result:-测试超时（30秒）}"
        fi
        
        # 过滤掉 Node.js 警告信息和正常的系统日志
        result=$(echo "$result" | grep -v "ExperimentalWarning" | grep -v "at emitExperimentalWarning" | grep -v "at ModuleLoader" | grep -v "at callTranslator")
        
        # 保存原始结果用于显示
        local display_result="$result"
        
        # 过滤掉正常的插件加载日志和 Doctor warnings 用于错误判断
        local filtered_result=$(echo "$result" | grep -v "\[plugins\]" | grep -v "Doctor warnings" | grep -v "Registered.*tools" | grep -v "State dir migration" | grep -v "^│" | grep -v "^◇" | grep -v "^$")
        
        # 检查结果是否为空
        if [ -z "$filtered_result" ]; then
            # 如果过滤后为空，但原始结果不为空，可能只是系统日志
            if [ -n "$display_result" ]; then
                # 检查是否有实际的 AI 响应内容（不是日志）
                if echo "$display_result" | grep -qE "^[^│◇\[\]]"; then
                    filtered_result="$display_result"
                else
                    filtered_result="(只有系统日志，没有 AI 响应)"
                    exit_code=1
                fi
            else
                filtered_result="(无输出 - 命令可能立即退出)"
                exit_code=1
            fi
        fi
        
        # 判断是否成功：退出码为 0 且没有真正的错误信息
        # 注意：只匹配真正的错误，排除正常日志
        if [ $exit_code -eq 0 ] && ! echo "$filtered_result" | grep -qiE "^error:|api error|401|403|Unknown model|超时|Incorrect API|authentication failed"; then
            test_passed=true
            echo -e "${GREEN}✓ OpenClaw AI 测试成功！${NC}"
            echo ""
            # 显示 AI 响应（过滤掉空行和系统日志）
            local ai_response=$(echo "$display_result" | grep -v "^$" | grep -v "\[plugins\]" | grep -v "Doctor" | grep -v "^│" | grep -v "^◇" | head -5)
            if [ -n "$ai_response" ]; then
                echo -e "  ${CYAN}AI 响应:${NC}"
                echo "$ai_response" | sed 's/^/    /'
            fi
        else
            retry_count=$((retry_count + 1))
            echo -e "${RED}✗ OpenClaw AI 测试失败 (退出码: $exit_code)${NC}"
            echo ""
            
            # 显示过滤后的错误信息（排除正常日志）
            local error_display=$(echo "$filtered_result" | head -5)
            if [ -n "$error_display" ] && [ "$error_display" != "(只有系统日志，没有 AI 响应)" ]; then
                echo -e "  ${RED}错误信息:${NC}"
                echo "$error_display" | sed 's/^/    /'
            else
                echo -e "  ${YELLOW}没有收到 AI 响应，可能是 API 配置问题${NC}"
            fi
            echo ""
            
            # 显示完整原始输出（用于调试）
            if [ -n "$display_result" ]; then
                echo -e "  ${GRAY}完整输出 (前 8 行):${NC}"
                echo "$display_result" | head -8 | sed 's/^/    /'
                echo ""
            fi
            
            if [ $retry_count -lt $max_retries ]; then
                echo -e "${YELLOW}剩余 $((max_retries - retry_count)) 次机会${NC}"
                echo ""
                
                # 提供修复建议
                if echo "$filtered_result" | grep -qi "Unknown model"; then
                    echo -e "${YELLOW}提示: 模型不被识别，建议运行: openclaw configure --section model${NC}"
                elif echo "$filtered_result" | grep -qi "401\|Incorrect API key\|authentication"; then
                    echo -e "${YELLOW}提示: API Key 可能不正确${NC}"
                elif echo "$filtered_result" | grep -qi "只有系统日志"; then
                    echo -e "${YELLOW}提示: API 可能没有正确响应，请检查 API 地址和模型名称${NC}"
                fi
                echo ""
                
                if confirm "是否重新配置 AI Provider？" "y"; then
                    setup_ai_provider
                    configure_openclaw_model
                else
                    echo -e "${YELLOW}继续使用当前配置...${NC}"
                    test_passed=true  # 允许跳过
                fi
            fi
        fi
    done
    
    if [ "$test_passed" = false ]; then
        echo -e "${RED}API 连接测试失败${NC}"
        echo ""
        echo "建议运行以下命令手动配置:"
        echo "  openclaw configure --section model"
        echo "  openclaw doctor"
        echo ""
        if confirm "是否仍然继续安装？" "y"; then
            log_warn "跳过连接测试，继续安装..."
            return 0
        else
            echo "安装已取消"
            exit 1
        fi
    fi
    
    return 0
}

# ================================ 身份配置 ================================

setup_identity() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}  第 3 步: 设置身份信息${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    read_value_allow_empty "${YELLOW}给你的 AI 助手起个名字 (默认: Clawd): ${NC}" BOT_NAME
    BOT_NAME=${BOT_NAME:-"Clawd"}
    
    read_value_allow_empty "${YELLOW}AI 如何称呼你 (默认: 主人): ${NC}" USER_NAME
    USER_NAME=${USER_NAME:-"主人"}
    
    read_value_allow_empty "${YELLOW}你的时区 (默认: Asia/Shanghai): ${NC}" TIMEZONE
    TIMEZONE=${TIMEZONE:-"Asia/Shanghai"}
    
    echo ""
    log_info "身份配置完成"
    echo -e "  助手名称: ${WHITE}$BOT_NAME${NC}"
    echo -e "  你的称呼: ${WHITE}$USER_NAME${NC}"
    echo -e "  时区: ${WHITE}$TIMEZONE${NC}"
    
    # 初始化渠道配置变量
    TELEGRAM_ENABLED="false"
    DISCORD_ENABLED="false"
    SHELL_ENABLED="false"
    FILE_ACCESS="false"
}


# ================================ 服务管理 ================================

setup_daemon() {
    if confirm "是否设置开机自启动？" "y"; then
        log_step "配置系统服务..."
        
        case "$OS" in
            macos)
                setup_launchd
                ;;
            *)
                setup_systemd
                ;;
        esac
    fi
}

setup_systemd() {
    cat > /tmp/openclaw.service << EOF
[Unit]
Description=OpenClaw AI Assistant
After=network.target

[Service]
Type=simple
User=$USER
ExecStart=$(which openclaw) start --daemon
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    sudo mv /tmp/openclaw.service /etc/systemd/system/
    sudo systemctl daemon-reload
    sudo systemctl enable openclaw
    
    log_info "Systemd 服务已配置"
}

setup_launchd() {
    mkdir -p "$HOME/Library/LaunchAgents"
    
    cat > "$HOME/Library/LaunchAgents/com.openclaw.agent.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.openclaw.agent</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(which openclaw)</string>
        <string>start</string>
        <string>--daemon</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$CONFIG_DIR/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>$CONFIG_DIR/stderr.log</string>
</dict>
</plist>
EOF

    launchctl load "$HOME/Library/LaunchAgents/com.openclaw.agent.plist" 2>/dev/null || true
    
    log_info "LaunchAgent 已配置"
}

# ================================ 完成安装 ================================

print_success() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}                    🎉 安装完成！🎉${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${WHITE}配置目录:${NC}"
    echo "  OpenClaw 配置: ~/.openclaw/"
    echo "  环境变量配置: ~/.openclaw/env"
    echo ""
    echo -e "${CYAN}常用命令:${NC}"
    echo "  openclaw gateway start   # 后台启动服务"
    echo "  openclaw gateway stop    # 停止服务"
    echo "  openclaw gateway status  # 查看状态"
    echo "  openclaw models status   # 查看模型配置"
    echo "  openclaw channels list   # 查看渠道列表"
    echo "  openclaw doctor          # 诊断问题"
    echo ""
    echo -e "${PURPLE}📚 官方文档: https://clawd.bot/docs${NC}"
    echo -e "${PURPLE}💬 社区支持: https://github.com/$GITHUB_REPO/discussions${NC}"
    echo ""
}

# 启动 OpenClaw Gateway 服务
start_openclaw_service() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}           🚀 启动 OpenClaw 服务${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    # 加载环境变量
    local env_file="$HOME/.openclaw/env"
    if [ -f "$env_file" ]; then
        source "$env_file"
        log_info "已加载环境变量"
    fi
    
    # 使用端口检测判断是否已有服务在运行（更可靠）
    local existing_pid=$(lsof -ti :18789 2>/dev/null | head -1)
    if [ -n "$existing_pid" ]; then
        log_warn "OpenClaw Gateway 已在运行 (PID: $existing_pid)"
        echo ""
        if confirm "是否重启服务？" "y"; then
            openclaw gateway stop 2>/dev/null || true
            sleep 2
        else
            return 0
        fi
    fi
    
    # 后台启动 Gateway（使用 setsid 完全脱离终端）
    log_step "正在后台启动 Gateway..."
    
    if command -v setsid &> /dev/null; then
        if [ -f "$env_file" ]; then
            setsid bash -c "source $env_file && exec openclaw gateway --port 18789" > /tmp/openclaw-gateway.log 2>&1 &
        else
            setsid openclaw gateway --port 18789 > /tmp/openclaw-gateway.log 2>&1 &
        fi
    else
        # 备用方案：nohup + disown
        if [ -f "$env_file" ]; then
            nohup bash -c "source $env_file && exec openclaw gateway --port 18789" > /tmp/openclaw-gateway.log 2>&1 &
        else
            nohup openclaw gateway --port 18789 > /tmp/openclaw-gateway.log 2>&1 &
        fi
        disown 2>/dev/null || true
    fi
    
    # 等待服务启动
    sleep 3
    
    # 使用端口检测判断服务是否启动成功（更可靠）
    local gateway_pid=$(lsof -ti :18789 2>/dev/null | head -1)
    if [ -n "$gateway_pid" ]; then
        echo ""
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}           ✓ OpenClaw Gateway 已启动！(PID: $gateway_pid)${NC}"
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "  ${CYAN}查看状态:${NC} openclaw gateway status"
        echo -e "  ${CYAN}查看日志:${NC} tail -f /tmp/openclaw-gateway.log"
        echo -e "  ${CYAN}停止服务:${NC} openclaw gateway stop"
        echo ""
        log_info "OpenClaw 现在可以接收消息了！"
    else
        log_error "Gateway 启动失败"
        echo ""
        echo -e "${YELLOW}请查看日志: tail -f /tmp/openclaw-gateway.log${NC}"
        echo -e "${YELLOW}或手动启动: source ~/.openclaw/env && openclaw gateway${NC}"
    fi
}

# 下载并运行配置菜单
run_config_menu() {
    local config_menu_path="$CONFIG_MENU_PATH"
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local local_config_menu="$script_dir/config-menu.sh"
    local menu_script=""
    
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}           🔧 启动配置菜单${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    # 检查本地是否已有配置菜单
    local has_local_menu=false
    if [ -f "$local_config_menu" ]; then
        has_local_menu=true
        menu_script="$local_config_menu"
    elif [ -f "$config_menu_path" ]; then
        has_local_menu=true
        menu_script="$config_menu_path"
    fi
    
    # 如果本地已有配置菜单，询问是否更新
    if [ "$has_local_menu" = true ]; then
        log_info "检测到本地配置菜单: $menu_script"
        echo ""

        if [ "$RUN_FROM_PIPE" = "true" ]; then
            log_step "检测到通过 curl | bash 运行，自动下载最新配置菜单..."
            if download_latest_config_menu "$config_menu_path"; then
                log_info "配置菜单已更新: $config_menu_path"
                menu_script="$config_menu_path"
            else
                log_warn "下载失败或超时，继续使用本地版本"
            fi
        elif confirm "是否从 GitHub 更新到最新版本？" "n"; then
            log_step "从 GitHub 下载最新配置菜单..."
            if download_latest_config_menu "$config_menu_path"; then
                log_info "配置菜单已更新: $config_menu_path"
                menu_script="$config_menu_path"
            else
                log_warn "下载失败或超时，继续使用本地版本"
            fi
        else
            log_info "使用本地配置菜单"
        fi
    else
        # 本地没有配置菜单，从 GitHub 下载
        log_step "从 GitHub 下载配置菜单..."
        if download_latest_config_menu "$config_menu_path"; then
            log_info "配置菜单已下载: $config_menu_path"
            menu_script="$config_menu_path"
        else
            log_error "配置菜单下载失败或超时"
            echo -e "${YELLOW}你可以稍后手动下载运行:${NC}"
            echo "  curl -fsSL $GITHUB_RAW_URL/config-menu.sh -o $CONFIG_MENU_PATH && bash $CONFIG_MENU_PATH"
            return 1
        fi
    fi
    
    # 确保有执行权限
    chmod +x "$menu_script" 2>/dev/null || true
    
    # 启动配置菜单（使用 /dev/tty 确保交互正常）
    echo ""
    if [ -e /dev/tty ]; then
        bash "$menu_script" < /dev/tty
    else
        bash "$menu_script"
    fi
    return $?
}

run_tuzi_only_setup() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}        🔌 已安装 OpenClaw，快速接入 Tuzi API${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    if ! check_command openclaw; then
        log_error "未检测到 openclaw 命令"
        echo ""
        echo -e "${YELLOW}该模式仅适用于已安装 OpenClaw 的用户。${NC}"
        echo -e "${YELLOW}请改用完整安装模式，或先自行安装 OpenClaw 后再运行:${NC}"
        echo "  bash install.sh --full-install"
        exit 1
    fi

    log_info "检测到 OpenClaw: $(openclaw --version 2>/dev/null || echo 'installed')"
    create_directories
    init_openclaw_config

    echo ""
    echo -e "${GRAY}本模式会跳过依赖安装、OpenClaw 安装、身份配置和开机自启动。${NC}"
    echo -e "${GRAY}只会写入 ~/.openclaw/env 与 ~/.openclaw/openclaw.json 的 Tuzi 配置。${NC}"
    echo ""

    local should_update_config=true
    if is_tuzi_configured; then
        log_info "检测到当前环境已经存在 Tuzi 配置"
        echo ""
        show_current_tuzi_config
        echo ""
        if ! confirm "是否修改当前 Tuzi 配置？" "n"; then
            should_update_config=false
            log_info "保留现有 Tuzi 配置"
        fi
    fi

    if [ "$should_update_config" = true ]; then
        setup_ai_provider
        configure_openclaw_model
        test_api_connection

        echo ""
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}          ✓ Tuzi API 已接入到现有 OpenClaw${NC}"
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    else
        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${WHITE}          当前 Tuzi 配置保持不变${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    fi

    echo ""
    echo -e "${CYAN}后续可用命令:${NC}"
    echo "  openclaw models status"
    echo "  source ~/.openclaw/env && openclaw gateway"
    echo "  bash ~/.openclaw/config-menu.sh"
    echo ""

    if confirm "是否现在启动或重启 OpenClaw 服务？" "y"; then
        start_openclaw_service
    fi

    echo ""
    echo -e "${WHITE}如需继续配置消息渠道，可运行:${NC}"
    echo "  bash ~/.openclaw/config-menu.sh"
    echo "  或 curl -fsSL $GITHUB_RAW_URL/config-menu.sh -o ~/.openclaw/config-menu.sh && bash ~/.openclaw/config-menu.sh"
    echo ""
}

# ================================ 主函数 ================================

main() {
    parse_args "$@"
    print_banner
    
    echo -e "${YELLOW}⚠️  警告: OpenClaw 需要完全的计算机权限${NC}"
    echo -e "${YELLOW}    不建议在主要工作电脑上安装，建议使用专用服务器或虚拟机${NC}"
    echo ""
    
    if ! confirm "是否继续安装？"; then
        echo "安装已取消"
        exit 0
    fi
    
    echo ""
    detect_install_mode

    if [ "$INSTALL_MODE" = "tuzi-only" ]; then
        log_info "检测到已有可复用的 OpenClaw，跳过安装步骤，进入现有配置检查"
        detect_os
        check_root
        run_tuzi_only_setup
        echo -e "${GREEN}🦞 Tuzi API 配置完成！祝你使用愉快！${NC}"
        echo ""
        exit 0
    fi

    detect_os
    check_root
    log_info "未检测到可复用的 OpenClaw 安装，开始完整安装流程"
    install_dependencies
    create_directories
    install_openclaw
    run_onboard_wizard
    setup_daemon
    print_success
    
    # 询问是否启动服务
    if confirm "是否现在启动 OpenClaw 服务？" "y"; then
        start_openclaw_service
    else
        echo ""
        echo -e "${CYAN}稍后可以通过以下命令启动服务:${NC}"
        echo "  source ~/.openclaw/env && openclaw gateway"
        echo ""
    fi
    
    # 推荐桌面版
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}           🖥️ 推荐：OpenClaw Manager 桌面版${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${WHITE}如果你更喜欢图形界面，推荐下载 OpenClaw Manager 桌面应用：${NC}"
    echo ""
    echo -e "  🎨 ${CYAN}现代化 UI${NC} - 基于 Tauri 2.0 + React + Rust 构建"
    echo -e "  📊 ${CYAN}实时监控${NC} - 仪表盘查看服务状态、内存、运行时间"
    echo -e "  🔧 ${CYAN}可视化配置${NC} - AI 模型、消息渠道一键配置"
    echo -e "  💻 ${CYAN}跨平台${NC} - 支持 macOS、Windows、Linux"
    echo ""
    echo -e "  👉 ${PURPLE}下载地址: https://github.com/miaoxworld/openclaw-manager${NC}"
    echo ""
    
    # 询问是否打开配置菜单进行详细配置
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}           📝 配置菜单（命令行版）${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${GRAY}配置菜单支持: 渠道配置、身份设置、安全配置、服务管理等${NC}"
    echo ""
    local config_menu_ready=false
    if ensure_config_menu_available; then
        config_menu_ready=true
        echo -e "${WHITE}💡 下次可以直接运行配置菜单:${NC}"
        echo -e "   ${CYAN}bash ~/.openclaw/config-menu.sh${NC}"
    else
        echo -e "${YELLOW}配置菜单未能自动保存到本地。${NC}"
        echo -e "${WHITE}稍后可以通过以下命令下载并运行:${NC}"
        echo -e "   ${CYAN}curl -fsSL $GITHUB_RAW_URL/config-menu.sh -o ~/.openclaw/config-menu.sh && bash ~/.openclaw/config-menu.sh${NC}"
    fi
    echo ""
    if confirm "是否现在打开配置菜单？" "n"; then
        run_config_menu
    else
        echo ""
        echo -e "${CYAN}稍后可以通过以下命令打开配置菜单:${NC}"
        if [ "$config_menu_ready" = true ]; then
            echo "  bash ~/.openclaw/config-menu.sh"
        else
            echo "  curl -fsSL $GITHUB_RAW_URL/config-menu.sh -o ~/.openclaw/config-menu.sh && bash ~/.openclaw/config-menu.sh"
        fi
        echo ""
    fi
    
    echo ""
    echo -e "${GREEN}🦞 OpenClaw 安装完成！祝你使用愉快！${NC}"
    echo ""
}

# 执行主函数
main "$@"
