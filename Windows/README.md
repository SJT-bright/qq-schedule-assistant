# QQ 排程助手 Windows 版

按 macOS v3.9.6/build116 的十个页面、配色、数据字段与调度规则移植。Windows 10/11 x64；下载安装包或解压便携 ZIP，直接运行 QQ排程助手.exe，不需要单独安装 Node.js/Python。

资料存放在 `%APPDATA%\QQ排程助手`，安装包和升级不携带个人群名、文案、素材、记录、会员会话或 QQ 登录信息。升级和卸载不主动删除该目录。首次运行是空库，先新增群、导入素材并创建计划。

## 使用

1. 自行在官方 QQ 客户端登录，保持桌面解锁；QQ 和助手使用相同权限级别。
2. 在「群与联系人」整理群名、试跑定位；试跑不填写或发送。
3. 「新建发送」选择群、图文、开始日期与轮次，先预览再保存。
4. 「发送队列」明确点击立即开始或按排期启动；「排期与间隔」修改时间与间隔；「发送进度」查看各队列。
5. 失败或待核对只记日志并跳过，不自动重复尝试。暂停快捷键 Ctrl+.。未核对时不要把旧记录改成已发。

## Windows 验收范围

源码含 Windows UI Automation 原生驱动：前台/可见落点、第一条搜索结果、禁止加群、双拍会话与输入框、空草稿、图文内容、提交前持久化、单次提交和发送后严格核验。只有可识别的稳定消息编号、本人图文、连续旧尾锚及空草稿均成立才显示界面已核验；未知控件格式必须停止。设置页可查看只读诊断，不会自动上传。

**真实 Windows QQ 群定位、图文提交和发送后核验尚未在实际 QQ 客户端验收，不能把界面/隔离测试通过当成真实发送通过。** Windows 微信自动发送和普通文件发送尚无实测控件/提交契约，因此对应路径明确拦截；微信名单、文案复制与人工维系保留。当前版本是首个 Windows 适配候选，尚不能称全部功能已完成 1:1 实机验收。不要取消校验来绕过这些拦截。

资料兼容 Swift 版的 SQLite JSON 表与 Apple reference-date 时间。恢复备份前暂停全部队列；应用检查库和素材完整性，并先保存当前资料。未知和坏行隔离保留。应用不保存 QQ 密码；会员会话使用 Windows 加密存储。

## 开发

```sh
npm ci
npm test
npm run test:e2e
npm run build
```

`test:e2e` 创建临时资料目录并启用禁止发送模式，实际点击、输入、预览/取消、排期保存、异常拦截、历史恢复与重开回读。macOS 上执行只能证明共用 Electron 界面与业务；GitHub Windows runner 检查 Windows 运行时、安装包和共用界面。二者均不证明实际 QQ 送达。Windows 原生驱动来源：[Microsoft UI Automation](https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-clientportal)；桌面隔离按 [Electron 官方安全建议](https://www.electronjs.org/docs/latest/tutorial/security)。

发布包目前没有 Windows Authenticode 证书签名；下载后应对照 Release 的 SHA256SUMS 校验。没有后台自启队列或自动更新下载行为。
