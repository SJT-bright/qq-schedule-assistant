# QQ排程助手 · 商业化服务端

为 macOS 应用「QQ排程助手」提供账号注册 / 登录 / 会员试用 / 卡密兑换 / 管理后台的一体化服务端。

- **零依赖**：纯 Python 3 标准库（http.server、sqlite3、hashlib 等），macOS 自带 Python 3.9 直接运行，无需 pip 安装任何东西。
- **单文件**：全部逻辑在 `server.py`；页面在 `www/`；数据库与配置自动生成。
- **SQLite + WAL**：单文件数据库，备份即拷贝。
- **售卖模式**：管理员批量生成卡密 → 用户在 App 内兑换卡密获得会员时长。真实支付网关（微信/支付宝）暂不接入，代码中已预留接入点（见下文「接入真实支付」）。

## 目录结构

```
Server/
├── server.py          # 服务端主程序（单文件）
├── run.sh             # 启动脚本：bash run.sh
├── smoke_test.sh      # 冒烟测试：bash smoke_test.sh
├── README.md          # 本文件
├── server.json        # 配置文件（首次运行自动生成；含 admin 密码哈希，勿提交仓库）
├── data/              # 数据目录（首次运行自动创建；已加入 .gitignore）
│   └── billing.sqlite3
└── www/
    ├── index.html     # 官网落地页（深色 / 靛蓝 / 纯内联 CSS）
    └── admin.html     # 管理后台单页应用（原生 JS + fetch）
```

## 本地启动

```bash
cd Server
bash run.sh
```

首次运行会自动：

1. 生成 `Server/server.json` 配置（host / port / trial_days / token_ttl_days / plans / admin 密码哈希）；
2. 创建 `Server/data/billing.sqlite3` 数据库并建表（WAL 模式）；
3. **随机生成管理员初始密码，只在控制台打印一次**：

```
================================================================
  [QQ排程助手] 首次初始化完成，已生成管理员初始密码

  管理后台地址: http://127.0.0.1:8790/admin
  管理员初始密码: Xx2k9mPq4Rt7Wb

  ※ 此密码【只在本次打印一次】，请立即记录。
================================================================
```

- 忘记 / 想换管理密码：**删除 `server.json` 后重启**即重新生成（用户与卡密数据不受影响）。
- 打开 `http://127.0.0.1:8790/` 是官网落地页；`http://127.0.0.1:8790/admin` 是管理后台（输入上述密码登录）。
- App 端将 API Base URL 指向 `http://<服务端地址>:8790` 即可。

### 修改端口 / 地址

编辑 `server.json` 里的 `host` / `port` 后重启，或临时指定：

```bash
python3 server.py --host 0.0.0.0 --port 9000
```

## 配置说明（server.json）

| 字段 | 默认值 | 说明 |
|---|---|---|
| `host` | `127.0.0.1` | 监听地址；对外服务改 `0.0.0.0`（建议配反向代理 + HTTPS） |
| `port` | `8790` | 监听端口 |
| `trial_days` | `3` | 新用户注册赠送的试用天数；改为 `0` 即关闭试用 |
| `token_ttl_days` | `30` | 登录 token 有效天数（每次请求滑动续期） |
| `admin_password_hash` / `admin_password_salt` | 自动生成 | 管理密码的 PBKDF2 哈希与盐 |
| `plans` | 月卡/季卡/年卡 | 档位配置，见下 |

### 改价方法（不用改代码）

直接编辑 `server.json` 的 `plans` 数组后重启服务端。价格以「分」为整数存储：

```json
"plans": [
  { "id": "month",   "name": "月卡", "days": 30,  "price_fen": 990,  "tagline": "30 天会员 · 当前优惠价" },
  { "id": "quarter", "name": "季卡", "days": 90,  "price_fen": 2690,  "tagline": "90 天会员 · 折合约 ¥8.97/月" },
  { "id": "year",    "name": "年卡", "days": 365, "price_fen": 9900, "tagline": "365 天会员 · 最划算" }
]
```

- `price_fen` 单位是分（¥9.9 = 990）；`price_display` 由服务端自动计算，无需手填。
- 官网落地页与 App 读取的价格来自 `GET /api/plans`，改配置即全端生效。
- 注意：**已生成的卡密按生成时的价格/天数核销**，改价只影响之后新生成的卡密。

## API 一览

公开接口：

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/` | 官网落地页 |
| GET | `/admin` | 管理后台单页 |
| GET | `/api/plans` | 档位列表 `[{id,name,days,price_fen,price_display,tagline}]`；响应头 `X-Trial-Days` 为当前有效试用天数 |
| POST | `/api/register` | `{account,password}` → `{token,profile}`；试用天数按 `trial_days` 配置（缺省 3 天） |
| POST | `/api/login` | `{account,password}` → `{token,profile}` |
| POST | `/api/logout` | （Bearer）注销当前 token |
| GET | `/api/me` | （Bearer）→ `{account,plan_label,paid_until,days_left,source:"trial|paid",...}`；token 滑动续期 |
| POST | `/api/redeem` | （Bearer）`{code}` → `{ok,profile,redeemed}`；错误区分 `CODE_NOT_FOUND` / `CODE_USED` / `ACCOUNT_DISABLED` |

管理接口（先 `POST /api/admin/login {password}` → `{admin_token}`，后续带 `Authorization: Bearer <admin_token>`）：

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/api/admin/logout` | 注销当前管理 token，其他管理会话保持有效 |
| GET | `/api/admin/overview` | 用户数 / 有效会员 / 试用中 / 累计收入(元) / 卡密未用·已用；有效会员与试用中均排除禁用账号 |
| GET | `/api/admin/users?q=` | 用户列表（支持账号搜索） |
| POST | `/api/admin/users/grant` | `{user_id,days,note}` 客服补单直接加时长 |
| POST | `/api/admin/users/disable` | `{user_id,disabled}` 禁用 / 恢复账号 |
| POST | `/api/admin/codes/generate` | `{plan_id,count(1-500),note}` 批量生成卡密，返回码列表 |
| GET | `/api/admin/codes?status=&q=` | 卡密列表（状态为 `unused` / `used` / `void`，可按卡密筛选；非法非空状态返回 `400 INVALID_STATUS`，导出同样校验） |
| POST | `/api/admin/codes/void` | `{code}` 作废未使用卡密；重复作废返回 `409 CODE_VOID`，已使用返回 `409 CODE_USED` |
| GET | `/api/admin/codes/export?status=&q=` | 卡密 CSV 导出（带 BOM，Excel 直接打开） |
| GET | `/api/admin/redemptions` | 兑换记录（谁 / 哪张码 / 哪个档 / 时间 / 金额） |

## 卡密售卖流程

1. **生成**：管理后台 →「卡密管理」→ 选档位 + 数量（1-500）+ 备注 → 生成 → 复制全部 / 导出 CSV。
   卡密形如 `QP-M-XXXX-XXXX`（M=月卡，Q=季卡，Y=年卡；字符集已剔除 0/O/1/I/L 等易混字符）。
2. **上架售卖**（任选其一）：
   - 发卡平台自动发货：把 CSV 里的卡密批量导入发卡平台（如独角发卡等），买家付款后自动发放；
   - 微店 / 淘宝店铺：人工客服核对订单后发送卡密；
   - 闲鱼人工发货：买家拍下后私聊发送卡密。
3. **用户兑换**：用户在 App「会员 / 兑换」输入卡密 → 时长在现有到期时间上**滑动叠加**立即生效。
4. **对账**：后台「兑换记录」与顶部「累计兑换收入」即为实际到账金额，可与各渠道订单核对。
   每张卡密只能核销一次（数据库唯一约束 + 原子 UPDATE，重复兑换返回 409）。

## 部署到 VPS

前提：一台 VPS + Python 3.9+（无需任何 pip 包）。上传整个 `Server/` 目录（`data/` 与 `server.json` 会自动生成）。

> 推荐架构：Nginx/Caddy 反向代理 + HTTPS → 转发到 `127.0.0.1:8790`，避免明文端口直接暴露公网。

### 方式一：nohup（最简单）

```bash
cd /opt/qqpa-server   # Server 目录所在位置
nohup python3 server.py --host 127.0.0.1 --port 8790 > billing.log 2>&1 &
echo $! > billing.pid  # 记录 PID，方便重启
```

### 方式二：systemd（Linux 推荐）

`/etc/systemd/system/qq-billing.service`：

```ini
[Unit]
Description=QQ排程助手 Billing Server
After=network.target

[Service]
WorkingDirectory=/opt/qqpa-server
ExecStart=/usr/bin/python3 /opt/qqpa-server/server.py --host 127.0.0.1 --port 8790
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now qq-billing
sudo systemctl status qq-billing
```

### 方式三：launchd（macOS）

`~/Library/LaunchAgents/com.qqpa.billing.plist`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.qqpa.billing</string>
  <key>WorkingDirectory</key><string>/Users/you/qqpa/Server</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>server.py</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/qqpa-billing.log</string>
  <key>StandardErrorPath</key><string>/tmp/qqpa-billing.err</string>
</dict>
</plist>
```

```bash
launchctl load ~/Library/LaunchAgents/com.qqpa.billing.plist
```

### 反向代理示例（Caddy，自动 HTTPS）

```
billing.example.com {
    reverse_proxy 127.0.0.1:8790
}
```

Nginx 同理：`proxy_pass http://127.0.0.1:8790;` 并保留 `X-Forwarded-For` 头（服务端用它做注册限速的 IP 识别）。

### 防火墙提示

- 云厂商安全组：只放行 80/443（反代）与 SSH；如坚持直连，再放行 `8790/tcp`（如 `ufw allow 8790/tcp`）。
- 强烈建议：`server.json` 的 `host` 保持 `127.0.0.1`，由反代对外提供 HTTPS；或干脆不暴露公网，用 SSH 隧道管理后台。

## 接入真实支付（预留点）

当前版本为「卡密兑换」售卖制，真实支付网关未接入，但已预留标准接入点，接入时**不需要改动加时长与记账逻辑**：

- 打开 `Server/server.py`，搜索 **`PAY-GATEWAY`**（共两处）：
  1. `Database.add_paid_days()` —— 统一的加时长函数（滑动叠加），并说明接入步骤；
  2. `BillingHandler._handle_redeem()` —— 卡密兑换入口，旁边即是支付回调应复用的逻辑。
- 接入支付宝当面付 / 微信 Native 的推荐做法：
  1. 新增 `POST /api/order`：按 `GET /api/plans` 的价格生成订单，返回二维码/支付链接；
  2. 支付网关**异步回调**（务必验签）确认支付成功后，调用
     `add_paid_days(user_id, plan["days"], f"{plan['name']}会员", is_purchase=True)`，
     并向 `redemptions` 表写入一条记录（`code` 字段存订单号，如 `PAY-20260925-xxx`）；
     —— 这与卡密兑换走的是同一段加时长与收入记账逻辑，后台统计自动包含真实支付收入；
  3. 客服补单（`/api/admin/users/grant`）内部同样调用 `add_paid_days`，三个入口一套逻辑。

## 数据备份与恢复

所有业务数据都在一个 SQLite 文件里：

```bash
# 方法一：停服后直接拷贝
cp Server/data/billing.sqlite3 /backup/billing-$(date +%F).sqlite3

# 方法二：不停服，用 SQLite 在线备份（WAL 模式推荐）
sqlite3 Server/data/billing.sqlite3 ".backup '/backup/billing-$(date +%F).sqlite3'"
```

> 注意：服务运行时目录里还会有 `billing.sqlite3-wal` / `-shm` 临时文件；不要只拷 `-wal` 文件，用上面 `.backup` 方式最稳妥。恢复 = 停服 → 用备份覆盖 `billing.sqlite3` → 启动。可配合 crontab 每日自动备份。

## 安全说明

- 密码：PBKDF2-SHA256，200,000 次迭代 + 每用户随机盐；管理密码哈希存于 `server.json`（权限 600）。
- 会话：token 用 `secrets.token_urlsafe(32)` 生成，库里只存 sha256 摘要；比较使用 `hmac.compare_digest`。
- 防爆破：登录连错 5 次锁 15 分钟（按账号）；注册每 IP 每小时 10 次；管理登录同样限速（按 IP）。
- 管理会话 12 小时滑动续期，服务重启后需重新登录。
- 建议：生产环境务必上 HTTPS；`server.json` 与 `data/` 不要提交到仓库；定期备份。

## 冒烟测试

```bash
cd Server
bash smoke_test.sh
```

脚本会用**随机端口 + 临时数据目录**启动服务端，自动走通：管理登录 → 批量生成 3 张月卡 → 注册送试用 → `/api/me` → 兑换（时长 +30 天）→ 重复兑换 / 不存在卡密 / 错误密码 / 未带 token / 禁用账号等错误分支 → 管理统计对账 → 登录连错 5 次锁定，全部通过时输出 `ALL PASS`。

## 常见问题

- **端口被占用**：`lsof -i :8790` 找到占用进程，或改 `server.json` 的 `port`。
- **忘记管理密码**：删除 `server.json` 重启（用户数据不受影响）。
- **换机器迁移**：拷贝整个 `Server/` 目录（含 `server.json` 与 `data/`）即可。
- **想把试用关掉**：`server.json` 里 `trial_days` 改为 `0`。
