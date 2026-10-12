macOS v3.9.6/build116：数据库连接故障自动重连一次；队列工作台拆为发送队列、排期与间隔、发送进度。固定证书构建、本机正常更新及实际运行身份、资料保留/恢复检查已通过。

新增Windows x64安装包与便携ZIP，按当前Mac版界面、数据和业务流程移植。Windows runner已通过业务回归、原生桥加载、62项源码界面交互、安装包构建及62项打包后EXE交互检查。

Windows是首个适配候选：真实QQ群定位、图文发送及发送后核验尚未实机验收，微信和普通文件自动发送缺已验证契约，对应路径明确拦截。不能称全部功能已经完成1:1实机验收。两个平台本轮均未向真实群发送消息。

安装包不包含个人群名、文案、素材、记录、会员会话或QQ登录信息；更新和卸载不会主动删除资料。下载后可使用SHA256SUMS.txt核对文件。Windows包未签Windows Authenticode证书；Mac包为现有本机固定开发证书签名，非Apple公证发布。

[完整验收记录](https://github.com/SJT-bright/qq-schedule-assistant/blob/main/docs/release-3.9.6/REPORT.md)
