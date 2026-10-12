# 搭建私人魔法节点 · by Nar

> 让 AI 带新手比较并购买海外服务器，直到自己的客户端真实可用。

这个 Skill 面向不懂服务器、但希望拥有个人独立出口的人。你说明预算、所在地区、设备和主要用途；AI 负责比较 VPS、核对费用、部署服务端、适配客户端、独立分流、真实验收、备份和跨设备交付。付款、实名、验证码、断流和关键安全动作始终由你确认。

**Created by [Nar / 那不然](https://github.com/Nar101)** · [v0.6.0 Release](https://github.com/Nar101/deploy-private-proxy-node/releases/tag/v0.6.0)

本项目只处理个人或极少数受信任设备的合法使用，不搭机场、不售卖、不开放注册或公网订阅。

## v0.6.0 解决了什么

旧流程容易停在“服务器安装成功”，但用户的 Shadowrocket 或其他客户端仍不可用。v0.6.0 把购买后的交付重构为七个证据门：

```text
G0 采购确认
→ G1 实例与 SSH 就绪
→ G2 服务端基线
→ G3 Reality 公网协议
→ G4 原生客户端
→ G5 独立分流与真实业务
→ G6 备份与跨设备交付
```

前一门没有证据，不进入后一门，也不提前报告完成。

本版重点加入：

- Reality 客户端版本边界预检；
- Shadowrocket UI、节点、规则、隧道四层真相；
- 新服务器 IP 的 TUN 防回环检查；
- 不切换全局节点的独立测试组；
- 以“服务器是否收到连接、Reality 是否认证”为主干的故障树；
- 服务器本地看门狗保护的调试窗口；
- 出口、目标服务、下载与路由证据的结构化验收；
- 不含 SSH 私钥的跨设备文件包。

## 30 秒开始

```bash
npx skills add Nar101/deploy-private-proxy-node
```

安装后可以说：

```text
使用 deploy-private-proxy-node，按交付门带我比较并购买海外 VPS，
部署私人节点，完成原生客户端、独立分流、真实出口、目标服务、
备份和跨设备文件交付；所有付费、断流和关键安全动作都先等我确认。
```

## 工作模式

| 模式 | 适用场景 |
| --- | --- |
| `new-deploy` | VPS 比较、购买到完整交付 |
| `clone` | 在新 VPS 复制已验证架构并重建凭证 |
| `diagnose` | 节点超时、Reality/VLESS、路由或目标服务故障 |
| `maintain` | 审计、备份、升级、换 IP 和恢复 |
| `client-adapt` | 为现有节点接入新客户端或新设备 |

## 为什么这版更快

第一次失败先问两个问题：

1. 服务器是否收到客户端连接？
2. 收到后 Reality 是否认证成功？

这会把故障快速分成：

- 服务器前路径：公网 IP、云防火墙、TUN 防回环、节点保存态、隧道快照；
- Reality 认证：凭证哈希、SNI、short ID、时间和客户端版本边界；
- VLESS/XTLS：UUID、Vision flow、TCP 与客户端序列化；
- 业务路由：规则顺序、代理组委托和真实出口。

没有新证据时，Skill 会拒绝反复更换端口、指纹、核心版本、target 或协议。

## Reality 版本兼容

截至 2026-07-28，Xray-core 当前源码在 `minClientVer` 留空时会应用默认最低客户端版本 `26.3.27`，其他 Reality 客户端可能被拒绝。Skill 会检查 Xray 实际加载配置和服务端记录的握手 `ClientVer`，只有证据闭合后才建议单变量放宽。

这里的 `ClientVer` 是 Reality 握手值，不一定等于 GUI 应用商店版本。显式降低最低版本还伴随 Xray 官方安全警告，因此不是所有部署的无条件默认。

## Shadowrocket 原生验收

macOS Shadowrocket 路径已经真实验证，但不把“导入成功”视为可用：

- 新节点 IP 先排除 TUN 回环；
- 导入后回读节点保存态；
- 节点测试必须产生真实连接证据；
- 建立只指向新节点的临时验收组；
- 出口 IP、Google、OpenAI、Claude 和下载都要有运行日志证明命中新节点；
- 独立 Xray 成功不能替代 Shadowrocket 原生成功。

## 费用与购买边界

Skill 本身免费开源，VPS、客户端、换 IP 或额外流量可能收费。AI 会在开始前列出当前官方价格、首购、续费、周期、自动续费、独立 IPv4、流量、退款与可选费用；每次付款前再次说明。付款、实名、验证码和下单由用户本人完成。

标称带宽通常是峰值或共享资源池能力，不是稳定吞吐承诺。最终只报告真实测试条件和结果。

## 目录

```text
SKILL.md
agents/openai.yaml
references/
  provider-selection.md
  client-adapters.md
  reality-compatibility.md
  shadowrocket.md
  troubleshooting.md
  security-and-acceptance.md
  tencent-lighthouse.md
  device-handoff.md
  clash-mihomo.md
  windows.md
scripts/
  audit-server.sh
  preflight-reality.sh
  diagnose-node.sh
  run-debug-window.sh
  redact-debug-log.py
  verify-client.sh
  build-transfer-package.sh
  backup-xui.sh
  test-skill.sh
  validate-public.sh
```

## 常用脚本

```bash
# 只读服务器审计
sudo bash scripts/audit-server.sh

# Reality 有效配置预检，只输出结构和哈希
bash scripts/preflight-reality.sh --config /path/to/effective-config.json

# 根据已知证据选择下一条诊断分支
bash scripts/diagnose-node.sh \
  --server-received clienthello \
  --reality failed \
  --vless unknown \
  --exit unknown \
  --effective-config yes \
  --contaminated no \
  --restored yes

# 验证本地代理出口与目标服务
bash scripts/verify-client.sh \
  --proxy socks5h://127.0.0.1:1082 \
  --expected-ip <VPS_IP> \
  --json-output /path/to/result.json

# 备份 3X-UI 数据库
sudo bash scripts/backup-xui.sh /path/to/x-ui-backup.db
```

## v0.6.0：先找原因，减少重复操作

- 安装前核对服务端核心与用户客户端的版本组合，不默认使用安装器最新核心。
- 首次连接失败读取同一次请求的两端诊断日志；TCP 已通时直接查握手。
- 同参数下 Xray 能通而 Shadowrocket/sing-box 失败时，优先检查握手兼容。
- 同一动作两次失败且无新证据时停止重复；通过节点、出口和指定分流后交付。
- 只把少量测试域名送到独立分组，保留主连接；缺少备用路径或恢复条件时不重建。
- HTTP 测试默认只验证出口与 Google，可用 `--targets exit,google,openai` 选择目标，`--skip-claude` 明确禁止 Claude 请求。

新增只读诊断读取和恢复条件检查工具：

```bash
python3 scripts/read-shadowrocket-diagnostics.py --since <ISO时间> --node-name <名称>
bash scripts/check-reload-safety.sh --evidence /path/to/recovery-evidence.json
```

服务端预检只证明配置结构成立，HTTP 测试仍需原生分流日志来证明请求用了新节点。45 项离线行为检查覆盖兼容分支、抓包时间错位、目标跳过、代理环境排除、日志脱敏和恢复；这些检查不替代新设备的真实验收。

## 已验证范围

- 腾讯云轻量 Ubuntu 24.04、3X-UI/Xray、VLESS Reality Vision：东京与硅谷真实案例；
- 2026-10-12：AlmaLinux 9.7、3X-UI 3.9.0、Xray 26.7.11、macOS Shadowrocket 2.2.92（3445）通过原生请求、出口与独立分流。26.7.11 是官方预发布版本，仅作为此组合的实测候选；本次没有测试 Claude。
- macOS Shadowrocket 原生节点、独立分流、出口和目标服务：A 已实测；
- Clash/Mihomo、Windows v2rayN：B/C，按当前内核和设备现场验证；
- 线路、IP 信誉和晚高峰：始终现场测试，不承诺永久稳定。

## 隐私与安全

- 仓库不包含真实私钥、密码、UUID、Reality 私钥、short ID、Token、节点 URI 或数据库正文；
- 敏感交付物只保存在本机，权限使用 `600`；
- 3X-UI 面板与订阅端口默认不公开；
- 独立节点 URI 不等于公网订阅；
- 会占用正式 443 的调试必须由服务器本地看门狗自动恢复并对日志脱敏；
- 退款、销毁和停用旧节点始终由用户确认。

## 验证公开版本

```bash
bash scripts/validate-public.sh
```

公开校验覆盖 Skill 结构、脚本语法与测试、敏感文件和字面量扫描、SQLite 热备份以及发布元数据一致性。

## 作者与许可

**[Nar / 那不然](https://github.com/Nar101)**

我在持续实践一件事：让 AI 从一次性回答，走向理解真实环境、遵守操作边界、执行并验证结果。这个 Skill 是其中一个可公开复用的真实样本。

[MIT License](./LICENSE)
