#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
QQ排程助手 · 商业化服务端（单文件，纯 Python 3 标准库，零 pip 依赖）

功能总览
  - 用户注册 / 登录 / 登出 / 会话（Bearer token，滑动续期）
  - 新用户注册自动赠送试用（trial_days 可配置、可关闭）
  - 卡密批量生成 / 兑换 / 列表 / CSV 导出（管理员）
  - 管理后台：统计概览、用户管理（搜索/禁用/补时长）、卡密管理、兑换记录
  - 官网落地页 + 管理后台单页应用（Server/www/ 下静态 HTML）

启动
  python3 server.py                      # 使用 Server/server.json 配置（首次自动生成）
  python3 server.py --port 9000          # 临时改端口
  python3 server.py --config /tmp/x.json --data-dir /tmp/xdata   # 测试用

文件位置
  配置  Server/server.json     （首次运行自动生成；admin 初始口令不再打印到控制台，见下）
  数据  Server/data/billing.sqlite3 （SQLite, WAL 模式，首次运行自动建表）
  口令  <data-dir>/admin-initial-password.txt （首次初始化时写入，权限 0600，读取后请删除）

管理口令的三种取法（默认不再把明文打进 stdout —— 那会被 `> billing.log 2>&1` 留档）
  1) 首次自动生成：读 <data-dir>/admin-initial-password.txt，读完即删；
  2) 无人值守部署：启动前 export QQPA_ADMIN_PASSWORD=<口令>（口令不落任何文件/日志）；
  3) 本机调试：export QQPA_PRINT_ADMIN_PASSWORD=1 或配置 print_admin_password=true，
     仍只在本次控制台打印一次。

安全
  - 密码 PBKDF2-SHA256 200000 次迭代 + 每用户随机盐；账号不存在时也做等量计算（防时间差枚举）
  - token 只存 sha256 摘要；口令比较使用 hmac.compare_digest
  - 登录连错 5 次锁 15 分钟（按账号）；注册每来源每小时 10 次 + 网段 + 全局上限；
    管理登录按来源 + 全局双层锁定；兑换按账号 + 按来源双层限速
  - 限速使用的来源 IP 默认只取 socket 对端地址；仅当配置 trust_proxy_headers=true 且直连对端
    属于 trusted_proxies 网段时，才按 trusted_proxy_hops 从右往左采信 X-Forwarded-For
  - HTTP 层：连接级读超时、请求体大小上限（含 chunked 解析与排空）、异常不外泄 traceback、
    并发工作线程上限、基础安全响应头、默认不发 CORS 头
  - 核销、补单、发卡、禁用/吊销、改密、审计日志均在 BEGIN IMMEDIATE 事务内提交，失败整体回滚
  - 卡密对外的 404/409 文案统一为「卡密无效」，真实原因只进后台审计（防码表枚举）
  - 传输加密【可选，默认关闭】：tls_cert_file + tls_key_file（或 --certfile/--keyfile）成对
    配置时才用 SSLContext 包住监听 socket（最低 TLS 1.2）。不配证书时行为与旧版一字不差，
    README 的 Nginx/Caddy 反代路径不受影响；配了证书却装载失败则拒绝启动，不静默降级成明文。
  - 绑定非回环地址且未启用 TLS 时启动打印显式告警（allow_public_bind=true 表示已确认知悉，
    告警收敛为一行）；任何情况下都不拦截启动，本机回环部署完全静默。

用户接口
  POST /api/change_password {old_password,new_password}（新增）：改密并吊销该账号全部
  会话，当前设备换发新 token。既有接口 /api/register|login|logout|me|redeem 的语义未变。

★ 真实支付接入预留点：全文件搜索 “PAY-GATEWAY”（见 add_paid_days 与 _handle_redeem）。
"""

import argparse
import csv
import hashlib
import hmac
import io
import ipaddress
import json
import math
import os
import re
import secrets
import socket
import sqlite3
import sys
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from http import HTTPStatus
from urllib.parse import urlparse, parse_qs

# ---------------------------------------------------------------------------
# 路径与常量
# ---------------------------------------------------------------------------

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CONFIG_PATH = os.path.join(BASE_DIR, "server.json")
DEFAULT_DATA_DIR = os.path.join(BASE_DIR, "data")
DEFAULT_WWW_DIR = os.path.join(BASE_DIR, "www")

DAY_SECONDS = 86400
PBKDF2_ITERATIONS = 200_000          # 安全要求：≥ 200000
MAX_BODY_BYTES = 1 * 1024 * 1024     # 1MB（Content-Length 与 chunked 都受此限）
TRIAL_DAYS_DEFAULT = 3
TOKEN_TTL_DAYS_DEFAULT = 30
ADMIN_SESSION_TTL = 12 * 3600        # 管理后台会话 12 小时（滑动续期）

LOGIN_MAX_FAILS = 5                  # 登录连错 5 次
LOGIN_LOCK_SECONDS = 15 * 60         # 锁 15 分钟
REGISTER_LIMIT_PER_HOUR = 10         # 注册每 IP 每小时 10 次
# --- 传输层与资源上限（可由 server.json 覆盖，均有安全默认值） ---
CONN_TIMEOUT_SECONDS = 15            # 单连接 socket 读超时（防 slowloris 挂线程）
MAX_WORKERS = 64                     # 并发工作线程上限
WORKER_ACQUIRE_TIMEOUT = 5           # 线程位等待超时后直接关闭连接
CHUNK_MAX_BYTES = 64 * 1024          # 单个 chunk 扩展行/块头大小上限
ADMIN_GLOBAL_FAILS = 30              # 管理登录：全局 15 分钟内最多 30 次失败
ADMIN_GLOBAL_WINDOW = 15 * 60
LOGIN_IP_MAX_FAILS = 100             # 登录：单 IP 15 分钟内最多 100 次失败（回环部署共享 IP，取宽值）
REGISTER_GLOBAL_PER_DAY = 200        # 全局每日注册上限（防刷试用）
REDEEM_LIMIT_PER_HOUR = 20           # 兑换：每账号每小时
REDEEM_IP_LIMIT_PER_HOUR = 60        # 兑换：每来源每小时
CHPASSWD_LIMIT_PER_HOUR = 10         # 改密：每账号每小时（限制旧口令的在线猜测次数）
LIMITER_MAX_KEYS = 20000             # 限速表条目上限，超限按最旧淘汰（防内存型 DoS）
LIMITER_TTL_SECONDS = 2 * 3600       # 限速表条目静默 2 小时后回收
MAX_QUERY_VALUE_LEN = 64             # q / status 等查询参数长度上限
MAX_NOTE_LEN = 200                   # 备注类字段长度上限
MAX_PASSWORD_LEN = 256               # 口令长度上限（避免 1MB 口令拖垮 PBKDF2）
TRUSTED_PROXY_CIDRS_DEFAULT = ["127.0.0.0/8", "::1"]

ACCOUNT_RE = re.compile(r"^[A-Za-z0-9_@.]{4,40}$")
# 卡密字符集：去掉易混淆的 0/O/1/I/L
CODE_ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"
# 严格格式（本服务端 gen_code 的产物）
CODE_STRICT_RE = re.compile(
    r"^QP-[A-Z]-(?:[%s]{4})-(?:[%s]{4})$" % (CODE_ALPHABET, CODE_ALPHABET))
# 宽松格式：形状合法但可能来自外部导入的历史卡密（向后兼容，仍禁止超长/非法字符）
CODE_LOOSE_RE = re.compile(r"^[A-Z0-9][A-Z0-9_-]{5,23}$")

# 日志脱敏：这些查询参数只记录长度与前缀
SENSITIVE_QUERY_KEYS = ("q", "code", "account", "password", "status")


DEFAULT_PLANS = [
    {"id": "month",   "name": "月卡", "days": 30,  "price_fen": 990,
     "tagline": "30 天会员 · 当前优惠价"},
    {"id": "quarter", "name": "季卡", "days": 90,  "price_fen": 2690,
     "tagline": "90 天会员 · 折合约 ¥8.97/月"},
    {"id": "year",    "name": "年卡", "days": 365, "price_fen": 9900,
     "tagline": "365 天会员 · 折合 ¥8.25/月 · 最划算"},
]


class ApiError(Exception):
    """业务错误：status 为 HTTP 状态码，code 为机器可读错误码（可省略）。"""

    def __init__(self, status, message, code=None):
        super().__init__(message)
        self.status = status
        self.message = message
        self.code = code


# ---------------------------------------------------------------------------
# 通用小工具
# ---------------------------------------------------------------------------

def now_i():
    return int(time.time())


def sha256_hex(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def hash_password(password, salt=None):
    """PBKDF2-SHA256；salt 为 hex 字符串；返回 (hash_hex, salt_hex)。"""
    salt = salt or secrets.token_hex(16)
    dk = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"),
                             bytes.fromhex(salt), PBKDF2_ITERATIONS)
    return dk.hex(), salt


def verify_password(password, salt_hex, expected_hex):
    dk = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"),
                             bytes.fromhex(salt_hex), PBKDF2_ITERATIONS)
    return hmac.compare_digest(dk.hex(), expected_hex)


# 3-05：账号不存在时也要做同样代价的 PBKDF2，否则响应时间差本身就是「账号存在性预言机」。
# 模块加载时算一次即可（迭代数与真实校验完全一致）。
DUMMY_SALT = secrets.token_hex(16)
_, DUMMY_HASH = hash_password(secrets.token_urlsafe(12), DUMMY_SALT)


def verify_account_password(row, password):
    """恒定代价校验：无论账号是否存在都执行一次 PBKDF2 + 常量时间比较。"""
    salt = row["password_salt"] if row is not None else DUMMY_SALT
    expect = row["password_hash"] if row is not None else DUMMY_HASH
    ok = False
    try:
        ok = verify_password(password, salt, expect)
    except (ValueError, TypeError):
        ok = False          # 库里盐被手工改坏：同样按「验证失败」处理
    return ok and row is not None



def fmt_ts(ts):
    if not ts:
        return "-"
    try:
        return datetime.fromtimestamp(int(ts)).strftime("%Y-%m-%d %H:%M:%S")
    except (ValueError, OverflowError, OSError):
        return "-"


def fmt_ts_utc(ts):
    """UTC ISO8601（带 Z）展示串：授权判定一律用 epoch 秒，本函数仅用于展示，
    不受部署机时区影响，避免跨时区部署时人工核对出现歧义。"""
    if not ts:
        return "-"
    try:
        return datetime.fromtimestamp(int(ts), timezone.utc).strftime(
            "%Y-%m-%dT%H:%M:%SZ")
    except (ValueError, OverflowError, OSError):
        return "-"


def price_display(fen):
    fen = int(fen)
    if fen % 100 == 0:
        return "¥%d" % (fen // 100)
    return "¥%.2f" % (fen / 100.0)


def days_left_of(paid_until, now=None):
    """剩余天数（向上取整），未开通/已过期返回 0。"""
    now = now_i() if now is None else now
    if not paid_until or paid_until <= now:
        return 0
    return max(1, int(math.ceil((paid_until - now) / float(DAY_SECONDS))))


def plan_letter(plan_id):
    """由档位 id 推导卡密前缀字母：month→M，quarter→Q，year→Y。"""
    for ch in str(plan_id).upper():
        if ch in CODE_ALPHABET:
            return ch
    return "X"


def gen_code(letter):
    """生成 QP-M-XXXX-XXXX 格式卡密（无歧义字符集，secrets 加密随机）。"""
    g1 = "".join(secrets.choice(CODE_ALPHABET) for _ in range(4))
    g2 = "".join(secrets.choice(CODE_ALPHABET) for _ in range(4))
    return "QP-%s-%s-%s" % (letter, g1, g2)


def _gen_admin_password():
    """生成易读、无歧义的管理员初始密码。"""
    alphabet = "ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789"
    return "".join(secrets.choice(alphabet) for _ in range(14))


def parse_ip(text):
    """把字符串解析为 ipaddress 对象；非法返回 None。"""
    try:
        return ipaddress.ip_address(str(text).strip())
    except (ValueError, TypeError):
        return None


def is_loopback_host(host):
    ip = parse_ip(host)
    if ip is not None:
        return ip.is_loopback
    return str(host).strip().lower() in ("localhost", "::1")


def cidr_list_matches(ip_obj, cidrs):
    """来源 IP 是否落在给定网段（CIDR 字符串列表）内。解析失败的网段忽略。"""
    if ip_obj is None:
        return False
    for raw in cidrs or []:
        try:
            net = ip_network(str(raw))
        except (ValueError, TypeError):
            continue
        if ip_obj.version != net.version:
            continue
        if ip_obj in net:
            return True
    return False


def ip_network(raw):
    return ipaddress.ip_network(raw, strict=False)


def ip_bucket(ip_text, prefixlen_v4=24, prefixlen_v6=64):
    """把 IP 聚合到网段键（用于 /24 维度的限速），非法输入归入 'unknown'。"""
    ip = parse_ip(ip_text)
    if ip is None:
        return "unknown"
    plen = prefixlen_v4 if ip.version == 4 else prefixlen_v6
    try:
        return str(ipaddress.ip_network("%s/%d" % (str(ip), plen), strict=False))
    except (ValueError, TypeError):
        return "unknown"


def code_shape_ok(code, strict=None):
    """卡密格式校验。strict=True 只接受 gen_code 产物；None 时按配置，
    False 时接受宽松形状（兼容外部导入的历史卡密），但一律拒绝超长/非法字符。"""
    if not code or len(code) > 64:
        return False
    if strict is True:
        return bool(CODE_STRICT_RE.match(code))
    if CODE_STRICT_RE.match(code) or CODE_LOOSE_RE.match(code):
        return True
    return False


def clamp_text(value, max_len=MAX_QUERY_VALUE_LEN):
    """查询/字符串参数归一：转字符串、去空白、限长（防超长串污染审计表）。"""
    text = str(value if value is not None else "").strip()
    if max_len and len(text) > max_len:
        text = text[:max_len]
    return text


def redact_query(path):
    """日志脱敏：把敏感查询参数的值收敛为“前 4 字符 + 长度”。"""
    try:
        parsed = urlparse(path)
    except (ValueError, AttributeError):
        return "<bad-path>"
    if not parsed.query:
        return parsed.path
    try:
        qs = parse_qs(parsed.query, keep_blank_values=True)
    except (ValueError, TypeError):
        return parsed.path
    parts = []
    for key in sorted(qs):
        vals = qs[key]
        joined = ",".join(vals)
        if key.lower() in SENSITIVE_QUERY_KEYS:
            parts.append("%s=%s*(len=%d)" % (key, joined[:4], len(joined)))
        else:
            parts.append("%s=%s" % (key, joined[:64]))
    return "%s?%s" % (parsed.path, "&".join(parts))


def like_escape(text):
    """LIKE 通配符转义（配合 SQL 尾部 ESCAPE '\\'），防止 % / _ 绕过筛选意图。"""
    return (str(text).replace("\\", "\\\\").replace("%", "\\%")
            .replace("_", "\\_"))


def safe_int(value, default=0, minimum=None, maximum=None):
    """宽松取整：非法/越界回落到 default（配置容错用）。"""
    try:
        num = int(value)
    except (TypeError, ValueError):
        return default
    if minimum is not None and num < minimum:
        return minimum
    if maximum is not None and num > maximum:
        return maximum
    return num


def code_status_label(status):
    """卡密状态展示串。新增 void，但 unused/used 的文案一字不动（后台页面/脚本依赖）。"""
    if status == "used":
        return "已使用"
    if status == "void":
        return "已作废"
    return "未使用"


def csv_safe_cell(value):
    """Excel 公式注入缓解：以 = + - @ 开头的单元格加前缀 '（导出场景）。"""
    text = "" if value is None else str(value)
    if text[:1] in ("=", "+", "-", "@", "\t"):
        return "'" + text
    return text


LOG_QUERY_RE = re.compile(r"\?[^\s]*")
EXC_SUMMARY_MAX = 160


def exc_summary(exc):
    """异常日志卫生：只留「类名: 单行消息（截断）」，绝不打印栈（栈里可能带请求内容），
    也不做 %r —— 某些异常（如 int('<用户输入>') 的 ValueError）会把原始入参回显进日志，
    而本服务的日志按 README 是被重定向长期留档的。"""
    if exc is None:
        return "-"
    try:
        message = " ".join(str(exc).split())
    except Exception:   # noqa: BLE001 极端对象（__str__ 自身抛错）
        message = ""
    message = redact_log_line(message)[:EXC_SUMMARY_MAX]
    name = exc.__class__.__name__
    return "%s: %s" % (name, message) if message else name


def redact_log_line(text):
    """BaseHTTPRequestHandler 的 log_request 会把整条请求行（含查询串）交进来；
    这里统一做脱敏 + 限长，避免卡密/账号片段长期堆在日志文件里（3-12）。
    只替换 `?` 到该段结束之间的查询串，方法与协议版本等结构性信息保留。"""
    text = str(text)
    match = LOG_QUERY_RE.search(text)
    if match:
        query = text[match.start() + 1:match.end()]
        suffix = "?[redacted qs len=%d]" % len(query)
        text = text[:match.start()] + suffix + text[match.end():]
    if len(text) > 300:
        text = text[:300] + "…"
    return text



# ---------------------------------------------------------------------------
# 错误与响应约定
# ---------------------------------------------------------------------------

# 对外统一文案：卡密存在性与“已被使用”不再可被外部区分（用户枚举预言机，见 3-04）。
CODE_INVALID_PUBLIC_MESSAGE = "卡密无效，请核对后重新输入"
CODE_INVALID_PUBLIC_ERROR_CODE = "CODE_INVALID"
# 禁用账号的唯一对外文案：登录 / /api/me / 兑换 / 补单 共用同一口径（3-07 判定一致）
DISABLED_MESSAGE = "账号已被禁用，请联系管理员"


# ---------------------------------------------------------------------------
# 配置（Server/server.json）
# ---------------------------------------------------------------------------

ADMIN_PASSWORD_ENV = "QQPA_ADMIN_PASSWORD"          # 显式注入管理口令（不落日志）
ADMIN_PRINT_ENV = "QQPA_PRINT_ADMIN_PASSWORD"       # 仅在开发机终端上允许打印一次
ADMIN_PASSWORD_FILENAME = "admin-initial-password.txt"

# 配置里允许的键（未知键只告警，不报错，保持向后兼容）
KNOWN_CONFIG_KEYS = {
    "host", "port", "trial_days", "token_ttl_days", "plans",
    "admin_password_hash", "admin_password_salt",
    "trust_proxy_headers", "trusted_proxies", "trusted_proxy_hops",
    "allow_public_bind", "allowed_hosts", "enforce_code_format", "code_format_strict",
    "unified_redeem_error", "revoke_sessions_on_disable", "print_admin_password",
    "require_json_content_type", "tls_cert_file", "tls_key_file",
    "conn_timeout_seconds", "max_workers", "max_body_bytes", "cors_allow_origin",
    "register_limit_per_hour", "register_global_per_day", "redeem_limit_per_hour",
    "redeem_ip_limit_per_hour", "admin_global_fails", "login_ip_max_fails",
    "chpasswd_limit_per_hour",
    "max_codes_per_batch", "log_client_ip",
}


def _admin_password_file_path(data_dir):
    return os.path.join(data_dir, ADMIN_PASSWORD_FILENAME)


def _write_admin_password_file(data_dir, password):
    """一次性口令写进 0600 文件，不再进 stdout（stdout 会被 README 的
    `> billing.log 2>&1` / launchd StandardOutPath 落盘成全局可读日志）。"""
    try:
        os.makedirs(data_dir, exist_ok=True)
        path = _admin_password_file_path(data_dir)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(password)
            f.write("\n")
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass
        return path
    except OSError as exc:
        sys.stderr.write("[warn] 管理员初始口令文件写入失败：%r\n" % (exc,))
        return None


def load_or_create_config(path, default_host="127.0.0.1", default_port=8790,
                          data_dir=DEFAULT_DATA_DIR):
    """读取配置；文件不存在则生成默认配置。

    管理员初始口令的处理（3-08）：
      - 默认【不打印】口令，改为写入 <data-dir>/admin-initial-password.txt（0600）；
      - 需要无人值守部署：设环境变量 QQPA_ADMIN_PASSWORD=<口令>（或配置
        print_admin_password=true / QQPA_PRINT_ADMIN_PASSWORD=1 时只在本次控制台输出）。
    """
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as f:
            cfg = json.load(f)
        changed = False
        cfg.setdefault("host", default_host)
        cfg.setdefault("port", default_port)
        cfg.setdefault("trial_days", TRIAL_DAYS_DEFAULT)
        cfg.setdefault("token_ttl_days", TOKEN_TTL_DAYS_DEFAULT)
        if not cfg.get("plans"):
            cfg["plans"] = [dict(p) for p in DEFAULT_PLANS]
            changed = True
        if not cfg.get("admin_password_hash") or not cfg.get("admin_password_salt"):
            cfg.update(_bootstrap_admin_credentials(cfg, data_dir,
                                                    default_host, default_port))
            changed = True
        if changed:
            _save_config(cfg, path)
        return cfg

    # 首次运行：生成管理员凭据
    salt = secrets.token_hex(16)
    cfg = {
        "host": default_host,
        "port": default_port,
        "trial_days": TRIAL_DAYS_DEFAULT,
        "token_ttl_days": TOKEN_TTL_DAYS_DEFAULT,
        "admin_password_salt": salt,
        "plans": [dict(p) for p in DEFAULT_PLANS],
    }
    cfg.update(_bootstrap_admin_credentials(cfg, data_dir, default_host, default_port))
    _save_config(cfg, path)
    return cfg


def _bootstrap_admin_credentials(cfg, data_dir, host, port):
    """生成（或接收）管理员口令，并返回 hash/salt；口令本身绝不写日志。"""
    env_pw = os.environ.get(ADMIN_PASSWORD_ENV) or ""
    if env_pw:
        if len(env_pw) < 10:
            sys.stderr.write("[warn] %s 长度不足 10 位，仍按注入值初始化\n"
                             % ADMIN_PASSWORD_ENV)
        password = env_pw
        source = "环境变量 %s" % ADMIN_PASSWORD_ENV
    else:
        password = _gen_admin_password()
        source = None

    salt = cfg.get("admin_password_salt") or secrets.token_hex(16)
    pw_hash, salt = hash_password(password, salt)

    if not source:
        # 首次自动生成：口令落到 0600 文件，控制台只提示路径
        path = _write_admin_password_file(data_dir, password)
        source = "文件 %s" % path if path else "（写入失败，请改用 %s 注入）" % ADMIN_PASSWORD_ENV
    # 配了证书就不能再告诉运维 http:// 地址（3-19）
    scheme = "https" if clamp_text(cfg.get("tls_cert_file", ""), 512) else "http"
    if _should_print_admin_password(cfg):
        _print_admin_password_banner(password, host, port, scheme=scheme)
    else:
        _print_admin_password_banner(None, host, port, source, scheme=scheme)
    return {"admin_password_hash": pw_hash, "admin_password_salt": salt}


def _should_print_admin_password(cfg):
    """只有显式开启（配置或环境变量）才把口令打到 stdout —— 该通道会被日志重定向留档。"""
    if cfg and cfg.get("print_admin_password") in (True, 1, "1", "true", "True"):
        return True
    return (os.environ.get(ADMIN_PRINT_ENV) or "").strip() in ("1", "true", "yes", "on")


def _print_admin_password_banner(password, host, port, source=None, scheme="http"):
    print("=" * 64)
    print("  [QQ排程助手] 首次初始化完成，已生成管理员凭据")
    print()
    print("  管理后台地址: %s://%s:%s/admin" % (scheme, host, port))
    if password:
        # 仅开发机显式开启时可达；生产默认走下面的“不打印”分支
        print("  管理员初始密码: %s" % password)
        print("  ※ 已按 print_admin_password/QQPA_PRINT_ADMIN_PASSWORD 打印，"
              "请确认 stdout 未被重定向到日志文件。")
    else:
        print("  管理员初始密码: 未打印（避免明文落进重定向日志）")
        print("  取回方式      : %s" % (source or "见 %s" % ADMIN_PASSWORD_FILENAME))
        print("  ※ 读取后立即删除该文件；或在部署时直接用 %s 注入口令。"
              % ADMIN_PASSWORD_ENV)
    print()
    print("  ※ 忘记密码：删除 server.json 后重启即重置（用户数据不受影响）。")
    print("=" * 64)
    sys.stdout.flush()


def sanitize_plans(raw_plans):
    """档位校验（3-10）：返回 (problems, 合法档位列表)。

    规则集中在这里，`validate_config`（启动时）与 `/api/plans`（运行时）用同一口径，
    坏条目剔除而不是让整个公开接口 500；全空时回退默认三档。
    独立成函数还有一层意义：/api/plans 不必每个请求都跑一遍完整配置校验
    （那会连带 tls_* 文件的存在性检查，即每次请求两遍磁盘 stat）。
    """
    problems = []
    if raw_plans is None:
        raw_plans = DEFAULT_PLANS
    if not isinstance(raw_plans, list):
        problems.append("plans 必须是数组，已回退为默认三档")
        return problems, [dict(p) for p in DEFAULT_PLANS]
    good = []
    seen_ids = set()
    for idx, p in enumerate(raw_plans):
        where = "plans[%d]" % idx
        if not isinstance(p, dict):
            problems.append("%s 不是对象，已剔除" % where)
            continue
        pid = clamp_text(p.get("id"), 32)
        name = clamp_text(p.get("name"), 32)
        if not pid:
            problems.append("%s.id 缺失或非法，已剔除" % where)
            continue
        if pid in seen_ids:
            problems.append("%s.id='%s' 重复，已剔除后者" % (where, pid))
            continue
        days = p.get("days")
        if not isinstance(days, int) or isinstance(days, bool) or not 1 <= days <= 3650:
            problems.append("%s.days=%r 需为 1-3650 的整数，已剔除该档位"
                            % (where, days))
            continue
        fen = p.get("price_fen")
        if not isinstance(fen, int) or isinstance(fen, bool) or not 0 <= fen <= 100000000:
            problems.append("%s.price_fen=%r 需为 0-100000000 的整数（单位：分），"
                            "已剔除该档位" % (where, fen))
            continue
        seen_ids.add(pid)
        entry = {"id": pid, "name": name or pid, "days": days, "price_fen": fen}
        tagline = p.get("tagline")
        entry["tagline"] = clamp_text(tagline, 80) if isinstance(tagline, str) else ""
        good.append(entry)
    if not good:
        problems.append("plans 无任何有效档位，已回退为默认三档")
        good = [dict(p) for p in DEFAULT_PLANS]
    return problems, good


def validate_config(cfg):
    """返回 (problems, sanitized_cfg)。

    不直接抛异常：部署现场多为用户手改 plans 改价（README 鼓励），一处笔误就让
    /api/plans 全部 500 的代价更高。非法项逐条打印【带字段名】的告警，并在运行时
    使用安全回退值。
    """
    problems = []
    if not isinstance(cfg, dict):
        return (["配置根节点必须是 JSON 对象"], {})
    for key in sorted(set(cfg.keys()) - KNOWN_CONFIG_KEYS):
        problems.append("未知配置项 '%s'（已忽略，请核对拼写）" % key)

    out = dict(cfg)
    out["port"] = safe_int(cfg.get("port", 8790), 8790, 1, 65535)
    out["host"] = clamp_text(cfg.get("host", "127.0.0.1"), 64) or "127.0.0.1"
    out["trial_days"] = safe_int(cfg.get("trial_days", TRIAL_DAYS_DEFAULT),
                                 TRIAL_DAYS_DEFAULT, 0, 3650)
    if "trial_days" in cfg and cfg.get("trial_days") != out["trial_days"]:
        problems.append("trial_days=%r 不是 0-3650 的整数，已回退为 %d"
                        % (cfg.get("trial_days"), out["trial_days"]))
    out["token_ttl_days"] = safe_int(cfg.get("token_ttl_days", TOKEN_TTL_DAYS_DEFAULT),
                                     TOKEN_TTL_DAYS_DEFAULT, 0, 3650)
    if "token_ttl_days" in cfg and cfg.get("token_ttl_days") != out["token_ttl_days"]:
        problems.append("token_ttl_days=%r 非法，已回退为 %d"
                        % (cfg.get("token_ttl_days"), out["token_ttl_days"]))

    # plans：逐字段校验，坏条目剔除（不让 KeyError/ValueError 冒到公开接口）
    plan_problems, out["plans"] = sanitize_plans(cfg.get("plans"))
    problems.extend(plan_problems)

    if not out.get("admin_password_hash") or not out.get("admin_password_salt"):
        problems.append("缺少 admin_password_hash/salt，首次启动会自动生成")

    # 反代与网络面
    out["trust_proxy_headers"] = bool_in(cfg.get("trust_proxy_headers", False))
    hops = safe_int(cfg.get("trusted_proxy_hops", 1), 1, 1, 8)
    out["trusted_proxy_hops"] = hops
    proxies = cfg.get("trusted_proxies")
    if proxies is None:
        out["trusted_proxies"] = list(TRUSTED_PROXY_CIDRS_DEFAULT)
    elif isinstance(proxies, list):
        bad = [str(x) for x in proxies if not _cidr_parseable(str(x))]
        if bad:
            problems.append("trusted_proxies 含非法网段 %s，已忽略该项" % ", ".join(bad))
        out["trusted_proxies"] = [str(x) for x in proxies if _cidr_parseable(str(x))]
        if not out["trusted_proxies"]:
            out["trusted_proxies"] = list(TRUSTED_PROXY_CIDRS_DEFAULT)
    else:
        problems.append("trusted_proxies 必须是数组，已回退为默认回环网段")
        out["trusted_proxies"] = list(TRUSTED_PROXY_CIDRS_DEFAULT)

    for key, default, lo, hi in (
            ("conn_timeout_seconds", CONN_TIMEOUT_SECONDS, 3, 300),
            ("max_workers", MAX_WORKERS, 4, 512),
            ("max_body_bytes", MAX_BODY_BYTES, 1024, 16 * 1024 * 1024),
            ("register_limit_per_hour", REGISTER_LIMIT_PER_HOUR, 1, 10000),
            ("register_global_per_day", REGISTER_GLOBAL_PER_DAY, 1, 100000),
            ("redeem_limit_per_hour", REDEEM_LIMIT_PER_HOUR, 1, 10000),
            ("redeem_ip_limit_per_hour", REDEEM_IP_LIMIT_PER_HOUR, 1, 100000),
            ("admin_global_fails", ADMIN_GLOBAL_FAILS, 1, 10000),
            ("login_ip_max_fails", LOGIN_IP_MAX_FAILS, 1, 100000),
            ("chpasswd_limit_per_hour", CHPASSWD_LIMIT_PER_HOUR, 1, 10000),
            ("max_codes_per_batch", 500, 1, 500)):
        val = safe_int(cfg.get(key, default), default, lo, hi)
        if key in cfg and cfg.get(key) is not None and cfg.get(key) != val:
            problems.append("配置项 %s=%r 越界/非法，已使用 %d" % (key, cfg.get(key), val))
        out[key] = val

    for key in ("enforce_code_format", "code_format_strict", "unified_redeem_error",
                "revoke_sessions_on_disable", "allow_public_bind", "log_client_ip"):
        out[key] = bool_in(cfg.get(key, False))
    out["enforce_code_format"] = bool_in(cfg.get("enforce_code_format", True))
    out["unified_redeem_error"] = bool_in(cfg.get("unified_redeem_error", True))
    # 老客户端（License.swift / admin.html）本来就带 application/json，默认开启；
    # 若有第三方脚本用 form-urlencoded，可在配置里关掉这一项。
    out["require_json_content_type"] = bool_in(cfg.get("require_json_content_type", True))

    hosts = cfg.get("allowed_hosts")
    out["allowed_hosts"] = ([clamp_text(h, 120) for h in hosts if clamp_text(h, 120)]
                            if isinstance(hosts, list) else [])
    origin = clamp_text(cfg.get("cors_allow_origin", ""), 200)
    if origin == "*":
        problems.append("cors_allow_origin='*' 过宽，已禁用 CORS（保持默认无跨域）")
        origin = ""
    out["cors_allow_origin"] = origin

    # 可选 TLS：不配证书时完全不启用，行为与旧版本一致
    cert = clamp_text(cfg.get("tls_cert_file", ""), 512)
    key = clamp_text(cfg.get("tls_key_file", ""), 512)
    if cert and not os.path.exists(cert):
        problems.append("tls_cert_file=%r 不存在，已退回明文 HTTP（请检查路径）" % cert)
        cert = ""
    if key and not os.path.exists(key):
        problems.append("tls_key_file=%r 不存在，已退回明文 HTTP" % key)
        key = ""
    if bool(cert) != bool(key):
        problems.append("tls_cert_file 与 tls_key_file 需成对配置，已退回明文 HTTP")
        cert = key = ""
    out["tls_cert_file"], out["tls_key_file"] = cert, key
    return (problems, out)



def _cidr_parseable(raw):
    try:
        ipaddress.ip_network(raw, strict=False)
    except (ValueError, TypeError):
        return False
    return True


def bool_in(value):
    return value in (True, 1, "1", "true", "True", "yes", "on")


def _save_config(cfg, path):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
        f.write("\n")
    try:
        os.chmod(path, 0o600)  # 含密码哈希，收紧文件权限
    except OSError:
        pass


# ---------------------------------------------------------------------------
# 数据库（SQLite + WAL）
# ---------------------------------------------------------------------------

class Database:
    """SQLite 访问层。

    线程模型（ThreadingHTTPServer 每请求一线程）：
      - `self.conn` 是唯一的【写连接】，所有写操作（含事务）都在 `self.lock` 内串行；
      - 读操作走【线程本地连接】，WAL 允许读写并发，避免「批量发卡/长事务」把只读接口
        （/api/me、/api/admin/*）一起堵死；
      - 事务型写（redeem_code / grant_days / generate_codes / set_user_disabled）一律
        `BEGIN IMMEDIATE` + 失败 rollback，跨进程同样安全。
    """

    def __init__(self, data_dir, conn_path=None):
        os.makedirs(data_dir, exist_ok=True)
        self.path = conn_path or os.path.join(data_dir, "billing.sqlite3")
        self.conn = self._connect(self.path)
        self.conn.row_factory = sqlite3.Row
        # 写连接全局锁：RLock 允许 handler 在外层已持锁时重入（如批量生成）
        self.lock = threading.RLock()
        self._local = threading.local()
        self._read_conns = []
        self._read_conns_guard = threading.Lock()
        with self.lock:
            self.conn.execute("PRAGMA journal_mode=WAL")
            self.conn.execute("PRAGMA synchronous=NORMAL")
            self.conn.executescript("""
                CREATE TABLE IF NOT EXISTS users (
                    id            INTEGER PRIMARY KEY AUTOINCREMENT,
                    account       TEXT    NOT NULL UNIQUE,
                    password_hash TEXT    NOT NULL,
                    password_salt TEXT    NOT NULL,
                    paid_until    INTEGER,                      -- 会员到期时间戳（含试用）；NULL=未开通
                    ever_paid     INTEGER NOT NULL DEFAULT 0,   -- 是否开通过付费会员（决定 source）
                    plan_label    TEXT,                         -- 最近一次开通的会员标签
                    disabled      INTEGER NOT NULL DEFAULT 0,
                    created_at    INTEGER NOT NULL,
                    updated_at    INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS tokens (
                    token_hash TEXT PRIMARY KEY,              -- 只存 sha256(token)
                    user_id    INTEGER NOT NULL,
                    expires_at INTEGER NOT NULL,
                    created_at INTEGER NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_tokens_user ON tokens(user_id);
                CREATE INDEX IF NOT EXISTS idx_tokens_expire ON tokens(expires_at);
                CREATE TABLE IF NOT EXISTS codes (
                    id         INTEGER PRIMARY KEY AUTOINCREMENT,
                    code       TEXT    NOT NULL UNIQUE,
                    plan_id    TEXT    NOT NULL,
                    plan_name  TEXT    NOT NULL,
                    days       INTEGER NOT NULL,
                    price_fen  INTEGER NOT NULL,
                    note       TEXT    DEFAULT '',
                    batch_id   TEXT    DEFAULT '',
                    status     TEXT    NOT NULL DEFAULT 'unused',  -- unused / used / void
                    created_at INTEGER NOT NULL,
                    used_by    INTEGER,
                    used_at    INTEGER
                );
                CREATE INDEX IF NOT EXISTS idx_codes_status ON codes(status);
                CREATE TABLE IF NOT EXISTS redemptions (
                    id         INTEGER PRIMARY KEY AUTOINCREMENT,
                    user_id    INTEGER NOT NULL,
                    account    TEXT    NOT NULL,
                    code       TEXT    NOT NULL,
                    plan_id    TEXT    NOT NULL,
                    plan_name  TEXT    NOT NULL,
                    days       INTEGER NOT NULL,
                    price_fen  INTEGER NOT NULL,
                    created_at INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS grants_log (
                    id         INTEGER PRIMARY KEY AUTOINCREMENT,
                    user_id    INTEGER NOT NULL,
                    account    TEXT    NOT NULL,
                    days       INTEGER NOT NULL,
                    note       TEXT    DEFAULT '',
                    created_at INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS admin_audit (
                    id         INTEGER PRIMARY KEY AUTOINCREMENT,
                    action     TEXT    NOT NULL,
                    user_id    INTEGER,
                    account    TEXT    DEFAULT '',
                    detail     TEXT    DEFAULT '',
                    origin     TEXT    DEFAULT '',      -- 脱敏后的来源标识（IP 或 'system'）
                    created_at INTEGER NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_audit_created ON admin_audit(created_at);
            """)
            self.conn.commit()

    @staticmethod
    def _connect(path):
        """每连接都要显式设 busy_timeout：多进程/多连接并发时避免直接抛 locked 变 500。"""
        conn = sqlite3.connect(path, check_same_thread=False, timeout=5.0)
        conn.row_factory = sqlite3.Row
        try:
            conn.execute("PRAGMA busy_timeout=5000")
        except sqlite3.Error:
            pass
        return conn

    def read_conn(self):
        """线程本地只读连接：WAL 下读不再排在写锁后面。"""
        conn = getattr(self._local, "conn", None)
        if conn is None:
            conn = self._connect(self.path)
            try:
                conn.execute("PRAGMA query_only=ON")
            except sqlite3.Error:
                pass
            self._local.conn = conn
            with self._read_conns_guard:
                self._read_conns.append(conn)
        return conn

    def close(self):
        with self._read_conns_guard:
            for conn in self._read_conns:
                try:
                    conn.close()
                except sqlite3.Error:
                    pass
            self._read_conns = []
        try:
            self.conn.close()
        except sqlite3.Error:
            pass

    def release_read_conn(self):
        """归还【当前线程】的只读连接：ThreadingHTTPServer 是「每连接一线程」，
        线程本地连接若只在进程退出时统一 close，就会随连接数线性堆积——每个泄漏的
        读连接占一个 fd，并且各自持有 WAL 读快照，使 `billing.sqlite3-wal` 无法回收，
        长跑进程最终表现为 fd 耗尽 / WAL 无限增长。工作线程结束时必须调用本方法。

        返回 True 表示确实关闭了一条连接（测试与自检用）。"""
        conn = getattr(self._local, "conn", None)
        if conn is None:
            return False
        self._local.conn = None
        with self._read_conns_guard:
            try:
                self._read_conns.remove(conn)
            except ValueError:
                pass
        try:
            conn.close()
        except sqlite3.Error:
            pass
        return True

    def integrity_notes(self):
        """数据卫生自检（3-13 的替代做法）。

        既有库补 FOREIGN KEY 需要重建全部表（SQLite 不支持 ALTER TABLE ADD
        FOREIGN KEY），而 `Server/data/` 不在本轮改动范围内，也不能假设现场有可
        回滚的备份。这里改成【只检测、只告警】：孤儿行不会造成越权——lookup_token
        走 JOIN users，孤儿天然失效——但运维应该知道库里有人手工删过用户。
        本函数不写库、不删除、不改结构，任何异常都吞掉（自检绝不能挡住启动）。
        """
        notes = []
        checks = (
            ("tokens", "SELECT COUNT(*) AS n FROM tokens t "
                       "LEFT JOIN users u ON u.id=t.user_id WHERE u.id IS NULL"),
            ("redemptions", "SELECT COUNT(*) AS n FROM redemptions r "
                             "LEFT JOIN users u ON u.id=r.user_id WHERE u.id IS NULL"),
            ("grants_log", "SELECT COUNT(*) AS n FROM grants_log g "
                           "LEFT JOIN users u ON u.id=g.user_id WHERE u.id IS NULL"),
            ("codes.used_by", "SELECT COUNT(*) AS n FROM codes c "
                              "LEFT JOIN users u ON u.id=c.used_by "
                              "WHERE c.used_by IS NOT NULL AND u.id IS NULL"),
        )
        for label, sql in checks:
            try:
                row = self.query_one(sql)
                n = row["n"] if row is not None else 0
            except sqlite3.Error:
                continue
            if n:
                notes.append("%s 表有 %d 行指向不存在的用户（不构成越权：token 反查走 "
                             "JOIN，孤儿行天然失效）。建议核对备份后手工清理。"
                             % (label, n))
        try:
            status_counts = {r["status"]: r["n"] for r in self.query_all(
                "SELECT status, COUNT(*) AS n FROM codes GROUP BY status")}
        except sqlite3.Error:
            status_counts = {}
        unknown = [k for k in status_counts if k not in ("unused", "used", "void")]
        if unknown:
            notes.append("codes.status 出现未知取值 %s（核销时按「已被使用」处理）。"
                         % ", ".join(sorted(str(k) for k in unknown)[:5]))
        return notes

    # ---- 基础封装 ----

    def execute(self, sql, params=()):
        """写：单条语句 + 立即提交。事务型业务（核销/补单/发卡）不要用本方法。"""
        with self.lock:
            cur = self.conn.execute(sql, params)
            self.conn.commit()
            return cur

    def query_all(self, sql, params=()):
        return self.read_conn().execute(sql, params).fetchall()

    def query_one(self, sql, params=()):
        return self.read_conn().execute(sql, params).fetchone()

    # ---- 事务骨架与审计 ----

    def _begin_immediate(self):
        """开启写事务；已在事务中则复用（防「cannot start a transaction within a
        transaction」）。返回 True 表示由本次调用开启，需在 finally 里负责提交/回滚。"""
        if self.conn.in_transaction:
            return False
        self.conn.execute("BEGIN IMMEDIATE")
        return True

    def audit(self, action, user_id=None, account="", detail="", origin=""):
        """写一条管理/安全审计。只负责 INSERT，事务归属由调用方决定——需要与业务变更
        同生共死的审计必须在事务内调用本方法。"""
        self.conn.execute(
            "INSERT INTO admin_audit(action,user_id,account,detail,origin,created_at)"
            " VALUES(?,?,?,?,?,?)",
            (action, user_id, clamp_text(account, 64), clamp_text(detail, 400),
             clamp_text(origin, 64), now_i()))

    def audit_event(self, action, user_id=None, account="", detail="", origin=""):
        """独立提交的审计（登录失败、注册、兑换未命中）。只用于本身已被限速的路径，
        否则会变成新的写入放大面。"""
        with self.lock:
            self.audit(action, user_id, account, detail, origin)
            self.conn.commit()


    # ---- 业务 ----

    def create_user(self, account, password, trial_days):
        now = now_i()
        pw_hash, salt = hash_password(password)
        paid_until = now + trial_days * DAY_SECONDS if trial_days and trial_days > 0 else None
        with self.lock:
            try:
                cur = self.conn.execute(
                    "INSERT INTO users(account,password_hash,password_salt,paid_until,"
                    "ever_paid,plan_label,disabled,created_at,updated_at)"
                    " VALUES(?,?,?,?,0,NULL,0,?,?)",
                    (account, pw_hash, salt, paid_until, now, now))
                self.conn.commit()
                return cur.lastrowid
            except BaseException:
                self.conn.rollback()
                raise

    def add_paid_days(self, user_id, days, plan_label, is_purchase=True):
        """给用户增加会员时长（滑动叠加：剩余时长保留，向后顺延）。

        ★ PAY-GATEWAY 支付接入预留点 ★
        接入支付宝当面付 / 微信 Native 等真实支付时：
          1. App 向本服务端发起下单（新增 /api/order 接口，返回二维码/订单号）；
          2. 支付网关回调（需验签）确认支付成功后，调用本函数：
                 add_paid_days(user_id, plan["days"], f"{plan['name']}会员", is_purchase=True)
             并向 redemptions 表写入一条记录（code 字段用订单号，如 "PAY-20260925-xxx"），
             即与卡密兑换走完全相同的加时长与收入记账逻辑（参见 _handle_redeem）；
          3. 价格口径以 GET /api/plans 返回的 price_fen 为准，前后端保持一致。

        读-改-写必须在同一写事务里（原来两条语句分属两次 autocommit，一旦与并发的
        兑换/补单交错就会丢更新）。已在事务中时复用外层事务，由外层负责提交。
        """
        with self.lock:
            own_txn = self._begin_immediate()
            try:
                row = self.conn.execute(
                    "SELECT paid_until FROM users WHERE id=?", (user_id,)).fetchone()
                if row is None:
                    raise ApiError(404, "用户不存在")
                now = now_i()
                base = max(now, row["paid_until"] or 0)
                new_until = base + int(days) * DAY_SECONDS
                self.conn.execute(
                    "UPDATE users SET paid_until=?, ever_paid=1, plan_label=?, updated_at=? WHERE id=?",
                    (new_until, plan_label, now, user_id))
                if own_txn:
                    self.conn.commit()
                return new_until
            except BaseException:
                if own_txn:
                    self.conn.rollback()
                raise

    def grant_days(self, user_id, days, plan_label, note="", origin="",
                   audit_action="admin.grant"):
        """客服补单：加时长 + grants_log 记账 + 审计，三者同一事务。

        与 redeem_code 同等强度：任何一步失败整体回滚，不会出现「时长凭空多了但没有
        工单记录」这种对账最头疼的半成品状态。
        """
        with self.lock:
            try:
                self.conn.execute("BEGIN IMMEDIATE")
                user = self.conn.execute(
                    "SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
                if user is None:
                    raise ApiError(404, "用户不存在")
                if user["disabled"]:
                    raise ApiError(403, "账号已被禁用，无法补单", code="ACCOUNT_DISABLED")
                new_until = self.add_paid_days(user_id, days, plan_label, is_purchase=True)
                now = now_i()
                self.conn.execute(
                    "INSERT INTO grants_log(user_id,account,days,note,created_at)"
                    " VALUES(?,?,?,?,?)",
                    (user_id, user["account"], int(days), clamp_text(note, MAX_NOTE_LEN), now))
                self.audit(audit_action, user_id, user["account"],
                           "days=%d;note=%s;paid_until=%d" % (int(days),
                                                              clamp_text(note, 120), new_until),
                           origin)
                updated = self.conn.execute(
                    "SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
                self.conn.commit()
                return new_until, updated
            except BaseException:
                self.conn.rollback()
                raise

    def set_user_disabled(self, user_id, flag, revoke_sessions=False, origin=""):
        """禁用/恢复 + （可选）吊销该账号全部 token + 审计，同一事务。"""
        with self.lock:
            try:
                self.conn.execute("BEGIN IMMEDIATE")
                user = self.conn.execute(
                    "SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
                if user is None:
                    raise ApiError(404, "用户不存在")
                now = now_i()
                self.conn.execute("UPDATE users SET disabled=?, updated_at=? WHERE id=?",
                                  (1 if flag else 0, now, user_id))
                revoked = 0
                if revoke_sessions:
                    cur = self.conn.execute("DELETE FROM tokens WHERE user_id=?", (user_id,))
                    revoked = cur.rowcount or 0
                self.audit("admin.user_disabled" if flag else "admin.user_enabled",
                           user_id, user["account"],
                           "revoked_tokens=%d" % revoked, origin)
                self.conn.commit()
                return user, revoked
            except BaseException:
                self.conn.rollback()
                raise

    def revoke_user_sessions(self, user_id, origin=""):
        """显式吊销某账号全部登录 token（禁用之外的独立操作，向后兼容默认不自动做）。"""
        with self.lock:
            try:
                self.conn.execute("BEGIN IMMEDIATE")
                user = self.conn.execute(
                    "SELECT account FROM users WHERE id=?", (user_id,)).fetchone()
                if user is None:
                    raise ApiError(404, "用户不存在")
                cur = self.conn.execute("DELETE FROM tokens WHERE user_id=?", (user_id,))
                revoked = cur.rowcount or 0
                self.audit("admin.revoke_sessions", user_id, user["account"],
                           "revoked_tokens=%d" % revoked, origin)
                self.conn.commit()
                return revoked
            except BaseException:
                self.conn.rollback()
                raise

    def change_password(self, user_id, new_password, origin=""):
        """改密（3-07 的「用户改密：接口不存在，旧 token 永不失效」）：
        新盐新哈希 + 吊销该账号【全部】token + 审计，同一事务；调用方随后为当前设备
        重新签发 token，其余设备一律需要重新登录。

        PBKDF2 在锁外计算：200k 次迭代约 100ms，若持着写锁做，这段时间里所有人的
        核销与 /api/me 续期都要排队。
        """
        pw_hash, salt = hash_password(new_password)      # 锁外，先算好
        with self.lock:
            try:
                self.conn.execute("BEGIN IMMEDIATE")
                user = self.conn.execute(
                    "SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
                if user is None:
                    raise ApiError(404, "用户不存在")
                self.conn.execute(
                    "UPDATE users SET password_hash=?, password_salt=?, updated_at=? WHERE id=?",
                    (pw_hash, salt, now_i(), user_id))
                cur = self.conn.execute("DELETE FROM tokens WHERE user_id=?", (user_id,))
                revoked = cur.rowcount or 0
                self.audit("user.password_changed", user_id, user["account"],
                           "revoked_tokens=%d" % revoked, origin)
                self.conn.commit()
                return user, revoked
            except BaseException:
                self.conn.rollback()
                raise

    def void_code(self, code, origin=""):
        """卡密作废（批次外泄时的止损手段）：unused → void，同事务写审计。
        已核销的码不可作废（退款回滚属于另一条迁移，见 Server/README 之外的设计文档）。"""
        normalized = clamp_text(code, 64).upper()
        with self.lock:
            try:
                self.conn.execute("BEGIN IMMEDIATE")
                row = self.conn.execute("SELECT * FROM codes WHERE code=?",
                                        (normalized,)).fetchone()
                if row is None:
                    raise ApiError(404, "卡密不存在", code="CODE_NOT_FOUND")
                if row["status"] == "void":
                    raise ApiError(409, "卡密已作废", code="CODE_VOID")
                if row["status"] != "unused":
                    raise ApiError(409, "卡密已被使用", code="CODE_USED")
                self.conn.execute("UPDATE codes SET status='void' WHERE id=? AND status='unused'",
                                  (row["id"],))
                self.audit("admin.code_void", None, "", "code=%s" % normalized, origin)
                self.conn.commit()
                return True
            except BaseException:
                self.conn.rollback()
                raise

    def generate_codes(self, plan, count, note, batch_id, origin=""):
        """整批卡密一个事务：BEGIN IMMEDIATE → 逐张 SAVEPOINT 插入（撞码只回滚到保存点）
        → 一次 commit → 审计同事务。
        原来循环内每条 INSERT 都单独 commit 且全程持有写锁，会把所有用户的 /api/me
        一起堵住；本实现只提交一次。
        """
        codes = []
        with self.lock:
            try:
                self.conn.execute("BEGIN IMMEDIATE")
                for _ in range(count):
                    made = None
                    for _attempt in range(20):
                        candidate = gen_code(plan_letter(plan["id"]))
                        self.conn.execute("SAVEPOINT gen_code")
                        try:
                            self.conn.execute(
                                "INSERT INTO codes(code,plan_id,plan_name,days,price_fen,"
                                "note,batch_id,status,created_at) VALUES(?,?,?,?,?,?,?,'unused',?)",
                                (candidate, plan["id"], plan["name"], int(plan["days"]),
                                 int(plan["price_fen"]), clamp_text(note, MAX_NOTE_LEN),
                                 batch_id, now_i()))
                        except sqlite3.IntegrityError as exc:
                            self.conn.execute("ROLLBACK TO SAVEPOINT gen_code")
                            self.conn.execute("RELEASE SAVEPOINT gen_code")
                            # 只有真正的撞码才重试；触发器/约束类失败必须冒泡，
                            # 否则一张坏表会被「重试 20 次」伪装成「生成冲突」。
                            if "unique" not in str(exc).lower():
                                raise
                            continue
                        self.conn.execute("RELEASE SAVEPOINT gen_code")
                        made = candidate
                        break
                    if made is None:
                        raise ApiError(500, "卡密生成冲突，请重试")
                    codes.append(made)
                self.audit("admin.codes_generated", None, "",
                           "count=%d;plan=%s;batch=%s" % (len(codes), plan["id"], batch_id),
                           origin)
                self.conn.commit()
                return codes
            except BaseException:
                self.conn.rollback()
                raise


    def redeem_code(self, user_id, code):
        """核销、收入记录与会员时长同事务提交；任何失败均保留卡密可重试。"""
        with self.lock:
            try:
                # 同时保护多个服务进程/连接；必须在读卡密和到期时间前取得写锁。
                self.conn.execute("BEGIN IMMEDIATE")
                user = self.conn.execute(
                    "SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
                if user is None:
                    raise ApiError(404, "用户不存在")
                if user["disabled"]:
                    raise ApiError(403, "账号已被禁用，无法兑换", code="ACCOUNT_DISABLED")
                code_row = self.conn.execute(
                    "SELECT * FROM codes WHERE code=?", (code,)).fetchone()
                if code_row is None:
                    raise ApiError(404, "卡密不存在，请检查后重试", code="CODE_NOT_FOUND")
                if code_row["status"] != "unused":
                    raise ApiError(409, "卡密已被使用", code="CODE_USED")
                now = now_i()
                claimed = self.conn.execute(
                    "UPDATE codes SET status='used', used_by=?, used_at=? "
                    "WHERE id=? AND status='unused'",
                    (user_id, now, code_row["id"]))
                if claimed.rowcount != 1:
                    raise ApiError(409, "卡密已被使用", code="CODE_USED")
                self.conn.execute(
                    "INSERT INTO redemptions(user_id,account,code,plan_id,plan_name,days,price_fen,created_at)"
                    " VALUES(?,?,?,?,?,?,?,?)",
                    (user_id, user["account"], code_row["code"], code_row["plan_id"],
                     code_row["plan_name"], code_row["days"], code_row["price_fen"], now))
                new_until = max(now, user["paid_until"] or 0) + int(code_row["days"]) * DAY_SECONDS
                self.conn.execute(
                    "UPDATE users SET paid_until=?, ever_paid=1, plan_label=?, updated_at=? WHERE id=?",
                    (new_until, "%s会员" % code_row["plan_name"], now, user_id))
                updated = self.conn.execute(
                    "SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
                self.conn.commit()
                return updated, code_row
            except BaseException:
                self.conn.rollback()
                raise

    def create_token(self, user_id, ttl_days):
        token = secrets.token_urlsafe(32)
        now = now_i()
        self.execute(
            "INSERT INTO tokens(token_hash,user_id,expires_at,created_at) VALUES(?,?,?,?)",
            (sha256_hex(token), user_id, now + int(ttl_days) * DAY_SECONDS, now))
        return token

    def lookup_token(self, token):
        """按明文 token 查用户；过期即删除并返回 (None, token_hash)。"""
        th = sha256_hex(token)
        row = self.query_one(
            "SELECT t.expires_at AS token_expires, u.* "
            "FROM tokens t JOIN users u ON u.id = t.user_id "
            "WHERE t.token_hash=?", (th,))
        if row is None:
            return None, th
        if row["token_expires"] < now_i():
            self.execute("DELETE FROM tokens WHERE token_hash=?", (th,))
            return None, th
        return row, th


# ---------------------------------------------------------------------------
# 限速 / 锁定（内存实现，进程重启即清零；带 TTL 回收与条目上限）
# ---------------------------------------------------------------------------

class Limiter:
    """滑动窗口限速 + 失败锁定。

    3-03：原实现的 login_fails / reg_hits 只增不减，而键来自攻击者可控的账号名，
    持续用随机账号名打 /api/login 就能让内存无上限增长。本实现：
      - 每个条目带最近活动时间，静默超过 ttl 即回收；
      - 条目总数超过 max_keys 时按最旧淘汰；
      - 读写路径上按摊销方式清理，不另起定时器。
    """

    def __init__(self, max_keys=LIMITER_MAX_KEYS, ttl=LIMITER_TTL_SECONDS):
        self.lock = threading.Lock()
        self.login_fails = {}   # key -> [连续失败次数, 锁定截止时间戳, 最近活动时间戳]
        self.hits = {}          # "维度:键" -> [时间戳列表]
        self.max_keys = max_keys
        self.ttl = ttl
        self._ops = 0

    # ---- 回收 ----

    def _maybe_prune_locked(self):
        self._ops += 1
        if self._ops % 128 and len(self.login_fails) + len(self.hits) <= self.max_keys:
            return
        self.prune_locked()

    def prune_locked(self):
        now = now_i()
        for key, e in list(self.login_fails.items()):
            last = e[2] if len(e) > 2 else 0
            if (not e[1] or e[1] <= now) and now - last > self.ttl:
                self.login_fails.pop(key, None)
        for key, hits in list(self.hits.items()):
            live = [t for t in hits if now - t < self.ttl]
            if live:
                self.hits[key] = live
            else:
                self.hits.pop(key, None)
        self._evict_overflow_locked()

    def _evict_overflow_locked(self):
        """超过上限时按最旧活动淘汰，保证内存有界。"""
        total = len(self.login_fails) + len(self.hits)
        if total <= self.max_keys:
            return
        by_age = []
        for key, e in self.login_fails.items():
            by_age.append((e[2] if len(e) > 2 else 0, "f", key))
        for key, hits in self.hits.items():
            by_age.append((hits[-1] if hits else 0, "h", key))
        by_age.sort()
        room = total - self.max_keys
        for _ts, kind, key in by_age[:room]:
            (self.login_fails if kind == "f" else self.hits).pop(key, None)

    # ---- 失败锁定（按账号 / 按维度键） ----

    def locked_remaining(self, key):
        with self.lock:
            self._maybe_prune_locked()
            e = self.login_fails.get(key)
            if not e:
                return 0
            if e[1] > now_i():
                return e[1] - now_i()
            if e[1]:
                # 锁定期已过：清掉锁标记并重新计数，但条目本身保留（由 TTL/容量回收）
                e[1] = 0
                e[0] = 0
            return 0


    def record_fail(self, key, max_fails=LOGIN_MAX_FAILS, lock_seconds=LOGIN_LOCK_SECONDS):
        now = now_i()
        with self.lock:
            self._maybe_prune_locked()
            e = self.login_fails.setdefault(key, [0, 0, now])
            if len(e) < 3:
                e.append(now)
            e[0] += 1
            e[2] = now
            if e[0] >= max_fails:
                e[1] = now + lock_seconds
                e[0] = 0  # 锁定期满后重新计数

    def clear_fails(self, key):
        with self.lock:
            self.login_fails.pop(key, None)

    def fail_count(self, key):
        with self.lock:
            e = self.login_fails.get(key)
            return e[0] if e else 0

    # ---- 滑动窗口计数 ----

    def allow(self, dimension, key, limit, window=3600):
        """limit/window 内是否还允许一次。dimension 用于隔离不同接口的键空间。"""
        if limit is None or limit <= 0:
            return True
        bucket = "%s:%s" % (dimension, key)
        now = now_i()
        with self.lock:
            self._maybe_prune_locked()
            hits = [t for t in self.hits.get(bucket, []) if now - t < window]
            allowed = len(hits) < limit
            if allowed:
                hits.append(now)
            self.hits[bucket] = hits
            return allowed

    def allow_register(self, ip, limit=REGISTER_LIMIT_PER_HOUR, window=3600):
        """兼容既有调用点（smoke/脚本）的注册限速入口。"""
        return self.allow("register", ip, limit, window)

    def remaining_of(self, dimension, key, limit, window=3600):
        bucket = "%s:%s" % (dimension, key)
        now = now_i()
        with self.lock:
            hits = [t for t in self.hits.get(bucket, []) if now - t < window]
            return max(0, limit - len(hits))

    def reset_bucket(self, dimension, key):
        """显式清零某个滑动窗口（如管理登录成功后重置全局失败计数）。"""
        with self.lock:
            self.hits.pop("%s:%s" % (dimension, key), None)


    def reset(self):
        with self.lock:
            self.login_fails.clear()
            self.hits.clear()


LIMITER = Limiter()

# 管理后台会话：token 摘要 -> 过期时间（内存，重启后需重新登录）
ADMIN_SESSIONS = {}
ADMIN_LOCK = threading.Lock()
ADMIN_SESSIONS_MAX = 512


def admin_prune_sessions():
    """回收过期/遗弃的管理会话（3-03：原来只在 token 被再次呈现时才 pop）。"""
    now = now_i()
    with ADMIN_LOCK:
        for th in [k for k, v in ADMIN_SESSIONS.items() if v <= now]:
            ADMIN_SESSIONS.pop(th, None)
        overflow = len(ADMIN_SESSIONS) - ADMIN_SESSIONS_MAX
        if overflow > 0:
            for th in sorted(ADMIN_SESSIONS.items(), key=lambda kv: kv[1])[0:overflow][::-1]:
                ADMIN_SESSIONS.pop(th[0], None)
        return len(ADMIN_SESSIONS)


def admin_create_session():
    token = secrets.token_urlsafe(32)
    with ADMIN_LOCK:
        ADMIN_SESSIONS[sha256_hex(token)] = now_i() + ADMIN_SESSION_TTL
    admin_prune_sessions()
    return token


def admin_check_session(token):
    if not token:
        return False
    th = sha256_hex(token)
    with ADMIN_LOCK:
        exp = ADMIN_SESSIONS.get(th)
        if exp and exp > now_i():
            ADMIN_SESSIONS[th] = now_i() + ADMIN_SESSION_TTL  # 滑动续期
            return True
        ADMIN_SESSIONS.pop(th, None)
    return False


# ---------------------------------------------------------------------------
# HTTP Handler
# ---------------------------------------------------------------------------

class BillingHandler(BaseHTTPRequestHandler):
    server_version = "QQBilling/1.0"
    protocol_version = "HTTP/1.1"
    # 3-02：StreamRequestHandler.setup() 会用它给 socket 设读超时；默认 None 意味着
    # 「声明了 Content-Length 却不发 body」能让工作线程永久挂住（slowloris）。
    timeout = CONN_TIMEOUT_SECONDS

    # main() 注入
    cfg = None
    db = None
    www_dir = DEFAULT_WWW_DIR
    bind_host = "127.0.0.1"
    bind_port = 8790
    max_body_bytes = MAX_BODY_BYTES

    # ---- 路由 ----

    def do_GET(self):
        self._route("GET")

    def do_HEAD(self):
        self._route("HEAD")

    def do_POST(self):
        self._route("POST")

    def do_OPTIONS(self):
        # 只应答预检，不开放任何跨域读权限（默认不发 CORS 头，这是最安全的取值）
        self._route("OPTIONS")

    def _reject_method(self, method):
        self.close_connection = True
        self.send_json(405, {"error": "不支持的请求方法 %s" % method},
                       {"Allow": "GET, HEAD, POST, OPTIONS"})

    def do_PUT(self):
        self._reject_method("PUT")

    def do_DELETE(self):
        self._reject_method("DELETE")

    def do_PATCH(self):
        self._reject_method("PATCH")

    def _route(self, method):
        """单个请求的异常隔离：任何未预期异常都只影响本连接，不拖垮工作线程/进程，
        且响应体里只有固定文案（traceback 只进服务端日志，绝不回显）。"""
        self._request_id = secrets.token_hex(4)
        try:
            self._guard_request_line(method)
            self._dispatch(method)
        except ApiError as e:
            payload = {"error": e.message}
            if e.code:
                payload["code"] = e.code
            if e.status >= 500:
                self._log_error_safe("server error %s: %s", e.status, e.code or e.message)
            try:
                self.send_json(e.status, payload)
            except (BrokenPipeError, ConnectionResetError, OSError):
                self.close_connection = True
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True
        except socket.timeout:
            # 慢连接：位置已不可信，回 408 并断开
            self.close_connection = True
            self._log_error_safe("read timeout from %s", self._peer_ip())
            try:
                self.send_json(408, {"error": "请求超时", "code": "REQUEST_TIMEOUT"})
            except Exception:
                pass
        except Exception as exc:  # noqa: BLE001 兜底，避免线程崩溃无响应
            self.close_connection = True
            self._log_error_safe("unhandled %s on %s", exc_summary(exc),
                                 self._safe_target())
            try:
                self.send_json(500, {"error": "服务器内部错误",
                                     "code": "INTERNAL_ERROR",
                                     "request_id": self._request_id})
            except Exception:
                pass

    def handle(self):
        """整条连接的兜底：BaseHTTPRequestHandler.handle() 的读循环之外也可能抛
        （例如 finish() 阶段 flush 半关闭的 socket），这里吞掉不影响其他连接。"""
        try:
            BaseHTTPRequestHandler.handle(self)
        except (BrokenPipeError, ConnectionResetError, socket.timeout):
            self.close_connection = True
        except Exception as exc:  # noqa: BLE001
            self.close_connection = True
            self._log_error_safe("connection error: %s", exc_summary(exc))

    def finish(self):
        try:
            BaseHTTPRequestHandler.finish(self)
        except (BrokenPipeError, ConnectionResetError, socket.timeout, OSError):
            # 客户端提前断开是常态，不该变成 socketserver 的 traceback 噪声
            try:
                if self.wfile is not None:
                    self.wfile.flush()
            except Exception:
                pass

    def _log_error_safe(self, fmt, *args):
        try:
            sys.stderr.write(("[error] [%s] " + fmt + "\n")
                             % ((getattr(self, "_request_id", "-"),) + args))
            sys.stderr.flush()
        except Exception:
            pass

    def _safe_target(self):
        """日志里只留脱敏后的路径（查询串可能含账号/卡密片段）。"""
        try:
            return redact_query(self.path or "")
        except Exception:
            return "<unknown>"

    def _guard_request_line(self, method):
        """Host 校验 + POST 的 Content-Type 约束（3-11）。

        只在监听回环时强制 Host：那正是 DNS rebinding 的受害面；绑定公网地址时
        客户端可能用任意域名访问，不能凭 Host 断言。
        """
        if is_loopback_host(self.bind_host) and not self._host_allowed():
            raise ApiError(400, "Host 头不被允许", code="BAD_HOST")
        if method in ("POST", "PUT", "PATCH"):
            te = (self.headers.get("Transfer-Encoding") or "").strip()
            cl = self.headers.get("Content-Length")
            has_body = bool(te) or (cl is not None and safe_int(cl, 0) != 0)
            if has_body and (self.cfg or {}).get("require_json_content_type", True):
                ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
                if ctype != "application/json":
                    raise ApiError(415, "请求体需为 application/json",
                                   code="UNSUPPORTED_MEDIA_TYPE")


    def _host_allowed(self):
        host_hdr = clamp_text(self.headers.get("Host", ""), 120).lower()
        if not host_hdr:
            return False
        if host_hdr.startswith("["):                    # [::1]:8790
            bare = host_hdr.split("]")[0] + "]"
        elif host_hdr.count(":") == 1:                  # 127.0.0.1:8790
            bare = host_hdr.split(":")[0]
        else:                                           # 无端口，或裸 IPv6 字面量
            bare = host_hdr
        names = set(self.cfg.get("allowed_hosts", []) if self.cfg else [])
        names |= {"127.0.0.1", "localhost", "::1", "[::1]", self.bind_host}
        if bare in names:
            return True
        return any(host_hdr == "%s:%d" % (n, self.bind_port) for n in names)

    def _dispatch(self, method):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        qs = parse_qs(parsed.query)

        if method == "OPTIONS":
            self._send(204, b"", "text/plain; charset=utf-8")
            return
        if method == "HEAD":
            # 只支持两个静态页的 HEAD，其余一律不执行副作用
            if path == "/":
                return self._serve_page("index.html", head_only=True)
            if path == "/admin":
                return self._serve_page("admin.html", head_only=True)
            return self._send(404, b"", "text/plain; charset=utf-8")

        if method == "GET":
            if path == "/":
                return self._serve_page("index.html")
            if path == "/admin":
                return self._serve_page("admin.html")
            if path == "/favicon.ico":
                return self._send(404, b"", "text/plain; charset=utf-8")
            if path == "/api/plans":
                return self._handle_plans()
            if path == "/api/me":
                return self._handle_me()
            if path == "/api/admin/overview":
                return self._handle_admin_overview()
            if path == "/api/admin/users":
                return self._handle_admin_users(qs)
            if path == "/api/admin/codes/export":
                return self._handle_admin_codes_export(qs)
            if path == "/api/admin/codes":
                return self._handle_admin_codes(qs)
            if path == "/api/admin/redemptions":
                return self._handle_admin_redemptions()
            if path == "/api/admin/audit":
                return self._handle_admin_audit(qs)
        else:  # POST
            if path == "/api/register":
                return self._handle_register()
            if path == "/api/login":
                return self._handle_login()
            if path == "/api/logout":
                return self._handle_logout()
            if path == "/api/change_password":
                return self._handle_change_password()
            if path == "/api/redeem":
                return self._handle_redeem()
            if path == "/api/admin/login":
                return self._handle_admin_login()
            if path == "/api/admin/logout":
                return self._handle_admin_logout()
            if path == "/api/admin/users/grant":
                return self._handle_admin_grant()
            if path == "/api/admin/users/disable":
                return self._handle_admin_disable()
            if path == "/api/admin/users/revoke-sessions":
                return self._handle_admin_revoke_sessions()
            if path == "/api/admin/codes/generate":
                return self._handle_admin_generate()
            if path == "/api/admin/codes/void":
                return self._handle_admin_code_void()
        raise ApiError(404, "接口不存在")


    # ---- 响应 / 请求体 ----

    def _body_limit(self):
        limit = self.max_body_bytes or MAX_BODY_BYTES
        if self.cfg:
            limit = safe_int(self.cfg.get("max_body_bytes", limit), limit, 1024,
                             16 * 1024 * 1024)
        return limit

    def _read_exactly(self, count):
        """循环读到恰好 count 字节。BufferedReader.read(n) 允许返回不足 n 的短读，
        原实现 `self.rfile.read(length)` 单次调用在慢速/分包时会少读。"""
        chunks = []
        got = 0
        while got < count:
            piece = self.rfile.read(min(65536, count - got))
            if not piece:
                self.close_connection = True
                raise ApiError(400, "请求体不完整（连接提前结束）")
            chunks.append(piece)
            got += len(piece)
        return b"".join(chunks)

    def _read_chunked(self, limit):
        """解析 chunked 请求体：不消费就会在同一 keep-alive 连接上串到下一个请求
        （3-02 路径 B），并且 chunked 会绕过 Content-Length 上的大小限制。"""
        total = bytearray()
        while True:
            head = self.rfile.readline(CHUNK_MAX_BYTES)
            if not head or len(head) >= CHUNK_MAX_BYTES:
                self.close_connection = True
                raise ApiError(400, "chunk 长度行非法")
            size_text = head.decode("ascii", "ignore").split(";")[0].strip()
            try:
                size = int(size_text, 16)
            except ValueError:
                self.close_connection = True
                raise ApiError(400, "chunk 长度行无法解析")
            if size < 0:
                self.close_connection = True
                raise ApiError(400, "chunk 长度非法")
            if len(total) + size > limit:
                self.close_connection = True   # 超限不再排空，直接断开
                raise ApiError(413, "请求体过大")
            if size == 0:
                # 结尾块之后可能还有 trailer 头，读到空行为止，否则残字节会串包
                while True:
                    trailer = self.rfile.readline(1024)
                    if not trailer or trailer in (b"\r\n", b"\n"):
                        break
                break
            total += self._read_exactly(size)
            sep = self._read_exactly(2)
            if sep not in (b"\r\n", b"\n\r"):
                self.close_connection = True
                raise ApiError(400, "chunk 数据后缺少 CRLF")
        return bytes(total)

    def _read_body(self):
        """读取（并只读一次）请求体；任何失败都同时置 close_connection。"""
        self._body_read = True
        te = (self.headers.get("Transfer-Encoding") or "").strip()
        cl_raw = self.headers.get("Content-Length")
        limit = self._body_limit()
        if te:
            if cl_raw is not None:
                self.close_connection = True
                raise ApiError(400, "Content-Length 与 Transfer-Encoding 不能并存",
                               code="AMBIGUOUS_BODY")
            if te.lower() != "chunked":
                self.close_connection = True
                raise ApiError(501, "不支持的 Transfer-Encoding: %s" % te)
            return self._read_chunked(limit)
        if cl_raw is None:
            # 既无 Content-Length 又无 Transfer-Encoding：body 的长度只能以「连接关闭」
            # 为界。这类 POST 若不判死，残体就会在同一 keep-alive 连接上被当成下一个
            # 请求行（3-02 路径 B 的另一种触发方式）。纯 bodyless 的 POST（如 /api/logout）
            # 通常不带 Content-Type，不受影响。
            if self.command == "POST" and self.headers.get("Content-Type"):
                self.close_connection = True
            return b""
        try:
            length = int(str(cl_raw).strip())
        except ValueError:
            self.close_connection = True
            raise ApiError(400, "Content-Length 非法")
        if length < 0:
            self.close_connection = True
            raise ApiError(400, "Content-Length 非法")
        if length > limit:
            self.close_connection = True   # 过大不读，直接断开
            raise ApiError(413, "请求体过大")
        if length == 0:
            return b""
        return self._read_exactly(length)

    def _drain_body_if_needed(self):
        """响应前把没读过的请求体排空，保证 HTTP/1.1 keep-alive 不串包。"""
        if getattr(self, "_body_read", False):
            return
        try:
            self._read_body()
        except ApiError:
            pass   # 已置 close_connection

    def _send(self, status, body, content_type, extra_headers=None):
        self._drain_body_if_needed()
        self.send_response(status)
        if status != HTTPStatus.NO_CONTENT:
            self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        # 基础安全响应头（不写 CSP：www 下两页大量使用内联脚本/样式，加了会白屏）
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "SAMEORIGIN")
        self.send_header("Referrer-Policy", "no-referrer")
        # stdlib 的 send_response 不会补 Connection，需与 self.close_connection 同步，
        # 否则客户端以为能复用连接、服务端却准备关闭
        if self.protocol_version >= "HTTP/1.1":
            self.send_header("Connection", "close" if self.close_connection else "keep-alive")
        origin = self._cors_origin_allowed()
        if origin:
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Vary", "Origin")
        rid = getattr(self, "_request_id", "")
        if rid:
            self.send_header("X-Request-Id", rid)
        for k, v in (extra_headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD" and body:
            self.wfile.write(body)

    def send_json(self, status, obj, extra_headers=None):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self._send(status, body, "application/json; charset=utf-8", extra_headers)

    def _cors_origin_allowed(self):
        """默认【不发】任何 CORS 头（跨域脚本读不到响应）。只有配置了精确来源才放开，
        且 '*' 已在配置校验阶段拒绝。"""
        configured = (self.cfg or {}).get("cors_allow_origin") if self.cfg else ""
        if not configured:
            return ""
        origin = clamp_text(self.headers.get("Origin", ""), 200)
        return origin if origin == configured else ""

    def _serve_page(self, filename, head_only=False):
        fp = os.path.join(self.www_dir, filename)
        try:
            with open(fp, "rb") as f:
                body = f.read()
        except OSError:
            # 具体路径只进服务端日志，不回显给客户端（3-11 调试信息外泄）
            self._log_error_safe("页面文件缺失: %s", filename)
            raise ApiError(404, "页面不存在", code="PAGE_NOT_FOUND")
        self._send(200, body, "text/html; charset=utf-8")

    def _read_json(self):
        raw = self._read_body()
        if not raw:
            return {}
        try:
            data = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            raise ApiError(400, "请求体不是合法 JSON")
        if not isinstance(data, dict):
            raise ApiError(400, "请求体应为 JSON 对象")
        return data

    # ---- 来源识别（限速键的唯一依据） ----

    def _peer_ip(self):
        try:
            return str(self.client_address[0])
        except (IndexError, TypeError):
            return "unknown"

    def _client_ip(self):
        """3-01：一个 X-Forwarded-For 请求头就能绕过全部限速与锁定，所以默认
        【只用 socket 对端地址】。仅当同时满足两条才采信 XFF：
          1) 配置 trust_proxy_headers = true（显式声明「部署在可信反代之后」）；
          2) 直连对端确实落在 trusted_proxies 网段内（默认只含回环）。
        取值方式：从右往左数 trusted_proxy_hops 跳（反代追加自己那一跳），
        而不是取最左段——最左段本来就是客户端自己写的。"""
        peer = self._peer_ip()
        cfg = self.cfg or {}
        if not cfg.get("trust_proxy_headers"):
            return peer
        xff = self.headers.get("X-Forwarded-For", "")
        if not xff:
            return peer
        if not cidr_list_matches(parse_ip(peer),
                                 cfg.get("trusted_proxies") or TRUSTED_PROXY_CIDRS_DEFAULT):
            return peer            # 对端不是可信代理：整个 XFF 一律不采信
        chain = [seg.strip() for seg in xff.split(",") if seg.strip()]
        if not chain:
            return peer
        hops = safe_int(cfg.get("trusted_proxy_hops", 1), 1, 1, 8)
        index = len(chain) - hops
        if index < 0:
            index = 0
        candidate = chain[index]
        return candidate if parse_ip(candidate) is not None else peer

    def _client_ip_for_log(self):
        """访问日志用：默认记脱敏后的来源标识（回环部署下都是 127.0.0.1，无需隐藏；
        公网部署可配 log_client_ip=false 只留网段）。"""
        ip = self._client_ip()
        if self.cfg and self.cfg.get("log_client_ip") is False:
            return ip_bucket(ip)
        return ip

    # ---- 鉴权 ----

    def _bearer(self):
        h = self.headers.get("Authorization", "")
        if h.startswith("Bearer "):
            return h[7:].strip()
        return ""

    def _require_user(self):
        """校验 Bearer token；通过则返回用户行，并对快过期的 token 滑动续期。

        禁用判定统一收口在这里（3-07 的「每个新接口都必须再查一次 disabled」脆弱模式）：
        所有需要登录的接口都经由此函数，禁用账号在任何接口都是同一 403 语义。
        """
        token = self._bearer()
        if not token:
            raise ApiError(401, "缺少登录凭证（Bearer token）")
        row, th = self.db.lookup_token(token)
        if row is None:
            raise ApiError(401, "登录已过期或凭证无效，请重新登录")
        if row["disabled"]:
            raise ApiError(403, DISABLED_MESSAGE, code="ACCOUNT_DISABLED")
        ttl = safe_int(self.cfg.get("token_ttl_days", TOKEN_TTL_DAYS_DEFAULT),
                       TOKEN_TTL_DAYS_DEFAULT, 0, 3650) * DAY_SECONDS
        if ttl > 0 and row["token_expires"] - now_i() < ttl // 2:
            self.db.execute("UPDATE tokens SET expires_at=? WHERE token_hash=?",
                            (now_i() + ttl, th))
        return row

    def _require_admin(self):
        if not admin_check_session(self._bearer()):
            raise ApiError(401, "管理员未登录或登录已过期")

    def _handle_admin_logout(self):
        self._require_admin()
        with ADMIN_LOCK:
            ADMIN_SESSIONS.pop(sha256_hex(self._bearer()), None)
        self.send_json(200, {"ok": True})

    # ---- profile ----

    def _profile(self, row):
        """账号档案。授权判定只看 epoch 秒（paid_until / now），展示串另列。

        向后兼容：只【新增】字段，原有键名/类型/取值一律不变（客户端 MembershipProfile
        用 JSONDecoder 解码，未识别的键会被忽略）。
        新增字段语义（供客户端 3-15 使用）：
          - expired            ：paid_until 为空或已过去 —— 服务端「明确回答已过期」，
                                 客户端不得据此把宽限计时点刷成当前时间；
          - active             ：与 expired 互斥，等价于 paid_until > server_time；
          - membership_state   ：'active' | 'expired'，字符串口径，便于日志与 UI；
          - server_time        ：服务端当前 epoch 秒，客户端用来建立单调时间锚
                                 （不再信任本机 Date() 作为唯一时基）；
          - paid_until_utc_iso ：UTC ISO8601 展示串，不受部署机时区影响。
        """
        paid_until = row["paid_until"] or 0
        now = now_i()
        if row["ever_paid"]:
            label = row["plan_label"] or "会员"
        else:
            label = "试用版"
        active = bool(paid_until and paid_until > now)
        return {
            "user_id": row["id"],
            "account": row["account"],
            "plan_label": label,
            "paid_until": paid_until,
            "paid_until_display": fmt_ts(paid_until) if paid_until else "-",
            "days_left": days_left_of(paid_until, now),
            "source": "paid" if row["ever_paid"] else "trial",
            "disabled": bool(row["disabled"]),
            "created_at": row["created_at"],
            # ---- 本轮新增（只增不改） ----
            "expired": not active,
            "active": active,
            "membership_state": "active" if active else "expired",
            "server_time": now,
            "paid_until_utc_iso": fmt_ts_utc(paid_until) if paid_until else "-",
        }

    # ---- 公开接口 ----

    def _handle_plans(self):
        """与启动时同一套字段规则（sanitize_plans）：坏档位剔除而不是返回半截数据，
        任何手改失误都不会让公开接口 500（3-10）。"""
        _problems, plans_cfg = sanitize_plans((self.cfg or {}).get("plans"))
        plans = [{
            "id": p["id"],
            "name": p["name"],
            "days": int(p["days"]),
            "price_fen": int(p["price_fen"]),
            "price_display": price_display(p["price_fen"]),
            "tagline": p.get("tagline", ""),
        } for p in plans_cfg]
        trial_days = safe_int((self.cfg or {}).get("trial_days", TRIAL_DAYS_DEFAULT), TRIAL_DAYS_DEFAULT, 0, 3650)
        self.send_json(200, plans, {"X-Trial-Days": str(trial_days)})


    def _handle_register(self):
        body = self._read_json()
        account = clamp_text(body.get("account"), 64)
        password = str(body.get("password") or "")
        if not ACCOUNT_RE.match(account):
            raise ApiError(400, "账号需为 4-40 位字母/数字/下划线/@/. 的组合")
        if len(password) < 6:
            raise ApiError(400, "密码至少 6 位")
        if len(password) > 128:
            raise ApiError(400, "密码过长（≤128 位）")
        cfg = self.cfg or {}
        source = self._client_ip()
        # 三层防线：单来源 / 网段聚合 / 全局总量。默认来源=socket 对端，伪造请求头
        # 不再能刷出新键（3-01）。
        if not LIMITER.allow("register", source,
                             safe_int(cfg.get("register_limit_per_hour",
                                              REGISTER_LIMIT_PER_HOUR),
                                      REGISTER_LIMIT_PER_HOUR, 1, 10000), 3600):
            raise ApiError(429, "注册过于频繁，请 1 小时后再试", code="RATE_LIMITED")
        if not LIMITER.allow("register-net", ip_bucket(source),
                             safe_int(cfg.get("register_limit_per_hour",
                                              REGISTER_LIMIT_PER_HOUR),
                                      REGISTER_LIMIT_PER_HOUR, 1, 10000) * 4, 3600):
            raise ApiError(429, "注册过于频繁，请稍后再试", code="RATE_LIMITED")
        if not LIMITER.allow("register-day", "global",
                             safe_int(cfg.get("register_global_per_day",
                                              REGISTER_GLOBAL_PER_DAY),
                                      REGISTER_GLOBAL_PER_DAY, 1, 100000), 86400):
            raise ApiError(429, "今日注册量已达上限，请明天再试", code="RATE_LIMITED")
        if self.db.query_one("SELECT id FROM users WHERE account=?", (account,)):
            raise ApiError(409, "该账号已被注册")
        trial_days = safe_int(cfg.get("trial_days", TRIAL_DAYS_DEFAULT),
                              TRIAL_DAYS_DEFAULT, 0, 3650)
        try:
            user_id = self.db.create_user(account, password, trial_days)
        except sqlite3.IntegrityError:
            # A concurrent duplicate is a conflict; other constraints are database failures.
            if self.db.query_one("SELECT id FROM users WHERE account=?", (account,)):
                raise ApiError(409, "该账号已被注册")
            raise
        ttl = safe_int(cfg.get("token_ttl_days", TOKEN_TTL_DAYS_DEFAULT),
                       TOKEN_TTL_DAYS_DEFAULT, 0, 3650)
        token = self.db.create_token(user_id, ttl)
        row = self.db.query_one("SELECT * FROM users WHERE id=?", (user_id,))
        self.db.audit_event("user.register", user_id, account,
                            "trial_days=%d" % trial_days, self._log_origin())
        self.send_json(200, {"token": token, "profile": self._profile(row),
                             "trial_days": trial_days})

    def _handle_login(self):
        body = self._read_json()
        account = clamp_text(body.get("account"), 64)
        password = str(body.get("password") or "")
        if not account or not password:
            raise ApiError(400, "请输入账号与密码")
        if len(password) > MAX_PASSWORD_LEN:
            raise ApiError(400, "密码过长")
        source = self._client_ip()
        cfg = self.cfg or {}
        key = "login:" + account.lower()
        remain = LIMITER.locked_remaining(key)
        if remain > 0:
            raise ApiError(429, "登录失败次数过多，请 %d 分钟后再试" % ((remain + 59) // 60))
        # 来源维度也计数：攻击者轮换账号名绕开单账号锁时仍有总量上限（3-01/3-03）。
        # 只有【失败】才消耗额度，正常登录不受影响。
        ip_limit = safe_int(cfg.get("login_ip_max_fails", LOGIN_IP_MAX_FAILS),
                            LOGIN_IP_MAX_FAILS, 1, 100000)
        if LIMITER.remaining_of("login-ip-fail", source, ip_limit,
                               LOGIN_LOCK_SECONDS) <= 0:
            raise ApiError(429, "登录尝试过多，请稍后再试", code="RATE_LIMITED")
        row = self.db.query_one("SELECT * FROM users WHERE account=?", (account,))
        if not verify_account_password(row, password):     # 恒定代价，不暴露存在性
            LIMITER.record_fail(key)
            LIMITER.allow("login-ip-fail", source, ip_limit, LOGIN_LOCK_SECONDS)
            raise ApiError(401, "账号或密码错误")

        if row["disabled"]:
            raise ApiError(403, DISABLED_MESSAGE, code="ACCOUNT_DISABLED")
        LIMITER.clear_fails(key)
        ttl = safe_int(cfg.get("token_ttl_days", TOKEN_TTL_DAYS_DEFAULT),
                       TOKEN_TTL_DAYS_DEFAULT, 0, 3650)
        token = self.db.create_token(row["id"], ttl)
        self.send_json(200, {"token": token, "profile": self._profile(row)})

    def _handle_logout(self):
        token = self._bearer()
        if token:
            self.db.execute("DELETE FROM tokens WHERE token_hash=?", (sha256_hex(token),))
        self.send_json(200, {"ok": True})

    def _handle_change_password(self):
        """POST /api/change_password {old_password, new_password}（Bearer 鉴权）。

        补 3-07 的缺口「用户无法改密，旧 token 永不失效」。本轮【新增】接口，不改动
        任何既有路径/状态码/字段；改密成功后该账号在所有设备上的会话都失效（库里
        全部 token 被吊销），当前设备用响应里的新 token 继续，其余设备需重新登录。
        限速按账号，防止有人拿这个接口当第二个口令猜测面。
        """
        row = self._require_user()
        cfg = self.cfg or {}
        key = "chpasswd:" + str(row["id"])
        remain = LIMITER.locked_remaining(key)
        if remain > 0:
            raise ApiError(429, "改密失败次数过多，请 %d 分钟后再试" % ((remain + 59) // 60))
        if not LIMITER.allow("chpasswd", row["id"],
                             safe_int(cfg.get("chpasswd_limit_per_hour",
                                              CHPASSWD_LIMIT_PER_HOUR),
                                      CHPASSWD_LIMIT_PER_HOUR, 1, 10000), 3600):
            raise ApiError(429, "改密过于频繁，请稍后再试", code="RATE_LIMITED")
        body = self._read_json()
        old_password = str(body.get("old_password") or "")
        new_password = str(body.get("new_password") or "")
        if not old_password or not new_password:
            raise ApiError(400, "请输入原密码与新密码")
        if len(old_password) > MAX_PASSWORD_LEN or len(new_password) > 128:
            raise ApiError(400, "密码过长（原密码 ≤%d 位，新密码 ≤128 位）" % MAX_PASSWORD_LEN)
        if len(new_password) < 6:
            raise ApiError(400, "新密码至少 6 位")
        if new_password == old_password:
            raise ApiError(400, "新密码不能与原密码相同")
        if not verify_account_password(row, old_password):
            LIMITER.record_fail(key)
            self.db.audit_event("user.password_change_denied", row["id"], row["account"],
                                "", self._log_origin())
            raise ApiError(403, "原密码不正确", code="BAD_OLD_PASSWORD")
        LIMITER.clear_fails(key)
        _user, revoked = self.db.change_password(row["id"], new_password,
                                                 self._log_origin())
        ttl = safe_int(cfg.get("token_ttl_days", TOKEN_TTL_DAYS_DEFAULT),
                       TOKEN_TTL_DAYS_DEFAULT, 0, 3650)
        token = self.db.create_token(row["id"], ttl)
        fresh = self.db.query_one("SELECT * FROM users WHERE id=?", (row["id"],))
        self.send_json(200, {"ok": True, "token": token,
                             "revoked_sessions": int(revoked),
                             "profile": self._profile(fresh)})

    def _handle_me(self):
        """过期语义（重要，与客户端 3-15 相关）：
        本接口对「已过期账号」仍返回 200 + 原有全部字段 —— 老客户端不会被踢出登录。
        新增的 expired/active/membership_state/server_time 供客户端区分
        「服务器明确回答已过期」与「根本没联系上服务器」；客户端只能在
        expired=false 时刷新宽限计时点。服务端不改状态码，避免破坏既有会话。"""
        row = self._require_user()
        self.send_json(200, self._profile(row))

    def _log_origin(self):
        """审计里的来源标识：默认只留 /24（或 /64）网段，避免把明细 IP 长期留在库里。"""
        if self.cfg and self.cfg.get("log_client_ip"):
            return self._client_ip()
        return ip_bucket(self._client_ip())

    def _rate_limit_redeem(self, user_id):
        cfg = self.cfg or {}
        uid = safe_int(user_id, 0, 0, None)
        limit_u = safe_int(cfg.get("redeem_limit_per_hour", REDEEM_LIMIT_PER_HOUR),
                           REDEEM_LIMIT_PER_HOUR, 1, 10000)
        limit_i = safe_int(cfg.get("redeem_ip_limit_per_hour", REDEEM_IP_LIMIT_PER_HOUR),
                           REDEEM_IP_LIMIT_PER_HOUR, 1, 100000)
        if not LIMITER.allow("redeem", uid, limit_u, 3600):
            raise ApiError(429, "兑换尝试过于频繁，请 1 小时后再试", code="RATE_LIMITED")
        if not LIMITER.allow("redeem-ip", self._client_ip(), limit_i, 3600):
            raise ApiError(429, "兑换尝试过于频繁，请稍后再试", code="RATE_LIMITED")

    def _redeem_public_error(self, exc):
        """把 404/409 的【可区分文案】收敛成同一条模糊提示（3-04 的用户枚举预言机）。
        HTTP 状态码保持不变（向后兼容：老客户端与冒烟脚本按 404/409 分支处理），
        真实原因写入 admin_audit，后台可查。"""
        cfg = self.cfg or {}
        if not cfg.get("unified_redeem_error", True):
            return exc
        if exc.code in ("CODE_NOT_FOUND", "CODE_USED"):
            self.db.audit_event("redeem.miss", None, "", "code=%s" % exc.code,
                                self._log_origin())
            return ApiError(exc.status, CODE_INVALID_PUBLIC_MESSAGE,
                            code=CODE_INVALID_PUBLIC_ERROR_CODE)
        return exc

    def _handle_redeem(self):
        row = self._require_user()          # disabled 已在此统一判定
        # 兑换是全系统价值最高的接口：按账号 + 按来源双重限速（3-04）
        self._rate_limit_redeem(row["id"])
        body = self._read_json()
        code = clamp_text(body.get("code"), 64).upper()
        if not code:
            raise ApiError(400, "请输入卡密")
        cfg = self.cfg or {}
        if cfg.get("enforce_code_format", True) and not code_shape_ok(
                code, True if cfg.get("code_format_strict") else None):
            # 不查库直接拒：既挡住「1MB 随机串灌进 redemptions.code」，
            # 也把 1.1e12 的爆破空间真正落实成有形状的合法码才可尝试
            raise ApiError(400, "卡密格式不正确", code="CODE_INVALID")

        # 卡密核销、收入记账与会员时长必须一起成功；不能调用逐语句提交的execute。
        try:
            new_row, code_row = self.db.redeem_code(row["id"], code)
        except ApiError as exc:
            if exc.code == "ACCOUNT_DISABLED":
                # 事务内重查命中的竞态（禁用与兑换交错）：文案与中央判定保持同一口径
                raise ApiError(403, DISABLED_MESSAGE, code="ACCOUNT_DISABLED") from exc
            raise self._redeem_public_error(exc) from exc
        self.db.audit_event("redeem.ok", row["id"], row["account"],
                            "plan=%s;days=%d" % (code_row["plan_id"], code_row["days"]),
                            self._log_origin())
        self.send_json(200, {
            "ok": True,
            "profile": self._profile(new_row),
            "redeemed": {"code": code_row["code"], "plan_name": code_row["plan_name"],
                         "days": code_row["days"]},
        })


    # ---- 管理接口 ----

    def _handle_admin_login(self):
        body = self._read_json()
        password = str(body.get("password") or "")
        if not password:
            raise ApiError(400, "请输入管理密码")
        if len(password) > MAX_PASSWORD_LEN:
            raise ApiError(400, "管理密码过长")
        ip = self._client_ip()
        cfg = self.cfg or {}
        key = "admin:" + ip
        remain = LIMITER.locked_remaining(key)
        if remain > 0:
            raise ApiError(429, "失败次数过多，请 %d 分钟后再试" % ((remain + 59) // 60))
        # 双键锁定（3-01）：单来源键 + 全局键。伪造来源只能绕开单来源那一层，
        # 全局总量仍受约束；不采信 XFF 时单来源键本身就是真实对端地址。
        global_key = "admin:global"
        global_limit = safe_int(cfg.get("admin_global_fails", ADMIN_GLOBAL_FAILS),
                                ADMIN_GLOBAL_FAILS, 1, 10000)
        if LIMITER.remaining_of("fail", global_key, global_limit,
                               ADMIN_GLOBAL_WINDOW) <= 0:
            self._log_error_safe("admin login globally locked (origin=%s)",
                                 self._log_origin())
            raise ApiError(429, "管理登录失败次数过多，请稍后再试", code="RATE_LIMITED")
        admin_hash, admin_salt = self._admin_credentials()
        if not verify_password(password, admin_salt, admin_hash):
            LIMITER.record_fail(key)
            LIMITER.allow("fail", global_key, global_limit, ADMIN_GLOBAL_WINDOW)
            self.db.audit_event("admin.login_failed", None, "", "", self._log_origin())
            raise ApiError(401, "管理密码错误")
        LIMITER.clear_fails(key)
        LIMITER.reset_bucket("fail", global_key)
        token = admin_create_session()
        self.db.audit_event("admin.login_ok", None, "", "", self._log_origin())
        self.send_json(200, {"admin_token": token, "expires_in": ADMIN_SESSION_TTL})

    def _admin_credentials(self):
        """3-10 的同一家族：server.json 被手工编辑过（删掉/截断 hash 字段）时，
        管理登录原来是 KeyError/bytes.fromhex 异常 → 裸 500 + stderr 栈。

        对外只给固定文案 + 机器可读 code（未鉴权的请求不该知道服务端配置内部形状）；
        【带字段名】的可操作提示写进服务端 stderr，运维照着补一句就能恢复。"""
        cfg = self.cfg or {}
        pw_hash = str(cfg.get("admin_password_hash") or "")
        salt = str(cfg.get("admin_password_salt") or "")
        bad = []
        if not pw_hash:
            bad.append("admin_password_hash 缺失")
        if not salt:
            bad.append("admin_password_salt 缺失")
        if not bad:
            try:
                bytes.fromhex(salt)
                bytes.fromhex(pw_hash)
            except ValueError:
                bad.append("admin_password_hash/salt 需为十六进制串（可能被截断或改过）")
        if bad:
            self._log_error_safe("管理员凭据不可用：%s。修复方式：删除 server.json 后重启即"
                                 "重新生成（用户数据不受影响），或用 %s 注入口令。",
                                 "；".join(bad), ADMIN_PASSWORD_ENV)
            raise ApiError(500, "服务端配置不完整", code="ADMIN_NOT_CONFIGURED")
        return pw_hash, salt


    def _handle_admin_overview(self):
        self._require_admin()
        now = now_i()
        db = self.db
        users_total = db.query_one("SELECT COUNT(*) AS n FROM users")["n"]
        valid_members = db.query_one(
            "SELECT COUNT(*) AS n FROM users WHERE disabled=0 AND ever_paid=1 AND paid_until>?", (now,))["n"]
        trial_users = db.query_one(
            "SELECT COUNT(*) AS n FROM users WHERE disabled=0 AND ever_paid=0 AND paid_until>?", (now,))["n"]
        disabled_users = db.query_one(
            "SELECT COUNT(*) AS n FROM users WHERE disabled=1")["n"]
        revenue_fen = db.query_one(
            "SELECT COALESCE(SUM(price_fen),0) AS s FROM redemptions")["s"]
        codes_unused = db.query_one(
            "SELECT COUNT(*) AS n FROM codes WHERE status='unused'")["n"]
        codes_used = db.query_one(
            "SELECT COUNT(*) AS n FROM codes WHERE status='used'")["n"]
        self.send_json(200, {
            "users_total": users_total,
            "valid_members": valid_members,
            "trial_users": trial_users,
            "disabled_users": disabled_users,
            "revenue_fen": revenue_fen,
            "revenue_yuan": round(revenue_fen / 100.0, 2),
            "codes_unused": codes_unused,
            "codes_used": codes_used,
        })

    def _handle_admin_users(self, qs):
        self._require_admin()
        q = clamp_text((qs.get("q") or [""])[0], MAX_QUERY_VALUE_LEN)
        sql = "SELECT * FROM users"
        params = []
        if q:
            # ESCAPE 转义：管理员输入 % 不再等于「筛出全量」（3-13）
            sql += r" WHERE account LIKE ? ESCAPE '\'"
            params.append("%" + like_escape(q) + "%")
        sql += " ORDER BY id DESC LIMIT 500"
        users = []
        for r in self.db.query_all(sql, tuple(params)):
            p = self._profile(r)
            p.update({
                "created_at_display": fmt_ts(r["created_at"]),
                "created_at_utc_iso": fmt_ts_utc(r["created_at"]),
                "status_label": "已禁用" if r["disabled"] else "正常",
            })
            users.append(p)
        self.send_json(200, {"users": users, "total": len(users)})

    def _handle_admin_grant(self):
        """客服补单 = 用户已在其他渠道付款，直接走与兑换相同的加时长逻辑。
        加时长、grants_log 记账、审计日志在同一事务内（3-06）：要么全部生效，
        要么整体回滚，不再出现「时长多了但查不到工单」。"""
        self._require_admin()
        body = self._read_json()
        user_id = self._require_int_arg(body, "user_id")
        days = self._require_int_arg(body, "days")
        if not 1 <= days <= 3650:
            raise ApiError(400, "补时长天数需在 1-3650 之间")
        note = clamp_text(body.get("note"), MAX_NOTE_LEN)
        new_until, _row = self.db.grant_days(user_id, days, "手动开通", note,
                                             self._log_origin())
        self.send_json(200, {"ok": True, "paid_until": new_until,
                             "paid_until_display": fmt_ts(new_until),
                             "paid_until_utc_iso": fmt_ts_utc(new_until)})

    def _require_int_arg(self, body, name):
        raw = body.get(name)
        if isinstance(raw, bool) or raw is None:
            raise ApiError(400, "参数 %s 无效" % name)
        if isinstance(raw, int):
            return raw
        text = str(raw).strip()
        if not re.match(r"^-?\d{1,10}$", text):
            raise ApiError(400, "参数 %s 无效" % name)
        return int(text)

    def _handle_admin_disable(self):
        self._require_admin()
        body = self._read_json()
        user_id = self._require_int_arg(body, "user_id")
        if "disabled" not in body:
            raise ApiError(400, "缺少参数 disabled")
        flag = bool_in(body.get("disabled"))
        revoke = bool_in(body.get("revoke_sessions")) or bool(
            (self.cfg or {}).get("revoke_sessions_on_disable"))
        # 禁用 + （可选）吊销会话 + 审计同事务；默认不吊销，保持既有「恢复后原 token
        # 仍可用」的行为（smoke/老管理流程依赖它），需要收紧时在后台勾选或配置打开。
        _user, revoked = self.db.set_user_disabled(user_id, flag, revoke,
                                                   self._log_origin())
        self.send_json(200, {"ok": True, "disabled": bool(flag),
                             "revoked_sessions": int(revoked)})

    def _handle_admin_revoke_sessions(self):
        """显式登出某账号的全部会话（新增接口，不影响既有路径）。"""
        self._require_admin()
        body = self._read_json()
        user_id = self._require_int_arg(body, "user_id")
        revoked = self.db.revoke_user_sessions(user_id, self._log_origin())
        self.send_json(200, {"ok": True, "revoked_sessions": int(revoked)})

    def _handle_admin_code_void(self):
        """卡密作废（批次外泄时的止损）：unused → void（新增接口）。"""
        self._require_admin()
        body = self._read_json()
        code = clamp_text(body.get("code"), 64).upper()
        if not code:
            raise ApiError(400, "请输入卡密")
        self.db.void_code(code, self._log_origin())
        self.send_json(200, {"ok": True, "code": code, "status": "void"})

    def _handle_admin_generate(self):
        self._require_admin()
        body = self._read_json()
        plan_id = clamp_text(body.get("plan_id"), 32)
        # 与 /api/plans 同一份清洗结果：坏档位不参与发卡，避免 generate_codes 里
        # int(plan["days"]) 抛 ValueError 变成裸 500（3-10 的同一族）。
        _plan_problems, usable_plans = sanitize_plans((self.cfg or {}).get("plans"))
        plan = next((p for p in usable_plans if p.get("id") == plan_id), None)
        if plan is None:
            raise ApiError(400, "档位不存在，请检查 plan_id")
        count = self._require_int_arg(body, "count")
        max_batch = safe_int((self.cfg or {}).get("max_codes_per_batch", 500), 500, 1, 500)
        if not 1 <= count <= max_batch:
            raise ApiError(400, "生成数量需在 1-%d 之间" % max_batch)
        note = clamp_text(body.get("note"), MAX_NOTE_LEN)
        batch_id = time.strftime("%Y%m%d%H%M%S") + "-" + secrets.token_hex(3)
        # 整批一个事务、一次提交（3-09）：不再逐条 commit 把写锁按住几百次，
        # 期间用户的 /api/me、/api/redeem 也不会被排队堵住。
        codes = self.db.generate_codes(plan, count, note, batch_id, self._log_origin())
        self.send_json(200, {
            "count": len(codes), "plan_id": plan["id"], "plan_name": plan["name"],
            "days": safe_int(plan.get("days"), 0, 0, 3650),
            "price_fen": safe_int(plan.get("price_fen"), 0, 0, 100000000),
            "price_display": price_display(plan["price_fen"]),
            "batch_id": batch_id, "codes": codes,
        })


    def _codes_query(self, qs):
        status = clamp_text((qs.get("status") or [""])[0], 16)
        if status and status not in ("unused", "used", "void"):
            raise ApiError(400, "卡密状态需为 unused、used 或 void", code="INVALID_STATUS")
        q = clamp_text((qs.get("q") or [""])[0], MAX_QUERY_VALUE_LEN).upper()
        sql = ("SELECT c.*, u.account AS used_by_account FROM codes c "
               "LEFT JOIN users u ON u.id = c.used_by")
        conds, params = [], []
        if status in ("unused", "used", "void"):
            conds.append("c.status=?")
            params.append(status)
        if q:
            conds.append(r"c.code LIKE ? ESCAPE '\'")
            params.append("%" + like_escape(q) + "%")
        if conds:
            sql += " WHERE " + " AND ".join(conds)
        sql += " ORDER BY c.id DESC LIMIT 1000"
        return self.db.query_all(sql, tuple(params))

    def _handle_admin_codes(self, qs):
        self._require_admin()
        codes = [{
            "id": r["id"], "code": r["code"],
            "plan_id": r["plan_id"], "plan_name": r["plan_name"],
            "days": r["days"], "price_fen": r["price_fen"],
            "price_display": price_display(r["price_fen"]),
            "note": r["note"], "batch_id": r["batch_id"],
            "status": r["status"],
            "status_label": code_status_label(r["status"]),
            "created_at": r["created_at"], "created_at_display": fmt_ts(r["created_at"]),
            "used_by_account": r["used_by_account"] or "",
            "used_at_display": fmt_ts(r["used_at"]) if r["used_at"] else "",
        } for r in self._codes_query(qs)]
        self.send_json(200, {"codes": codes, "total": len(codes)})

    def _handle_admin_codes_export(self, qs):
        self._require_admin()
        rows = self._codes_query(qs)
        buf = io.StringIO()
        buf.write("\ufeff")  # UTF-8 BOM，Excel 直接打开不乱码
        writer = csv.writer(buf)
        writer.writerow(["卡密", "档位", "天数", "面值(元)", "状态", "备注", "批次",
                         "生成时间", "使用者", "使用时间"])
        for r in rows:
            writer.writerow([
                csv_safe_cell(r["code"]), csv_safe_cell(r["plan_name"]), r["days"],
                "%.2f" % (r["price_fen"] / 100.0),
                code_status_label(r["status"]),
                csv_safe_cell(r["note"]), csv_safe_cell(r["batch_id"]),
                fmt_ts(r["created_at"]),
                csv_safe_cell(r["used_by_account"] or ""),
                fmt_ts(r["used_at"]) if r["used_at"] else "",
            ])
        filename = time.strftime("codes-%Y%m%d-%H%M%S") + ".csv"
        self._send(200, buf.getvalue().encode("utf-8"), "text/csv; charset=utf-8",
                   {"Content-Disposition": 'attachment; filename="%s"' % filename})

    def _handle_admin_redemptions(self):
        self._require_admin()
        out = [{
            "id": r["id"], "user_id": r["user_id"], "account": r["account"],
            "code": r["code"], "plan_id": r["plan_id"], "plan_name": r["plan_name"],
            "days": r["days"], "price_fen": r["price_fen"],
            "amount_display": price_display(r["price_fen"]),
            "created_at": r["created_at"], "created_at_display": fmt_ts(r["created_at"]),
        } for r in self.db.query_all(
            "SELECT * FROM redemptions ORDER BY id DESC LIMIT 1000")]
        self.send_json(200, {"redemptions": out, "total": len(out)})

    def _handle_admin_audit(self, qs):
        """新增只读接口：管理/安全审计（含兑换未命中的真实原因，用于识别码表泄漏）。
        不返回卡密明文全文，只留前缀 + 长度。"""
        self._require_admin()
        limit = safe_int((qs.get("limit") or ["200"])[0], 200, 1, 1000)
        action = clamp_text((qs.get("action") or [""])[0], 40)
        sql = "SELECT * FROM admin_audit"
        params = ()
        if action:
            sql += " WHERE action=?"
            params = (action,)
        sql += " ORDER BY id DESC LIMIT " + str(limit)   # limit 已收敛为整数，无注入面
        out = []
        for r in self.db.query_all(sql, params):
            detail = r["detail"] or ""
            out.append({
                "id": r["id"], "action": r["action"], "user_id": r["user_id"],
                "account": r["account"] or "",
                "detail": detail[:400], "origin": r["origin"] or "",
                "created_at": r["created_at"],
                "created_at_display": fmt_ts(r["created_at"]),
                "created_at_utc_iso": fmt_ts_utc(r["created_at"]),
            })
        self.send_json(200, {"audit": out, "total": len(out)})

    # ---- 日志 ----

    def log_message(self, fmt, *args):
        """访问日志脱敏（3-12）：URL 查询串里的 q/code/account 片段收敛成长度提示，
        来源默认只留 /24 网段。口令与 token 从不进日志（它们只在请求头/请求体里）。"""
        try:
            text = fmt % args
        except (TypeError, ValueError):
            text = str(args)
        text = redact_log_line(text)
        origin = self._client_ip_for_log() if self.cfg else self._peer_ip()
        sys.stdout.write("[%s] %s %s\n" % (time.strftime("%H:%M:%S"), origin, text))
        sys.stdout.flush()


# ---------------------------------------------------------------------------
# 后台清理线程：过期 token、限速表、管理会话、审计表容量
# ---------------------------------------------------------------------------

AUDIT_ROWS_MAX = 20000


def start_bg_cleanup(db):
    def loop():
        while True:
            time.sleep(600)
            try:
                db.execute("DELETE FROM tokens WHERE expires_at < ?", (now_i(),))
            except Exception:
                pass
            try:
                # 审计表只留最近 AUDIT_ROWS_MAX 行，避免无上限增长
                db.execute("DELETE FROM admin_audit WHERE id < "
                           "(SELECT COALESCE(MAX(id),0) - ? FROM admin_audit)",
                           (AUDIT_ROWS_MAX,))
            except Exception:
                pass
            try:
                admin_prune_sessions()
                with LIMITER.lock:
                    LIMITER.prune_locked()
            except Exception:
                pass
    t = threading.Thread(target=loop, daemon=True)
    t.start()
    return t


# ---------------------------------------------------------------------------
# HTTP 服务：并发工作线程上限
# ---------------------------------------------------------------------------

class TlsSetupError(RuntimeError):
    """证书/私钥不可用。区别于裸 SSL stack trace：部署现场看得懂、知道下一步做什么。"""


def build_tls_context(certfile, keyfile):
    """构造服务端 SSLContext（最低 TLS 1.2，关闭压缩以规避 CRIME）。

    `ssl` 只在这里 import：不配证书时整条默认路径不引入 TLS 栈，行为与旧版一致。
    """
    import ssl
    try:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    except (AttributeError, ValueError) as exc:      # 极老 stdlib 兜底
        raise TlsSetupError("本机 Python 不支持服务端 TLS 上下文（%r）；"
                            "请改由 Nginx/Caddy 反代提供 HTTPS。" % (exc,))
    try:
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    except (AttributeError, ValueError):
        pass                       # 老版本没有该属性时不因此拒绝启动（仍走系统默认）
    try:
        ctx.options |= ssl.OP_NO_COMPRESSION
    except (AttributeError, ValueError):
        pass
    try:
        ctx.load_cert_chain(certfile, keyfile)
    except Exception as exc:  # noqa: BLE001 SSLError/OSError/ValueError 都收敛成一条提示
        raise TlsSetupError(
            "TLS 证书或私钥无法装载（%s: %s），证书=%s 私钥=%s。"
            "请核对：文件是否为 PEM、私钥是否带口令、本进程是否有权读取私钥。"
            "已拒绝降级成明文启动。" % (exc.__class__.__name__, exc, certfile, keyfile))
    return ctx


class LimitedThreadingHTTPServer(ThreadingHTTPServer):
    """ThreadingHTTPServer 线程数无上限；配合 15 秒读超时仍可能被大批慢连接占满内存。
    这里加一个信号量：拿不到位子就在等待超时后直接关闭连接，而不是无限起线程。

    可选 TLS（3-19 的服务端那一半）：给出 cert/key 时用 SSLContext 包住监听 socket，
    默认不启用 —— 不配证书时行为与旧版完全一致（README 的 Nginx/Caddy 反代路径不变）。

    thread_finalizer：每条连接的工作线程结束前调用（用于归还该线程的 SQLite 读连接）。
    """

    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, addr, handler, max_workers=MAX_WORKERS,
                 acquire_timeout=WORKER_ACQUIRE_TIMEOUT,
                 certfile=None, keyfile=None, thread_finalizer=None):
        self.tls_certfile = certfile or None
        self.tls_keyfile = keyfile or None
        self.tls_context = None
        self.thread_finalizer = thread_finalizer
        ThreadingHTTPServer.__init__(self, addr, handler)
        self.request_semaphore = threading.BoundedSemaphore(max(1, int(max_workers)))
        self.worker_acquire_timeout = acquire_timeout

    def server_bind(self):
        # 顺序要紧：先让父类完成 SO_REUSEADDR + bind（含 port=0 时的地址回填），
        # 再包 TLS。反过来「先 wrap 再 bind」只是恰好能跑——它依赖 SSLSocket.bind
        # 转发到内部 _shared_socket 这一实现细节，跨 Python 版本不保证。
        ThreadingHTTPServer.server_bind(self)
        if self.tls_certfile:
            self.tls_context = build_tls_context(self.tls_certfile, self.tls_keyfile)
            self.socket = self.tls_context.wrap_socket(self.socket, server_side=True)

    def process_request_thread(self, request, client_address):
        acquired = self.request_semaphore.acquire(
            blocking=True, timeout=self.worker_acquire_timeout)
        if not acquired:
            self._log_overload(client_address)
            try:
                self.shutdown_request(request)   # 只关这一条连接，不影响其他请求
            except OSError:
                pass
            return
        try:
            ThreadingHTTPServer.process_request_thread(self, request, client_address)
        finally:
            self.request_semaphore.release()
            self._run_thread_finalizer()

    def _run_thread_finalizer(self):
        """本函数运行在【该连接的工作线程】里 —— 线程本地资源只能在这里归还。"""
        callback = self.thread_finalizer
        if callback is None:
            return
        try:
            callback()
        except Exception:   # noqa: BLE001 收尾失败绝不能影响服务
            pass

    @staticmethod
    def _log_overload(client_address):
        try:
            sys.stderr.write("[warn] 并发已达上限，关闭新连接 %s\n"
                             % (client_address[0] if client_address else "?",))
        except Exception:
            pass

    def handle_error(self, request, client_address):
        """stdlib 的实现会给每个出错连接打印完整 traceback：一条畸形连接一行噪声，
        公网部署下就是日志洪水（还能把内部栈留在被重定向的 stdout 里）。
        连接类错误压成一行；真正的程序缺陷仍然打印栈，便于运维定位。"""
        exc = sys.exc_info()[1]
        if isinstance(exc, (BrokenPipeError, ConnectionResetError, socket.timeout,
                            OSError)):
            try:
                sys.stderr.write("[warn] 连接异常结束 %s: %s\n"
                                 % (client_address[0] if client_address else "?",
                                    exc.__class__.__name__))
            except Exception:   # noqa: BLE001 日志本身失败不该再抛出
                pass
            return
        ThreadingHTTPServer.handle_error(self, request, client_address)



# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------

def public_bind_advisory(cfg, host, tls_enabled=False):
    """3-19 的第二半：非回环部署守卫。口径是【显式告警 + 显式开关，绝不阻断】——
    既有部署里「绑 0.0.0.0 直连」和「本机回环」都在跑，任何 hard-fail 都会让
    现网服务起不来，那比明文过网更糟。

    返回需要打印的行；下列情形返回空列表（完全静默，与今天一致）：
      - 绑定地址是回环（默认形态：127.0.0.1）；
      - 已启用 TLS（tls_cert_file / --certfile 生效），口令不再明文过网。

    allow_public_bind=true 的含义：运维显式确认「我知道这是公网明文，仍然要这样跑」，
    于是把长告警压成一行提示；不设该键时每次启动打完整告警。两种情况都继续启动。
    """
    cfg = cfg or {}
    if is_loopback_host(host) or tls_enabled:
        return []
    acknowledged = bool_in(cfg.get("allow_public_bind", False))
    if acknowledged:
        return [
            "  [提示] 非回环地址 %s + 明文 HTTP（allow_public_bind=true 已确认此配置）。" % host,
            "        口令/Bearer token/卡密仍会过网；随时可改配 tls_cert_file 或反代 https。",
        ]
    lines = [
        "=" * 64,
        "  [警告] 正在监听非回环地址 %s，且未启用 TLS。" % host,
        "  账号口令、Bearer token、卡密都会明文过网（3-19）。",
        "  建议：host 保持 127.0.0.1，由 Nginx/Caddy 反代对外提供 HTTPS；",
        "        或用 SSH 隧道访问管理后台。",
        "  也可以直接给本服务配证书：命令行 --certfile/--keyfile，",
        "        或 server.json 里的 tls_cert_file / tls_key_file。",
        "  如确需长期这样跑，请在 server.json 里显式设置 allow_public_bind=true，",
        "  表示已确认知悉该风险（设置后本告警收敛为一行；服务照常启动，不做拦截）。",
    ]
    if not cfg.get("trust_proxy_headers"):
        lines.append(
            "  注意：限速来源 = socket 对端地址。若你其实躲在反代之后，"
            "请设 trust_proxy_headers=true + trusted_proxies，"
            "否则所有真实用户会共用一个限速键。")
    lines.append("=" * 64)
    return lines


def main(argv=None):
    ap = argparse.ArgumentParser(description="QQ排程助手 商业化服务端")
    ap.add_argument("--host", default=None, help="监听地址，默认取配置或 127.0.0.1")
    ap.add_argument("--port", type=int, default=None, help="监听端口，默认取配置或 8790")
    ap.add_argument("--config", default=DEFAULT_CONFIG_PATH, help="配置文件路径")
    ap.add_argument("--data-dir", default=DEFAULT_DATA_DIR, help="数据目录（存放 billing.sqlite3）")
    ap.add_argument("--www-dir", default=DEFAULT_WWW_DIR, help="静态页面目录")
    ap.add_argument("--certfile", default=None, help="可选：TLS 证书 PEM（与 --keyfile 成对）")
    ap.add_argument("--keyfile", default=None, help="可选：TLS 私钥 PEM")
    args = ap.parse_args(argv)


    cfg = load_or_create_config(args.config, args.host or "127.0.0.1",
                                args.port or 8790, data_dir=args.data_dir)
    if args.certfile:
        cfg["tls_cert_file"] = args.certfile
    if args.keyfile:
        cfg["tls_key_file"] = args.keyfile
    problems, cfg = validate_config(cfg)      # 带字段名的告警 + 安全回退值
    for msg in problems:
        sys.stderr.write("[config] %s\n" % msg)
    host = args.host or cfg.get("host", "127.0.0.1")
    port = safe_int(cfg.get("port", 8790), 8790, 1, 65535)
    port = args.port or port
    tls_cert, tls_key = cfg.get("tls_cert_file", ""), cfg.get("tls_key_file", "")
    scheme = "https" if tls_cert else "http"


    db = Database(args.data_dir)
    for msg in db.integrity_notes():          # 数据卫生自检（3-13）：只告警，不改数据
        sys.stderr.write("[data] %s\n" % msg)

    BillingHandler.cfg = cfg
    BillingHandler.db = db
    BillingHandler.www_dir = args.www_dir
    BillingHandler.bind_host = host
    BillingHandler.bind_port = port
    BillingHandler.timeout = safe_int(cfg.get("conn_timeout_seconds", CONN_TIMEOUT_SECONDS),
                                      CONN_TIMEOUT_SECONDS, 3, 300)
    BillingHandler.max_body_bytes = safe_int(cfg.get("max_body_bytes", MAX_BODY_BYTES),
                                             MAX_BODY_BYTES, 1024, 16 * 1024 * 1024)
    start_bg_cleanup(db)

    for line in public_bind_advisory(cfg, host, bool(tls_cert)):
        print(line)
    sys.stdout.flush()

    try:
        server = LimitedThreadingHTTPServer((host, port), BillingHandler,
                                            max_workers=safe_int(
                                                cfg.get("max_workers", MAX_WORKERS),
                                                MAX_WORKERS, 4, 512),
                                            certfile=tls_cert or None,
                                            keyfile=tls_key or None,
                                            thread_finalizer=db.release_read_conn)
    except TlsSetupError as exc:
        # 证书配了却装不上：明确拒绝启动，绝不「静默降级成明文」——那正是 3-19 最怕的
        # 配置漂移（运维以为在跑 https）。回环/反代部署请把 tls_* 留空。
        sys.stderr.write("[fatal] %s\n" % exc)
        db.close()
        return 2
    print("=" * 64)
    print("  QQ排程助手 商业化服务端 已启动")
    print("  官网落地页 : %s://%s:%s/" % (scheme, host, port))
    print("  管理后台   : %s://%s:%s/admin" % (scheme, host, port))
    print("  数据库     : %s" % db.path)
    print("  配置文件   : %s" % args.config)
    print("  传输       : %s" % ("TLS（最低 TLS 1.2），证书 %s" % tls_cert
                                 if tls_cert else "明文 HTTP（仅回环/反代之后可接受）"))
    print("  读超时     : %ss；请求体上限 %sB；并发上限 %s"
          % (BillingHandler.timeout, BillingHandler.max_body_bytes,
             cfg.get("max_workers", MAX_WORKERS)))

    print("  限速来源   : %s" % ("可信反代之后的 X-Forwarded-For"
                                 if cfg.get("trust_proxy_headers")
                                 else "socket 对端地址（不采信 X-Forwarded-For）"))
    print("  按 Ctrl+C 停止")
    sys.stdout.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n正在停止…")
    finally:
        try:
            server.server_close()
        finally:
            db.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
