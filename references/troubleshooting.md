# 节点故障证据树

## 首次失败直接取证

记录一次请求的时间、目标、使用的客户端与服务端核心版本，同时读客户端握手日志和服务端日志。Shadowrocket 先用 `read-shadowrocket-diagnostics.py`，不要只读规则命中库。

- 本地 HTTP 代理 503：本次代理转发失败，不算目标站的有效响应。结合 `invalid backend status`、fallback 和 Reality 日志继续分层。
- 同参数下独立 Xray 通过、原生客户端失败：优先查跨实现握手兼容，读取 `reality-compatibility.md`；未证实运行快照旧时不重建隧道。
- 两次相同动作都失败且无新证据：停止该动作，选择能区分原因的一条日志或单变量对照，不重复保存、改名或扫描端口。

抓包必须在请求前开始并覆盖同一次窗口，过滤真实 IP/端口，确认监听接口和抓包进程有效。未满足这些条件时 `server-received=unknown`。有效诊断日志已经显示 TCP/ClientHello 时，不再以错位抓包的“无包”推翻它。

## 第一次分叉：服务端是否收到连接

### 没有收到 SYN/443 流量

只有同步抓包或同次诊断证明未收到连接，才查实例、公网 IP、云防火墙、本地路由、TUN 防回环和节点运行快照。无有效观测时先补观测，不改 Reality 参数。

### 收到 TCP 或 ClientHello

进入第二次分叉。不要再用 `nc` 可达性重复证明 TCP。

## 第二次分叉：Reality 是否认证

### Reality authentication/validation failed

检查有效配置哈希、时间、short ID、SNI、握手字段、客户端版本边界和 fallback。若独立 Xray 通过、原生客户端失败，先查 `key_share` 特性差异；放宽 `minClientVer` 不能修复缺失字段。读取 `reality-compatibility.md`。

### Reality 认证成功

进入 VLESS/XTLS 层，检查 UUID 哈希、Vision flow、TCP 和客户端序列化。

### 没有 Reality 日志

用 `run-debug-window.sh --redact-config <effective-config.json>` 创建服务器本地看门狗调试窗口。必须先确认正式服务能自动恢复，不能让 SSH 连接承担恢复责任；日志必须经过凭证脱敏。

## 第三次分叉：业务出口是否正确

### 节点成功，出口错误

只查规则顺序、代理组、配置选择和运行日志。

### 出口正确，特定服务失败

区分 DNS、目标服务 IP 信誉、账号风控、协议响应和线路质量；不要重新部署服务器。

### 下载成功但速度不可信

确认测速域名真实命中新节点。若被旧规则送到其他节点，整次结果无效。报告单连接/多连接、文件大小、测试点、时间、网络和 Mbps，不与峰值带宽直接等同。

## 证据表模板

首次失败即填已知事实。三个假设失败后停止修改，重新核对这张表；不要到此时才读取日志。

```text
当前正式状态：
服务器收到连接：unknown / none / tcp / clienthello
观测覆盖同次请求：yes / no
独立客户端：unknown / failed / passed
原生客户端：unknown / failed / passed
跨实现参数一致：yes / no / unknown
Reality：unknown / failed / passed
VLESS：unknown / failed / passed
出口：unknown / wrong / expected
当前有效配置已回读：yes / no
最近一次只改变的变量：
测试是否受污染：yes / no
已恢复并验证：yes / no
下一条唯一分支：
```

可将这些事实交给 `scripts/diagnose-node.sh` 生成下一步。用 `--observation-valid yes` 声明同步观测，跨实现对照用 `--isolated-client passed --native-client failed --same-parameters yes`。`none` 缺有效观测时会被拒绝；没有证据的字段必须填 `unknown`。
