#!/bin/bash

# 便携式代理检测脚本
# 模拟libproxy的proxy命令功能

function detect_proxy() {
    local url="$1"

    # 检查HTTP_PROXY和HTTPS_PROXY环境变量
    if [[ -n "$HTTP_PROXY" ]]; then
        echo "$HTTP_PROXY"
        return 0
    fi

    if [[ -n "$HTTPS_PROXY" ]]; then
        echo "$HTTPS_PROXY"
        return 0
    fi

    if [[ -n "$http_proxy" ]]; then
        echo "$http_proxy"
        return 0
    fi

    if [[ -n "$https_proxy" ]]; then
        echo "$https_proxy"
        return 0
    fi

    # 检查常见代理端口
    local common_ports=(8080 3128 8118 1080 8888)
    for port in "${common_ports[@]}"; do
        if netstat -ln 2>/dev/null | grep -q ":$port.*LISTEN" || \
           ss -ln 2>/dev/null | grep -q ":$port.*LISTEN"; then
            echo "http://127.0.0.1:$port"
            return 0
        fi
    done

    # 检查系统代理配置文件
    if [[ -f ~/.config/proxy/config ]]; then
        local proxy_config=$(grep -E "^proxy=" ~/.config/proxy/config | cut -d'=' -f2)
        if [[ -n "$proxy_config" ]]; then
            echo "$proxy_config"
            return 0
        fi
    fi

    # 检查PAC文件
    if [[ -f ~/.config/proxy/proxy.pac ]]; then
        # 简单解析PAC文件 - 这里只是示例
        local pac_proxy=$(grep -o "PROXY [^;]*" ~/.config/proxy/proxy.pac | head -1 | sed 's/PROXY /http:\/\//')
        if [[ -n "$pac_proxy" ]]; then
            echo "$pac_proxy"
            return 0
        fi
    fi

    # 如果没有找到代理配置，返回直连
    echo "direct://"
    return 0
}

# 主程序逻辑
if [[ $# -gt 0 ]]; then
    # 如果有命令行参数，处理每个URL
    for url in "$@"; do
        detect_proxy "$url"
    done
else
    # 从stdin读取URL
    while IFS= read -r url; do
        if [[ -n "$url" ]]; then
            detect_proxy "$url"
        fi
    done
fi