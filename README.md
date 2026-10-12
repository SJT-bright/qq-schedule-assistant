# QQ 排程助手

面向 macOS 与 Windows 的本地 QQ 群聊排程工具。用户在桌面端整理群聊名单、文案与素材，预览排期后选择保存或启动。macOS 应用通过辅助功能操作已登录的 QQ 客户端，Windows 候选版使用 UI Automation；不会保存 QQ 密码。

## 主要功能

- 管理群聊名单、常用文案和本地图片等素材，支持多工作空间。
- 按开始时间、发送轮次和群间隔生成计划，预览后保存或启动。
- 查看待执行队列、执行进度和发送记录，可暂停、调整待执行任务及导出记录。
- 发送前检查目标会话、输入框、文字和附件状态；异常时暂停并保留待人工核对记录。
- 提供本地 SQLite 数据备份和恢复。
- 附带可选的 Python 服务端，用于账号、试用、会员卡密及管理后台。

## 构建与验证

需要 Apple Silicon Mac、macOS 14 或更新版本，以及 Xcode Command Line Tools。

```bash
bash build.sh
bash test.sh
```

构建输出位于 `dist/QQ排程助手.app`。首次使用需要在 macOS 系统设置中授予辅助功能权限，并在官方 QQ 客户端自行登录。可选服务端的启动方式见 [Server/README.md](Server/README.md)。

自动化测试使用隔离资料，不会向真实 QQ 会话发送消息。真实 QQ 环境中的图文发送效果需要在用户自己的客户端单独核验。

## v3.9.6 / build116

macOS 新增数据库连接故障自动重连一次，仍无法保存时停止全部队列；发送工作台分为「发送队列」「排期与间隔」「发送进度」三页。安装前备份资料，使用固定证书构建后正常退出并重开，核对实际运行映像。

Windows 安装包与便携版见 [GitHub Releases](https://github.com/SJT-bright/qq-schedule-assistant/releases)。Windows 界面、数据字段与业务流程按当前 Mac 版移植；首次运行空库，不含个人资料。开发与使用见 [Windows/README.md](Windows/README.md)，验收差异见 [版本验收记录](docs/release-3.9.6/REPORT.md)。

**Windows 是首个适配候选，尚未完成真实 Windows QQ 的群定位、图文发送和发送后核验。Windows 微信自动发送与普通文件自动发送没有已验证契约，对应路径明确拦截；不能称全部功能已完成 1:1 实机验收。** 隔离界面、业务测试和 Windows runner 结果分别记录，不代表实际群消息送达。

Windows 构建：

```sh
cd Windows
npm ci
npm test
npm run test:e2e
npm run build
```

Windows 发布包包含 Electron 运行时，可直接运行，无需额外安装 Node.js 或 Python。现有 Python 会员服务可供两个平台使用；本轮没有部署服务端。
