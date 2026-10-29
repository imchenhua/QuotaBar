# QuotaBar

轻量 macOS 菜单栏额度面板，集中查看 Claude 与 GPT 的账号、套餐、实际额度窗口和重置倒计时。

- 菜单栏只显示一个图标，点击查看额度。
- 根据接口返回的实际窗口显示 5h、7d 等限额，不根据套餐名称虚构窗口。
- 支持多个 Claude / GPT 账号、手动刷新和统一诊断。
- 账号管理放在设置中；设置与仪表在同一面板内切换。
- 更新使用 Sparkle，对 GitHub Releases 的更新包与更新源进行 Ed25519 签名验证。

## 系统与登录

当前发布包支持 **Apple Silicon、macOS 27 或更新版本**。GPT 额度查询需要安装 Codex CLI；Claude Code 当前账号识别需要 Claude Code CLI。额度查询不会启动模型对话。

从 Releases 下载并解压，将 `QuotaBar.app` 放到 **`~/Applications/QuotaBar.app`**，然后打开。凭据助手会检查应用所在位置，当前版本必须使用这个路径。当前应用使用本地签名，尚未经过 Apple 公证。

在设置中分别添加 Claude 或 GPT 账号。新增 GPT 账号使用独立 CLI 登录目录，不覆盖原有 Codex CLI 登录。后台刷新不请求钥匙串交互授权；需要切换 Claude Code 账号时，由用户主动操作。

账号资料保存在本机的 `~/.config/quotabar`，凭据使用固定身份的本地助手与系统钥匙串。发布仓库和更新包不包含开发机器上的账号、登录令牌或日志。

## 从源码构建

安装 Xcode Command Line Tools 后运行：

```sh
bash build.sh
bash scripts/check.sh
```

构建结果位于 `build/QuotaBar.app`。构建脚本会下载并校验固定版本的 Sparkle。`support/credential-agent-v1` 是固定身份的凭据助手，构建会核对源码和二进制摘要，不会在升级时重新编译或替换已安装的凭据助手。

退出现有 QuotaBar 后，可运行 `python3 scripts/install.py` 安装，再运行 `python3 scripts/start.py` 启动并配置登录时启动。安装前会备份旧应用。

## 发布更新

`Info.plist` 中的版本号、构建号必须随新版本递增。配置自己的更新签名密钥、公钥和更新源后，运行：

```sh
python3 scripts/package_release.py
```

脚本验证签名、凭据助手摘要，生成应用压缩包、签名的 `appcast.xml` 与 SHA-256 清单。签名私钥留在发布者机器的 `~/.local/share/quotabar-update-signing/ed25519.key`，不可提交仓库或放入应用。

发布时将整个版本目录中的 `.zip`、`appcast.xml`、`SHA256SUMS` 上传至对应 GitHub Release，核对公开下载地址后再启用应用更新。

Sparkle 的许可证见 [support/Sparkle-LICENSE](support/Sparkle-LICENSE)。
