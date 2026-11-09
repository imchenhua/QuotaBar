# QuotaBar 2.6.6

- 修复关闭「添加 Claude 账号」窗口后几秒内应用崩溃退出的问题（窗口被重复释放）；独立面板窗口同样修复。
- 身份核验失败时区分原因：网络／代理不可用、凭据失效（401/403）、账号不匹配、服务端临时错误；不再一律提示「请重新登录」。
- 网络不可用时每分钟重试，代理恢复后额度立即恢复显示，不再退避到 30 分钟。

## QuotaBar 2.6.5

- Token 图表的粒度切换改为简洁的「时／日／月」，悬停显示对应范围（24 小时／30 天／12 个月）。

## QuotaBar 2.6.4

- 切换同时更新共享凭据和 `~/.claude.json` 中的账号身份，并复核两份状态；失败时恢复原凭据和身份，保留其他项目与 MCP 配置。
- 切走前保存当前账号最新令牌；后台不续期 Claude Code 当前共享登录，独立账号续期按账号加锁，并保留已轮换的新令牌。
- 识别 Claude Code 的续期锁，避免在其续期过程中覆盖登录状态。
- 身份不一致不再标成“当前”；对已用满 5h／7d 的账号显示限制提示，切换后明确提示 Rebon 旧会话需要重连。
- 验证新增：配置保留与私有备份、两份状态回滚、共享令牌续期排除、未知归属时不续期、跨进程续期互斥与陈旧锁恢复。

## QuotaBar 2.6.2

- 修复 Claude 凭据续期／切换后签名分区被重置、持续弹钥匙串密码窗口的问题。共享凭据改由 Apple 工具原地更新，原固定助手只管理私有资料。
- 旧凭据迁移先创建并验证加密恢复副本，再迁移共享条目；账号和令牌保持不变。
- 权限不可用时直接显示失败，不自动请求授权；切换进度与错误直接显示在对应账号旁。
- 修复续期后临时网络失败可能丢失轮换刷新令牌的问题；版本显示改为读取实际应用版本。
- 验证覆盖旧权限迁移、连续 12 次写入与读取、无授权时拒绝访问、无效写入保护和转义令牌。

Shared Claude credentials now use Apple-owned, in-place updates instead of native helper writes that reset partition access. Migration keeps verified encrypted recovery copies; unavailable access fails without an authorization fallback. Regression tests cover migration and twelve repeated credential updates and reads.

## QuotaBar 2.6.0

- 提供 DMG 安装包：打开后点击安装，自动放好应用并启动，已有应用先备份。
- 新增 Language 设置：跟随系统、简体中文和 English，切换立即生效。
- 启用 GitHub 自动更新：支持自动检查、下载和空闲时安装；验证更新源和更新包签名。
- Claude / GPT 多账号额度、套餐识别与紧凑重置倒计时。
- 统一诊断覆盖 Claude 和 GPT；移除两家的服务状态监控。

**安装：** 下载下方 `QuotaBar-arm64.dmg`，打开并双击 **Install QuotaBar**。

当前支持 Apple Silicon、macOS 27+。此版本尚未经过 Apple 公证；如系统阻止打开，请到系统设置的「隐私与安全性」确认允许。

---

- One-click DMG installer, with backups of an existing installation.
- System default, Simplified Chinese, and English; language changes apply immediately.
- Signed GitHub updates with automatic checking, downloading, and installation when idle.
- Multiple Claude / GPT accounts, actual quota windows and plans, compact reset countdowns, and unified diagnostics.

**Install:** Download `QuotaBar-arm64.dmg`, open it, and double-click **Install QuotaBar**.

Requires Apple Silicon and macOS 27+. This release is not yet notarized by Apple; if macOS blocks it, review it in System Settings → Privacy & Security.
