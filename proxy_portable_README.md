# 便携式代理检测脚本

这个脚本模拟了 libproxy 的 `proxy` 命令功能，可以在没有安装 libproxy 的系统上使用。

## 功能

脚本会按以下顺序检测代理配置：

1. 环境变量：`HTTP_PROXY`, `HTTPS_PROXY`, `http_proxy`, `https_proxy`
2. 检测常见代理端口（8080, 3128, 8118, 1080, 8888）是否有监听服务
3. 读取用户配置文件：`~/.config/proxy/config`
4. 解析 PAC 文件：`~/.config/proxy/proxy.pac`
5. 如果都没有找到，返回 `direct://`

## 使用方法

### 从标准输入读取 URL：
```bash
echo "http://www.google.com" | ./proxy_portable.sh
```

### 作为命令行参数：
```bash
./proxy_portable.sh http://www.google.com http://www.baidu.com
```

## 安装

1. 复制 `proxy_portable.sh` 到目标系统
2. 给脚本添加执行权限：`chmod +x proxy_portable.sh`
3. 可选：将脚本移动到 `/usr/local/bin/proxy` 以替代原始命令

## 配置

### 环境变量
设置代理环境变量：
```bash
export HTTP_PROXY=http://proxy.company.com:8080
export HTTPS_PROXY=http://proxy.company.com:8080
```

### 配置文件
创建 `~/.config/proxy/config`：
```
proxy=http://proxy.company.com:8080
```

### PAC 文件
创建 `~/.config/proxy/proxy.pac`：
```javascript
function FindProxyForURL(url, host) {
    return "PROXY proxy.company.com:8080";
}
```

## 依赖

- bash
- 基本的 Unix 工具（netstat 或 ss）

## 限制

- PAC 文件解析功能有限，只支持简单的 PROXY 指令
- 不支持复杂的代理规则和条件判断
- 不支持 WPAD 自动发现

## 原始 proxy 命令

原始的 `proxy` 命令来自 libproxy 包，是一个功能更强大的代理配置检测工具，支持：
- 自动代理配置 (PAC)
- WPAD 协议
- 各种桌面环境的代理设置
- 复杂的代理规则