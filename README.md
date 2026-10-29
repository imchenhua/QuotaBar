# QuotaBar

轻量 macOS 菜单栏额度面板，集中查看 Claude 与 GPT 的账号、套餐、实际额度窗口和重置倒计时。

**[下载 QuotaBar（DMG）](https://github.com/imchenhua/QuotaBar/releases/latest/download/QuotaBar-arm64.dmg)** · [查看版本更新](https://github.com/imchenhua/QuotaBar/releases) · [English](README.en.md)

## 安装

1. 下载并打开 DMG。
2. 双击 **Install QuotaBar**，点 **安装 QuotaBar**。应用会自动安装并打开。
3. 点击菜单栏的 Q 图标，在设置中添加 Claude / GPT 账号。

无需终端命令。应用会自动检查、下载并安装后续签名版本，也可以在设置中关闭自动更新或手动检查。

支持 **Apple Silicon、macOS 27 及以上**。当前版本尚未经过 Apple 公证；如果系统阻止打开，请到「系统设置 → 隐私与安全性」中确认允许。

- 菜单栏只显示一个图标，点击查看额度。
- 根据接口返回的实际窗口显示 5h、7d 等限额，不根据套餐名称虚构窗口。
- 支持多个 Claude / GPT 账号、手动刷新和统一诊断。
- 账号管理放在设置中；设置与仪表在同一面板内切换。
- 设置中可选择跟随系统、简体中文或 English，切换立即生效。
- 更新使用 Sparkle，对 GitHub Releases 的更新包与更新源进行 Ed25519 签名验证。

## 登录与数据

当前发布包支持 **Apple Silicon、macOS 27 或更新版本**。GPT 额度查询需要安装 Codex CLI；Claude Code 当前账号识别需要 Claude Code CLI。额度查询不会启动模型对话。

安装器会自动将应用放到 `~/Applications/QuotaBar.app`，已有版本会先备份，无需自行选择路径。

在设置中分别添加 Claude 或 GPT 账号。新增 GPT 账号使用独立 CLI 登录目录，不覆盖原有 Codex CLI 登录。后台刷新不请求钥匙串交互授权；需要切换 Claude Code 账号时，由用户主动操作。

账号资料保存在本机的 `~/.config/quotabar`，凭据使用固定身份的本地助手与系统钥匙串。发布仓库和更新包不包含开发机器上的账号、登录令牌或日志。

## 开发：从源码构建

安装 Xcode Command Line Tools 后运行：

```sh
bash build.sh
bash scripts/check.sh
```

构建结果位于 `build/QuotaBar.app`。构建脚本会下载并校验固定版本的 Sparkle。`support/credential-agent-v1` 是固定身份的凭据助手，构建会核对源码和二进制摘要，不会在升级时重新编译或替换已安装的凭据助手。

退出现有 QuotaBar 后，可运行 `python3 scripts/install.py` 安装，再运行 `python3 scripts/start.py` 启动并配置登录时启动。安装前会备份旧应用。

## 开发：发布更新

`Info.plist` 中的版本号、构建号必须随新版本递增。配置自己的更新签名密钥、公钥和更新源后，运行：

```sh
python3 scripts/package_release.py
python3 scripts/package_dmg.py
```

脚本验证签名、凭据助手摘要，生成应用压缩包、签名的 `appcast.xml`、DMG 安装器与 SHA-256 清单。签名私钥留在发布者机器的 `~/.local/share/quotabar-update-signing/ed25519.key`，不可提交仓库或放入应用。

发布时将版本目录中的 `.zip`、`.dmg`、`appcast.xml`、`SHA256SUMS` 上传至对应 GitHub Release，核对公开下载地址。自动更新使用签名 ZIP，首次安装使用 DMG。

维护者完成代码提交并登录正确 GitHub 账号后，也可以运行 `python3 scripts/publish_release.py --notes-file CHANGELOG.md`。脚本会核对账号、公开仓库、文件摘要和版本标签，推送源码并发布，再核验公开下载内容。

Sparkle 的许可证见 [support/Sparkle-LICENSE](support/Sparkle-LICENSE)。
