# Reality 客户端兼容与目标站预检

## 目录

1. 为什么要在 GUI 接入前检查
2. 已实测的版本组合与握手差异
3. 客户端版本边界
4. 条件性兼容修复
5. target 与 fallback
6. 可接受的证据

## 为什么要在 GUI 接入前检查

先记录面板、服务端核心、原生客户端、独立测试客户端的版本。选择官方发布中与目标客户端有实测证据的组合；没有证据时先做一次隔离握手测试，不先完成全部 GUI 配置。`preflight-reality.sh` 只检查结构，不能从一个 JSON 文件证明客户端兼容。

## 已实测的版本组合与握手差异

2026-10-12，同一台 AlmaLinux 9.7、3X-UI 3.9.0 服务器上，保持 VLESS/Reality/Vision、TCP 443、凭证和 SNI 不变：

| 服务端核心 | 原生客户端 | 结果与范围 |
|---|---|---|
| Xray 26.9.30 | macOS Shadowrocket 2.2.92（3445） | 本地 HTTP 代理 503，客户端 `invalid backend status`；未通过 Reality |
| Xray 26.7.11 | 同一 Shadowrocket | 原生测试 258 ms，请求 200，US/LAX 出口等于 VPS，指定域名命中独立测试组 |

根因证据：26.9.30 使用的 REALITY 代码要求 ClientHello 的 `key_share` 包含 `X25519MLKEM768`，并在可选的 `X25519` 之前；缺少该字段会在解密认证前进入 fallback。26.7.11 使用的代码接受单独的 `X25519`，本次仅切换核心就通过。服务端成功日志包含 `conn == conn: true`，握手错误为 `<nil>`。这不说明所有 Shadowrocket 或后续 Xray 版本都不兼容。

[26.7.11 官方发布](https://github.com/XTLS/Xray-core/releases/tag/v26.7.11) 标记 `prerelease: true`。它是本次实测候选，不是永久稳定默认；部署前仍核对官方状态、校验发布文件，并检查是否已有更新的已验证组合。此例没有测试 Claude。

当相同参数下 Xray 独立客户端通过，而 Shadowrocket/sing-box 失败，或出现 503、`invalid backend status` 与 fallback：

1. 先读同一次请求的两端诊断日志，确定是否已经收到 TCP/ClientHello。
2. 核对当前核心依赖的 REALITY 代码中的 `keyShares`、`X25519MLKEM768`、`MinClientVer`；不能只看 GUI 是否支持 Reality。
3. 对照凭证哈希、时间、SNI 和握手字段。必要时只切换一个已核验官方核心版本，保留所有协议参数，备份后做一次对照。
4. 通过后固定组合并完成原生分流；失败则恢复，不连续盲降版本。

`minClientVer` 只控制解密后的版本校验。它不能补齐缺失的 ClientHello 字段，不能用放宽版本门槛代替握手兼容诊断。

## 客户端版本边界

2026-07-28 曾核对的 Xray-core `infra/conf/transport_security.go` 将留空的服务端 `minClientVer` 默认设为 `26.3.27`。此记录不适用于所有版本：26.7.11 与 26.9.30 的默认行为不同。以实际安装版本的官方源码、有效配置和同次握手日志为准，不按旧记录统一放宽最低版本。

Reality 日志中的 `ClientVer` 是握手协议上报值，不一定等于 GUI 应用商店版本。不要拿应用“关于”页面直接参与版本比较。

配置语义：

- `minClientVer` 留空：当前 Xray 可能应用自己的默认最低版本。
- 显式 `minClientVer`：覆盖默认最低版本。
- `maxClientVer` 留空：通常不设置上限，但仍以当前源码和有效配置为准。
- 3X-UI 表单、数据库记录和 Xray 实际加载 JSON 可能不同，必须检查有效配置。

## 条件性兼容修复

只有下列证据同时成立，才考虑显式放宽最低版本：

1. 服务端收到完整连接；
2. Reality 日志为 authentication/validation failed；
3. 客户端时间、SNI、short ID 和凭证哈希正确；
4. 服务端记录了低于默认门槛的 `ClientVer`；
5. 独立或原生客户端在放宽前稳定失败；
6. 变更前已备份 3X-UI 数据库与有效配置。

可以用 `minClientVer: 0.0.0` 做单变量对照，但它不是所有部署的无条件默认。Xray 官方警告：修改最低版本可能提高服务器 IP 被识别或封锁的风险。实施后必须：

- 保留 UUID、Reality 密钥、short ID、时间和 SNI 校验；
- 不同时更换 target、端口、指纹或核心版本；
- 重启服务并回读有效配置；
- 完成原生客户端与独立分流验收；
- 失败则恢复备份，不继续扩大变量。

## target 与 fallback

候选 target 必须从 VPS 本机验证：

- DNS 可解析；
- TCP 443 可达；
- TLS 1.3 握手稳定；
- SNI 与证书匹配；
- 多次测试结果一致。

知名域名不等于适合作为 Reality target。若认证未通过，服务端可能把连接转给 target；客户端随后出现 VLESS backend/status 错误。这时不能把 fallback 可访问误判为 Reality 成功。

更换 target 前先证明：凭证、时间、short ID、版本边界和公网字节路径均无误。只允许一次单变量候选切换，成功后同步更新服务端与客户端 SNI，并重做完整验收。

## 可接受的证据

优先级从高到低：

1. 当前 Xray 官方源码或发布说明；
2. 服务端 `show/debug` 在同一次握手窗口内的日志；
3. Xray 实际加载的有效配置；
4. 客户端运行日志和服务端到包；
5. 3X-UI API/数据库提交内容；
6. UI 显示值。

低优先级证据不得推翻更高优先级证据。
