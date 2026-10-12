# Shadowrocket 接入与验收

## 目录

1. 四层真相
2. 接管前基线
3. 黄金接入顺序
4. 独立分流验收
5. 失败分层
6. 底层编辑与隧道重载
7. 跨设备边界

## 四层真相

Shadowrocket 至少存在四个不能互相替代的状态：

1. **UI 显示态**：编辑页面当前显示的值。
2. **节点保存态**：持久化节点对象真实保存的字段。
3. **规则保存态**：当前配置文件、代理组和规则顺序。
4. **隧道运行态**：`MacPacketTunnel` 实际加载的节点和规则快照。

“保存成功”只证明 UI 动作结束。每次编辑后必须重新打开节点或导出节点 JSON 到本机受限文件，回读端口、SNI、flow、Reality、fingerprint 等非敏感结构；随后用运行日志或服务端到包证明隧道真正使用了该对象。

## 接管前基线

### 直接找到当前配置和诊断日志

首次失败就运行 `python3 scripts/read-shadowrocket-diagnostics.py --since <ISO时间> --node-name <名称>`，只输出匹配窗口中的脱敏诊断行。脚本默认从本机 Group Containers 发现目录，不修改配置；模拟测试可以传 `--group-dir <临时目录>`。

- 当前配置名：Group Container 中偏好设置的 `group.com.liguangming.CurrentRuleFileName`。先读此值，再找对应的源库，不扫描或编辑历史副本。
- 握手诊断：`Library/Caches/DebugLogs/PacketTunnel-*.log`。它包含 TCP、Reality、VLESS 和本地 HTTP 代理错误；失败时优先读它。
- 规则命中：`Library/Caches/Logs/proxy-*.db`。它只证明域名被送到哪一组/节点，不能证明握手成功。
- 节点保存表：`ServerManager`。内部节点对象 UUID 与 VLESS 凭证 UUID 不同；本次版本的 VLESS 凭证保存在 `password`。敏感值只比较哈希，不导出数据库正文。

路径和表字段须现场发现；不把本次设备的容器 UUID 写成通用默认。沙箱中的 `scutil --nc status` 曾显示 Disconnected，但实际隧道和代理正在运行；VPN 状态必须结合进程、监听和真实请求判断。

### 记录并保护主连接

- 回读首页当前节点、全局路由模式、VPN 状态和当前配置。
- 从运行态读取本地 SOCKS/HTTP 监听，不能把 `127.0.0.1:1082` 当成通用默认。
- 读取现有代理组委托和高优先级规则。
- 记录当前 `MacPacketTunnel` PID、当前出口和回退路径。
- 检查新服务器公网 IP 是否已加入 TUN 排除路由。若没有，加入精确 `/32` 后回读系统路由，确认该 IP 走物理网卡而不是当前 TUN。
- 不关闭 VPN、不切换当前节点、不改变全局路由，除非用户在动作前明确确认。

## 黄金接入顺序

1. 先让独立 Xray/sing-box 客户端通过公网验证服务端；它失败时不要进入 Shadowrocket UI 调参。
2. 导入新节点，使用中性本地名称。本次 2.2.92 单节点剪贴板入口是首页叠纸图标，不是配置文件导入页；看不到该图标时先读当前 UI，不编造“粘贴”文字按钮。
3. 回读节点保存态：TCP 443、VLESS、Vision、Reality、SNI、public key、short ID、fingerprint。敏感字段只比哈希。
4. 每次界面变化后重新读取 UI；不复用旧 AX 编号。节点次级菜单中的“测试”曾切换当前主节点，不能凭名称认定安全。不能确认其行为时，跳过该入口，直接建立独立验收组。
5. 使用只含新节点的验收组发送请求，同时读取两端诊断日志。首页主节点保持原值；运行日志或原生请求通过即可，不强制再做一次可能切主节点的 UI 测试。
6. 通过本地代理发送真实请求，并从 Shadowrocket 运行日志确认域名、代理组和节点。
7. 需要迁移业务时，让业务组委托统一上层组，不把具体节点名散落到多条业务规则。

## 独立分流验收

建立临时组，例如 `NEW-NODE-TEST`，只包含新节点。置顶加入少量精确规则：

- 出口 IP 检查域名；
- Google `generate_204`；
- 用户要求的其他目标或下载测速域名。

默认出口与 Google 已足够验证基本可用；用户说暂不测 Claude 时，不加入 Anthropic/Claude 规则，不向这些域名发请求。网站登录验收与无凭证 HTTP 连通性是两件事。

验收必须同时看到：

```text
请求成功
+ 出口 IP 等于新 VPS
+ 运行日志命中 NEW-NODE-TEST
+ 运行日志使用新节点
```

已有宽泛规则若先命中，例如整个下载域名走旧 `PROXY`，该次测速无效；把精确规则置顶并重新验证。

## 失败分层

### 0 秒失败且服务器没有任何连接

此结论只允许来自同次请求的诊断日志或同步抓包。抓包晚于请求、过滤了错误 IP/端口或只看规则库时，状态填 `unknown`，先补一条有效日志。

优先检查：

- 新服务器 IP 是否仍被 TUN 接管；
- 节点保存态是否缺关键字段；
- 端口是否仍残留为已关闭的诊断端口；
- 测速 IPC 引用的节点 ID 是否存在于隧道快照；
- 编辑后是否只刷新了主应用，没有刷新隧道。

此分支不要修改 Reality target、核心版本或服务器协议。

### 服务器收到 TCP，Reality authentication failed

先核对：

- 服务端实际配置与客户端凭证哈希；
- SNI、short ID、时间差；
- Xray `minClientVer/maxClientVer` 与服务端记录的 Reality `ClientVer`；
- 是否进入 target fallback。

若独立 Xray 通过、原生客户端失败，优先走 `reality-compatibility.md` 的握手特性分支。不要继续反复改名称、保存刷新或重建隧道。

读取 `reality-compatibility.md`。不要把 Reality 握手上报的 `ClientVer` 直接当成 Shadowrocket App Store 版本。

### Reality 成功但 VLESS 失败

核对协议 UUID 哈希、`flow=xtls-rprx-vision`、TCP 和客户端的 VLESS encryption/序列化字段。此时才比较已验证旧节点的非敏感结构。

### 请求成功但出口错误

检查规则顺序、代理组委托、当前配置和运行日志。不要继续改节点参数。

## 底层编辑与隧道重载

UI 优先。只有 UI 无法生成兼容记录且用户明确授权时才编辑底层：

1. 确认当前真相源，不修改 iCloud 历史副本。
2. 备份并记录 SHA-256。
3. 只改目标节点的必要字段。
4. 执行 `pragma integrity_check`。
5. 重开 UI，确认没有被新版序列化再次覆盖。
6. 用运行证据复验。

保存态正确但隧道仍使用旧快照时：

1. 先尝试应用公开的热重载入口。
2. 无效时说明为什么必须重建隧道、预计中断多久和自动恢复方式。
3. 已有当前动作授权可复用。先按 `security-and-acceptance.md` 验证备用代理、物理路径、工具权限和脱离会话的恢复动作；任何一项缺失就停止重建。
4. 后台动作完成 stop → start 后，检查新 PID、本地监听、主节点和原出口请求。只显示 Connected 不足以证明恢复。失败一次且没有新的旧快照证据时，不再次重建。

## 跨设备边界

优先使用受控文件包，不把 Shadowrocket iCloud 自动同步当成唯一交付机制。节点文件与规则文件分开；新设备导入后重新验证保存态、原生测速和出口。详见 `device-handoff.md`。
