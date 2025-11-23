#!/bin/bash

# Linux 系统代理管理脚本
# 支持订阅链接导入和全局系统代理

set -e

# 配置文件路径
CONFIG_DIR="$HOME/.config/proxy-manager"
CONFIG_FILE="$CONFIG_DIR/config.json"
BACKUP_FILE="$CONFIG_DIR/env_backup"
PID_FILE="$CONFIG_DIR/proxy.pid"
LOG_FILE="$CONFIG_DIR/proxy.log"
NODE_FILE="$CONFIG_DIR/current_node.json"
CLASH_CONFIG="$CONFIG_DIR/clash.yaml"
V2RAY_CONFIG="$CONFIG_DIR/v2ray.json"

# 默认端口
SOCKS_PORT=1080
HTTP_PORT=8118

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 创建配置目录
mkdir -p "$CONFIG_DIR"

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# 打印带颜色的消息
print_msg() {
    echo -e "${2}${1}${NC}"
}

# 检查依赖
check_dependencies() {
    local deps=("curl" "jq" "base64")
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        print_msg "缺少以下依赖：${missing_deps[*]}" "$RED"
        print_msg "请安装：sudo apt-get install ${missing_deps[*]} 或 sudo yum install ${missing_deps[*]}" "$YELLOW"
        exit 1
    fi
}

# 检查可用的代理客户端
check_proxy_clients() {
    local available_clients=""
    
    if command -v xray &> /dev/null; then
        available_clients="$available_clients xray"
    fi
    
    if command -v v2ray &> /dev/null; then
        available_clients="$available_clients v2ray"
    fi
    
    if command -v clash &> /dev/null; then
        available_clients="$available_clients clash"
    fi
    
    if command -v hysteria &> /dev/null; then
        available_clients="$available_clients hysteria"
    fi
    
    if command -v trojan-go &> /dev/null; then
        available_clients="$available_clients trojan-go"
    fi
    
    if command -v ss-local &> /dev/null; then
        available_clients="$available_clients shadowsocks"
    fi
    
    echo "$available_clients"
}

# 解析trojan URL
parse_trojan_url() {
    local url="$1"
    # 移除 trojan:// 前缀
    url="${url#trojan://}"
    
    # 分离密码和服务器部分
    local password="${url%%@*}"
    local server_part="${url#*@}"
    
    # 分离服务器、端口和参数
    local server="${server_part%%:*}"
    local remaining="${server_part#*:}"
    local port="${remaining%%\?*}"
    local params="${remaining#*\?}"
    
    # 解析参数
    local sni=""
    local alpn=""
    local allowInsecure="false"
    
    if [[ "$params" == *"sni="* ]]; then
        sni="${params#*sni=}"
        sni="${sni%%&*}"
    fi
    
    if [[ "$params" == *"alpn="* ]]; then
        alpn="${params#*alpn=}"
        alpn="${alpn%%&*}"
    fi
    
    if [[ "$params" == *"allowInsecure=1"* ]]; then
        allowInsecure="true"
    fi
    
    # 创建配置JSON
    cat > "$NODE_FILE" <<EOF
{
    "type": "trojan",
    "server": "$server",
    "port": $port,
    "password": "$password",
    "sni": "$sni",
    "alpn": "$alpn",
    "allowInsecure": $allowInsecure
}
EOF
}

# 解析vmess URL
parse_vmess_url() {
    local url="$1"
    # 移除 vmess:// 前缀并解码
    url="${url#vmess://}"
    local decoded
    decoded=$(echo "$url" | base64 -d 2>/dev/null || echo "{}")
    
    echo "$decoded" > "$NODE_FILE"
}

# 解析shadowsocks URL
parse_ss_url() {
    local url="$1"
    # ss://base64(method:password)@server:port
    url="${url#ss://}"
    
    local encoded_part="${url%%@*}"
    local server_part="${url#*@}"
    
    # 解码方法和密码
    local decoded
    decoded=$(echo "$encoded_part" | base64 -d 2>/dev/null || echo "")
    
    if [ -z "$decoded" ]; then
        # 某些SS链接可能不是base64编码的
        decoded="$encoded_part"
    fi
    
    local method="${decoded%%:*}"
    local password="${decoded#*:}"
    local server="${server_part%%:*}"
    local port="${server_part#*:}"
    port="${port%%#*}"  # 移除可能的标签
    
    cat > "$NODE_FILE" <<EOF
{
    "type": "shadowsocks",
    "server": "$server",
    "port": $port,
    "method": "$method",
    "password": "$password"
}
EOF
}

# 生成Xray/V2ray配置
generate_xray_config() {
    local node_info
    node_info=$(cat "$NODE_FILE")
    local node_type
    node_type=$(echo "$node_info" | jq -r '.type')
    
    case "$node_type" in
        trojan)
            local server port password sni
            server=$(echo "$node_info" | jq -r '.server')
            port=$(echo "$node_info" | jq -r '.port')
            password=$(echo "$node_info" | jq -r '.password')
            sni=$(echo "$node_info" | jq -r '.sni // empty')
            
            cat > "$V2RAY_CONFIG" <<EOF
{
  "inbounds": [
    {
      "port": $SOCKS_PORT,
      "protocol": "socks",
      "settings": {
        "auth": "noauth"
      }
    },
    {
      "port": $HTTP_PORT,
      "protocol": "http",
      "settings": {}
    }
  ],
  "outbounds": [
    {
      "protocol": "trojan",
      "settings": {
        "servers": [
          {
            "address": "$server",
            "port": $port,
            "password": "$password"
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "serverName": "$sni",
          "allowInsecure": true
        }
      }
    }
  ]
}
EOF
            ;;
            
        vmess)
            local v ps add port id aid net type host path tls
            v=$(echo "$node_info" | jq -r '.v // "2"')
            ps=$(echo "$node_info" | jq -r '.ps // ""')
            add=$(echo "$node_info" | jq -r '.add')
            port=$(echo "$node_info" | jq -r '.port')
            id=$(echo "$node_info" | jq -r '.id')
            aid=$(echo "$node_info" | jq -r '.aid // 0')
            net=$(echo "$node_info" | jq -r '.net // "tcp"')
            type=$(echo "$node_info" | jq -r '.type // "none"')
            host=$(echo "$node_info" | jq -r '.host // ""')
            path=$(echo "$node_info" | jq -r '.path // ""')
            tls=$(echo "$node_info" | jq -r '.tls // ""')
            
            cat > "$V2RAY_CONFIG" <<EOF
{
  "inbounds": [
    {
      "port": $SOCKS_PORT,
      "protocol": "socks",
      "settings": {
        "auth": "noauth"
      }
    },
    {
      "port": $HTTP_PORT,
      "protocol": "http",
      "settings": {}
    }
  ],
  "outbounds": [
    {
      "protocol": "vmess",
      "settings": {
        "vnext": [
          {
            "address": "$add",
            "port": $port,
            "users": [
              {
                "id": "$id",
                "alterId": $aid
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "$net",
        "security": "$tls",
        "wsSettings": {
          "path": "$path",
          "headers": {
            "Host": "$host"
          }
        }
      }
    }
  ]
}
EOF
            ;;
            
        shadowsocks)
            local server port method password
            server=$(echo "$node_info" | jq -r '.server')
            port=$(echo "$node_info" | jq -r '.port')
            method=$(echo "$node_info" | jq -r '.method')
            password=$(echo "$node_info" | jq -r '.password')
            
            cat > "$V2RAY_CONFIG" <<EOF
{
  "inbounds": [
    {
      "port": $SOCKS_PORT,
      "protocol": "socks",
      "settings": {
        "auth": "noauth"
      }
    },
    {
      "port": $HTTP_PORT,
      "protocol": "http",
      "settings": {}
    }
  ],
  "outbounds": [
    {
      "protocol": "shadowsocks",
      "settings": {
        "servers": [
          {
            "address": "$server",
            "port": $port,
            "method": "$method",
            "password": "$password"
          }
        ]
      }
    }
  ]
}
EOF
            ;;
    esac
}

# 解析订阅链接
parse_subscription() {
    local sub_url="$1"
    print_msg "正在获取订阅内容..." "$BLUE"
    
    # 下载订阅内容
    local sub_content
    sub_content=$(curl -sL "$sub_url" || {
        print_msg "下载订阅失败" "$RED"
        return 1
    })
    
    # 尝试base64解码（大多数订阅是base64编码的）
    local decoded_content
    if echo "$sub_content" | base64 -d &>/dev/null; then
        decoded_content=$(echo "$sub_content" | base64 -d)
    else
        decoded_content="$sub_content"
    fi
    
    # 解析代理节点（支持ss://、ssr://、vmess://等格式）
    local proxies=()
    while IFS= read -r line; do
        if [[ "$line" =~ ^(ss|ssr|vmess|vless|trojan|socks5|http|hysteria|hysteria2):// ]]; then
            proxies+=("$line")
        fi
    done <<< "$decoded_content"
    
    if [ ${#proxies[@]} -eq 0 ]; then
        print_msg "未找到有效的代理节点" "$RED"
        return 1
    fi
    
    print_msg "找到 ${#proxies[@]} 个代理节点" "$GREEN"
    
    # 保存配置
    jq -n --argjson proxies "$(printf '%s\n' "${proxies[@]}" | jq -R . | jq -s .)" \
        '{subscription: $ARGS.positional[0], proxies: $proxies, selected: 0}' \
        --args "$sub_url" > "$CONFIG_FILE"
    
    return 0
}

# 选择代理节点
select_proxy() {
    if [ ! -f "$CONFIG_FILE" ]; then
        print_msg "请先导入订阅链接" "$RED"
        return 1
    fi
    
    local proxies
    proxies=$(jq -r '.proxies[]' "$CONFIG_FILE")
    
    if [ -z "$proxies" ]; then
        print_msg "没有可用的代理节点" "$RED"
        return 1
    fi
    
    print_msg "可用的代理节点：" "$BLUE"
    local i=0
    while IFS= read -r proxy; do
        # 提取节点名称或简化显示
        local display_name=""
        if [[ "$proxy" =~ \#(.+)$ ]]; then
            display_name="${BASH_REMATCH[1]}"
            display_name=$(echo "$display_name" | sed 's/%20/ /g' | sed 's/%2C/,/g')
        else
            display_name="${proxy:0:50}..."
        fi
        printf "[%2d] %s\n" "$i" "$display_name"
        ((i++))
    done <<< "$proxies"
    
    read -p "请选择代理节点（输入编号）: " selection
    
    # 验证输入
    if ! [[ "$selection" =~ ^[0-9]+$ ]]; then
        print_msg "无效的选择" "$RED"
        return 1
    fi
    
    local proxy_count
    proxy_count=$(echo "$proxies" | wc -l)
    if [ "$selection" -ge "$proxy_count" ]; then
        print_msg "选择超出范围" "$RED"
        return 1
    fi
    
    # 更新选中的节点
    jq ".selected = $selection" "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    
    # 获取选中的代理URL
    local selected_proxy
    selected_proxy=$(jq -r ".proxies[$selection]" "$CONFIG_FILE")
    
    # 解析代理URL
    if [[ "$selected_proxy" =~ ^trojan:// ]]; then
        parse_trojan_url "$selected_proxy"
    elif [[ "$selected_proxy" =~ ^vmess:// ]]; then
        parse_vmess_url "$selected_proxy"
    elif [[ "$selected_proxy" =~ ^ss:// ]]; then
        parse_ss_url "$selected_proxy"
    fi
    
    print_msg "已选择节点 $selection" "$GREEN"
}

# 备份当前环境变量
backup_env() {
    {
        echo "HTTP_PROXY=${HTTP_PROXY:-}"
        echo "HTTPS_PROXY=${HTTPS_PROXY:-}"
        echo "http_proxy=${http_proxy:-}"
        echo "https_proxy=${https_proxy:-}"
        echo "ALL_PROXY=${ALL_PROXY:-}"
        echo "all_proxy=${all_proxy:-}"
        echo "NO_PROXY=${NO_PROXY:-}"
        echo "no_proxy=${no_proxy:-}"
    } > "$BACKUP_FILE"
    log "环境变量已备份"
}

# 恢复环境变量
restore_env() {
    if [ -f "$BACKUP_FILE" ]; then
        while IFS='=' read -r key value; do
            if [ -z "$value" ]; then
                unset "$key"
            else
                export "$key=$value"
            fi
        done < "$BACKUP_FILE"
        log "环境变量已恢复"
    fi
}

# 设置系统代理
set_system_proxy() {
    local proxy_addr="http://127.0.0.1:$HTTP_PORT"
    local socks_addr="socks5://127.0.0.1:$SOCKS_PORT"
    
    # 备份当前环境
    backup_env
    
    # 创建临时脚本来设置环境变量（用于当前shell）
    local temp_script="$CONFIG_DIR/set_proxy.sh"
    cat > "$temp_script" <<EOF
#!/bin/bash
# 设置代理环境变量
export HTTP_PROXY="$proxy_addr"
export HTTPS_PROXY="$proxy_addr"
export http_proxy="$proxy_addr"
export https_proxy="$proxy_addr"
export ALL_PROXY="$socks_addr"
export all_proxy="$socks_addr"
export NO_PROXY="localhost,127.0.0.1,::1,10.0.0.0/8,192.168.0.0/16"
export no_proxy="localhost,127.0.0.1,::1,10.0.0.0/8,192.168.0.0/16"
EOF
    
    # 写入到profile（永久生效）
    local profile_file="$HOME/.proxy_env"
    {
        echo "# Proxy settings - Generated by proxy-manager"
        echo "export HTTP_PROXY=\"$proxy_addr\""
        echo "export HTTPS_PROXY=\"$proxy_addr\""
        echo "export http_proxy=\"$proxy_addr\""
        echo "export https_proxy=\"$proxy_addr\""
        echo "export ALL_PROXY=\"$socks_addr\""
        echo "export all_proxy=\"$socks_addr\""
        echo "export NO_PROXY=\"localhost,127.0.0.1,::1,10.0.0.0/8,192.168.0.0/16\""
        echo "export no_proxy=\"localhost,127.0.0.1,::1,10.0.0.0/8,192.168.0.0/16\""
    } > "$profile_file"
    
    # 添加到bashrc/zshrc
    for rc_file in "$HOME/.bashrc" "$HOME/.zshrc"; do
        if [ -f "$rc_file" ]; then
            # 移除旧的代理设置
            sed -i '/# proxy-manager-start/,/# proxy-manager-end/d' "$rc_file"
            # 添加新的代理设置
            {
                echo "# proxy-manager-start"
                echo "[ -f \"$profile_file\" ] && source \"$profile_file\""
                echo "# proxy-manager-end"
            } >> "$rc_file"
        fi
    done
    
    # 设置GNOME/KDE桌面环境代理（如果存在）
    if command -v gsettings &> /dev/null; then
        gsettings set org.gnome.system.proxy mode 'manual'
        gsettings set org.gnome.system.proxy.http host '127.0.0.1'
        gsettings set org.gnome.system.proxy.http port "$HTTP_PORT"
        gsettings set org.gnome.system.proxy.https host '127.0.0.1'
        gsettings set org.gnome.system.proxy.https port "$HTTP_PORT"
        gsettings set org.gnome.system.proxy.socks host '127.0.0.1'
        gsettings set org.gnome.system.proxy.socks port "$SOCKS_PORT"
        gsettings set org.gnome.system.proxy ignore-hosts "['localhost', '127.0.0.0/8', '10.0.0.0/8', '192.168.0.0/16', '::1']"
    fi
    
    # 设置APT代理（如果是Debian/Ubuntu）
    if [ -f /etc/apt/apt.conf ]; then
        sudo tee /etc/apt/apt.conf.d/95proxy > /dev/null <<EOF
Acquire::http::Proxy "$proxy_addr";
Acquire::https::Proxy "$proxy_addr";
EOF
    fi
    
    log "系统代理已设置"
    print_msg "系统代理已设置" "$GREEN"
    print_msg "HTTP代理: $proxy_addr" "$BLUE"
    print_msg "SOCKS5代理: $socks_addr" "$BLUE"
    print_msg "" "$NC"
    print_msg "要在当前终端立即启用代理，请执行：" "$YELLOW"
    print_msg "source $temp_script" "$GREEN"
}

# 清除系统代理
unset_system_proxy() {
    # 创建临时脚本来清除环境变量（用于当前shell）
    local temp_script="$CONFIG_DIR/unset_proxy.sh"
    cat > "$temp_script" <<EOF
#!/bin/bash
# 清除代理环境变量
unset HTTP_PROXY
unset HTTPS_PROXY
unset http_proxy
unset https_proxy
unset ALL_PROXY
unset all_proxy
unset NO_PROXY
unset no_proxy
EOF
    
    # 恢复备份的环境变量（如果有）
    if [ -f "$BACKUP_FILE" ]; then
        echo "# 恢复原始环境变量" >> "$temp_script"
        while IFS='=' read -r key value; do
            if [ -n "$value" ]; then
                echo "export $key=\"$value\"" >> "$temp_script"
            fi
        done < "$BACKUP_FILE"
    fi
    
    # 移除profile文件
    rm -f "$HOME/.proxy_env"
    
    # 从bashrc/zshrc中移除
    for rc_file in "$HOME/.bashrc" "$HOME/.zshrc"; do
        if [ -f "$rc_file" ]; then
            sed -i '/# proxy-manager-start/,/# proxy-manager-end/d' "$rc_file"
        fi
    done
    
    # 清除GNOME/KDE代理设置
    if command -v gsettings &> /dev/null; then
        gsettings set org.gnome.system.proxy mode 'none'
    fi
    
    # 清除APT代理
    if [ -f /etc/apt/apt.conf.d/95proxy ]; then
        sudo rm -f /etc/apt/apt.conf.d/95proxy
    fi
    
    log "系统代理已清除"
    print_msg "系统代理已清除，环境已恢复" "$GREEN"
    print_msg "" "$NC"
    print_msg "要在当前终端立即清除代理，请执行：" "$YELLOW"
    print_msg "source $temp_script" "$GREEN"
}

# 启动本地代理服务
start_proxy_service() {
    if [ -f "$PID_FILE" ]; then
        local old_pid
        old_pid=$(cat "$PID_FILE")
        if kill -0 "$old_pid" 2>/dev/null; then
            print_msg "代理服务已在运行 (PID: $old_pid)" "$YELLOW"
            return 0
        fi
    fi
    
    # 检查是否已选择节点
    if [ ! -f "$NODE_FILE" ]; then
        if [ ! -f "$CONFIG_FILE" ]; then
            print_msg "请先导入订阅链接" "$RED"
            return 1
        fi
        
        # 自动选择第一个节点
        print_msg "自动选择第一个节点..." "$YELLOW"
        local first_proxy
        first_proxy=$(jq -r '.proxies[0]' "$CONFIG_FILE")
        
        if [[ "$first_proxy" =~ ^trojan:// ]]; then
            parse_trojan_url "$first_proxy"
        elif [[ "$first_proxy" =~ ^vmess:// ]]; then
            parse_vmess_url "$first_proxy"
        elif [[ "$first_proxy" =~ ^ss:// ]]; then
            parse_ss_url "$first_proxy"
        fi
    fi
    
    # 生成配置文件
    generate_xray_config
    
    # 检查可用的客户端
    local clients
    clients=$(check_proxy_clients)
    
    if [ -z "$clients" ]; then
        print_msg "未找到代理客户端，正在尝试安装..." "$YELLOW"
        install_xray
        return $?
    fi
    
    # 启动代理客户端
    local started=false
    
    # 优先使用xray
    if command -v xray &> /dev/null; then
        print_msg "使用 Xray 启动代理..." "$BLUE"
        nohup xray run -c "$V2RAY_CONFIG" > "$LOG_FILE" 2>&1 &
        echo $! > "$PID_FILE"
        started=true
    elif command -v v2ray &> /dev/null; then
        print_msg "使用 V2Ray 启动代理..." "$BLUE"
        nohup v2ray run -c "$V2RAY_CONFIG" > "$LOG_FILE" 2>&1 &
        echo $! > "$PID_FILE"
        started=true
    fi
    
    if [ "$started" = true ]; then
        sleep 2
        if kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
            print_msg "代理服务启动成功" "$GREEN"
            log "代理服务已启动"
            return 0
        else
            print_msg "代理服务启动失败，请查看日志: $LOG_FILE" "$RED"
            rm -f "$PID_FILE"
            return 1
        fi
    else
        print_msg "没有可用的代理客户端" "$RED"
        print_msg "请安装 xray 或 v2ray" "$YELLOW"
        return 1
    fi
}

# 安装xray（可选功能）
install_xray() {
    print_msg "正在安装 Xray..." "$BLUE"
    
    # 检测系统架构
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64) arch="64" ;;
        aarch64) arch="arm64-v8a" ;;
        armv7l) arch="arm32-v7a" ;;
        *) 
            print_msg "不支持的架构: $arch" "$RED"
            return 1
            ;;
    esac
    
    # 下载安装脚本
    if curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh | sudo bash; then
        print_msg "Xray 安装成功" "$GREEN"
        
        # 重新启动代理服务
        start_proxy_service
    else
        print_msg "Xray 安装失败" "$RED"
        print_msg "请手动安装代理客户端" "$YELLOW"
        return 1
    fi
}

# 停止代理服务
stop_proxy_service() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
            sleep 1
            # 强制停止
            if kill -0 "$pid" 2>/dev/null; then
                kill -9 "$pid" 2>/dev/null
            fi
            print_msg "代理服务已停止" "$GREEN"
        fi
        rm -f "$PID_FILE"
    fi
    
    # 停止所有可能的代理进程
    pkill -f "xray.*$V2RAY_CONFIG" 2>/dev/null
    pkill -f "v2ray.*$V2RAY_CONFIG" 2>/dev/null
    
    log "代理服务已停止"
}

# 检查代理状态
check_status() {
    print_msg "=== 代理状态 ===" "$BLUE"
    
    # 检查服务状态
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            print_msg "代理服务: 运行中 (PID: $pid)" "$GREEN"
        else
            print_msg "代理服务: 已停止" "$RED"
        fi
    else
        print_msg "代理服务: 未启动" "$YELLOW"
    fi
    
    # 显示当前节点
    if [ -f "$NODE_FILE" ]; then
        local node_type server
        node_type=$(jq -r '.type' "$NODE_FILE" 2>/dev/null || echo "unknown")
        server=$(jq -r '.server' "$NODE_FILE" 2>/dev/null || echo "unknown")
        print_msg "当前节点: $node_type://$server" "$BLUE"
    fi
    
    # 检查环境变量
    if [ -n "${HTTP_PROXY:-}" ] || [ -n "${http_proxy:-}" ]; then
        print_msg "系统代理: 已设置" "$GREEN"
        [ -n "${HTTP_PROXY:-}" ] && echo "  HTTP_PROXY=$HTTP_PROXY"
        [ -n "${HTTPS_PROXY:-}" ] && echo "  HTTPS_PROXY=$HTTPS_PROXY"
        [ -n "${ALL_PROXY:-}" ] && echo "  ALL_PROXY=$ALL_PROXY"
    else
        print_msg "系统代理: 未设置" "$YELLOW"
    fi
    
    # 测试连接
    print_msg "\n测试代理连接..." "$BLUE"
    
    # 测试SOCKS5
    if timeout 5 curl -sS --socks5 "127.0.0.1:$SOCKS_PORT" http://www.google.com -o /dev/null 2>/dev/null; then
        print_msg "SOCKS5代理: 正常" "$GREEN"
    else
        print_msg "SOCKS5代理: 失败" "$RED"
    fi
    
    # 测试HTTP
    if timeout 5 curl -sS --proxy "http://127.0.0.1:$HTTP_PORT" http://www.google.com -o /dev/null 2>/dev/null; then
        print_msg "HTTP代理: 正常" "$GREEN"
    else
        print_msg "HTTP代理: 失败" "$RED"
    fi
    
    # 获取IP地址
    print_msg "\n检查IP地址..." "$BLUE"
    local current_ip
    current_ip=$(curl -sS --socks5 "127.0.0.1:$SOCKS_PORT" --connect-timeout 5 https://api.ipify.org 2>/dev/null)
    if [ -n "$current_ip" ]; then
        print_msg "当前IP: $current_ip" "$GREEN"
    else
        print_msg "无法获取IP地址" "$RED"
    fi
}

# 更新订阅
update_subscription() {
    if [ ! -f "$CONFIG_FILE" ]; then
        print_msg "没有保存的订阅链接" "$RED"
        return 1
    fi
    
    local sub_url
    sub_url=$(jq -r '.subscription' "$CONFIG_FILE")
    
    if [ -z "$sub_url" ] || [ "$sub_url" = "null" ]; then
        print_msg "订阅链接无效" "$RED"
        return 1
    fi
    
    print_msg "正在更新订阅..." "$BLUE"
    parse_subscription "$sub_url"
}

# 添加快捷命令：设置当前终端代理
set_current_shell() {
    local script="$CONFIG_DIR/set_proxy.sh"
    if [ -f "$script" ]; then
        print_msg "正在为当前终端设置代理..." "$BLUE"
        source "$script"
        print_msg "当前终端代理已设置" "$GREEN"
    else
        print_msg "请先执行 start 命令启动代理" "$RED"
    fi
}

# 添加快捷命令：清除当前终端代理
unset_current_shell() {
    local script="$CONFIG_DIR/unset_proxy.sh"
    if [ -f "$script" ]; then
        print_msg "正在清除当前终端代理..." "$BLUE"
        source "$script"
        print_msg "当前终端代理已清除" "$GREEN"
    else
        # 直接清除
        unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy NO_PROXY no_proxy
        print_msg "当前终端代理已清除" "$GREEN"
    fi
}

# 显示帮助信息
show_help() {
    cat << EOF
Linux 系统代理管理脚本

使用方法:
  $0 [命令] [参数]

命令:
  import <订阅链接>   导入订阅链接
  update             更新订阅
  select             选择代理节点
  start              启动代理
  stop               停止代理
  restart            重启代理
  status             查看代理状态
  set                设置当前终端代理（快捷命令）
  unset              清除当前终端代理（快捷命令）
  install            安装代理客户端
  help               显示帮助信息

示例:
  $0 import https://example.com/subscription
  $0 select
  $0 start
  $0 set      # 立即在当前终端启用代理
  $0 status
  $0 unset    # 立即在当前终端清除代理
  $0 stop

配置文件位置: $CONFIG_DIR
日志文件: $LOG_FILE

支持的代理协议:
  - Trojan
  - VMess (V2Ray)
  - Shadowsocks
  - VLESS (需要手动配置)

注意:
  - 首次使用需要安装代理客户端（xray或v2ray）
  - 使用 'install' 命令可以自动安装xray
  - 代理端口: SOCKS5=$SOCKS_PORT, HTTP=$HTTP_PORT
  - start/stop 后使用 set/unset 可立即在当前终端生效
EOF
}

# 主函数
main() {
    check_dependencies
    
    case "${1:-}" in
        import)
            if [ -z "${2:-}" ]; then
                print_msg "请提供订阅链接" "$RED"
                exit 1
            fi
            parse_subscription "$2"
            ;;
        update)
            update_subscription
            ;;
        select)
            select_proxy
            ;;
        start)
            start_proxy_service
            if [ $? -eq 0 ]; then
                set_system_proxy
                print_msg "\n代理已启动" "$GREEN"
                print_msg "立即在当前终端启用代理：" "$YELLOW"
                print_msg "source ~/.config/proxy-manager/set_proxy.sh" "$GREEN"
                print_msg "\n或者新开终端窗口自动生效" "$BLUE"
            fi
            ;;
        stop)
            unset_system_proxy
            stop_proxy_service
            print_msg "\n代理已停止" "$GREEN"
            print_msg "立即在当前终端清除代理：" "$YELLOW"
            print_msg "source ~/.config/proxy-manager/unset_proxy.sh" "$GREEN"
            print_msg "\n或者新开终端窗口自动生效" "$BLUE"
            ;;
        restart)
            "$0" stop
            sleep 2
            "$0" start
            ;;
        status)
            check_status
            ;;
        set)
            set_current_shell
            ;;
        unset)
            unset_current_shell
            ;;
        install)
            install_xray
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            print_msg "未知命令: ${1:-}" "$RED"
            show_help
            exit 1
            ;;
    esac
}

# 执行主函数
main "$@"
