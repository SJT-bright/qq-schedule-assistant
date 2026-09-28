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
  配置  Server/server.json     （首次运行自动生成；admin 密码只在控制台打印一次）
  数据  Server/data/billing.sqlite3 （SQLite, WAL 模式，首次运行自动建表）

安全
  - 密码 PBKDF2-SHA256 200000 次迭代 + 每用户随机盐
  - token 只存 sha256 摘要，比较使用 hmac.compare_digest
  - 登录连错 5 次锁 15 分钟（按账号）；注册每 IP 每小时 10 次；管理登录同样限速

★ 真实支付接入预留点：全文件搜索 “PAY-GATEWAY”（见 add_paid_days 与 _handle_redeem）。
"""

import argparse
import csv
import hashlib
import hmac
import io
import json
import math
import os
import re
import secrets
import sqlite3
import sys
import threading
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
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
MAX_BODY_BYTES = 1 * 1024 * 1024     # 1MB
TRIAL_DAYS_DEFAULT = 3
TOKEN_TTL_DAYS_DEFAULT = 30
ADMIN_SESSION_TTL = 12 * 3600        # 管理后台会话 12 小时（滑动续期）

LOGIN_MAX_FAILS = 5                  # 登录连错 5 次
LOGIN_LOCK_SECONDS = 15 * 60         # 锁 15 分钟
REGISTER_LIMIT_PER_HOUR = 10         # 注册每 IP 每小时 10 次

ACCOUNT_RE = re.compile(r"^[A-Za-z0-9_@.]{4,40}$")
# 卡密字符集：去掉易混淆的 0/O/1/I/L
CODE_ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"

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


def fmt_ts(ts):
    if not ts:
        return "-"
    try:
        return datetime.fromtimestamp(int(ts)).strftime("%Y-%m-%d %H:%M:%S")
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


# ---------------------------------------------------------------------------
# 配置（Server/server.json）
# ---------------------------------------------------------------------------

def load_or_create_config(path, default_host="127.0.0.1", default_port=8790):
    """读取配置；文件不存在则生成默认配置并【只在控制台打印一次】admin 密码。"""
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as f:
            cfg = json.load(f)
        # 容错补齐缺失字段（用户手改配置的兜底）
        changed = False
        cfg.setdefault("host", default_host)
        cfg.setdefault("port", default_port)
        cfg.setdefault("trial_days", TRIAL_DAYS_DEFAULT)
        cfg.setdefault("token_ttl_days", TOKEN_TTL_DAYS_DEFAULT)
        if not cfg.get("plans"):
            cfg["plans"] = [dict(p) for p in DEFAULT_PLANS]
            changed = True
        if not cfg.get("admin_password_hash") or not cfg.get("admin_password_salt"):
            new_pw = _gen_admin_password()
            salt = secrets.token_hex(16)
            cfg["admin_password_hash"], _ = hash_password(new_pw, salt)
            cfg["admin_password_salt"] = salt
            changed = True
            _print_admin_password_banner(new_pw, cfg.get("host"), cfg.get("port"))
        if changed:
            _save_config(cfg, path)
        return cfg

    # 首次运行：随机生成管理员密码
    admin_password = _gen_admin_password()
    salt = secrets.token_hex(16)
    pw_hash, _ = hash_password(admin_password, salt)
    cfg = {
        "host": default_host,
        "port": default_port,
        "trial_days": TRIAL_DAYS_DEFAULT,
        "token_ttl_days": TOKEN_TTL_DAYS_DEFAULT,
        "admin_password_hash": pw_hash,
        "admin_password_salt": salt,
        "plans": [dict(p) for p in DEFAULT_PLANS],
    }
    _save_config(cfg, path)
    _print_admin_password_banner(admin_password, cfg["host"], cfg["port"])
    return cfg


def _save_config(cfg, path):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
        f.write("\n")
    try:
        os.chmod(path, 0o600)  # 含密码哈希，收紧文件权限
    except OSError:
        pass


def _print_admin_password_banner(password, host, port):
    print("=" * 64)
    print("  [QQ排程助手] 首次初始化完成，已生成管理员初始密码")
    print()
    print("  管理后台地址: http://%s:%s/admin" % (host, port))
    print("  管理员初始密码: %s" % password)
    print()
    print("  ※ 此密码【只在本次控制台打印一次】，请立即记录。")
    print("  ※ 忘记密码：删除 server.json 后重启服务端即可重置（用户数据不受影响）。")
    print("=" * 64)


# ---------------------------------------------------------------------------
# 数据库（SQLite + WAL）
# ---------------------------------------------------------------------------

class Database:
    def __init__(self, data_dir):
        os.makedirs(data_dir, exist_ok=True)
        self.path = os.path.join(data_dir, "billing.sqlite3")
        self.conn = sqlite3.connect(self.path, check_same_thread=False)
        self.conn.row_factory = sqlite3.Row
        # ThreadingHTTPServer 每请求一线程；单连接 + 全局锁串行化（本场景量级足够）
        self.lock = threading.RLock()
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
                    status     TEXT    NOT NULL DEFAULT 'unused',  -- unused / used
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
            """)
            self.conn.commit()

    # ---- 基础封装（全部串行化） ----

    def execute(self, sql, params=()):
        with self.lock:
            cur = self.conn.execute(sql, params)
            self.conn.commit()
            return cur

    def query_all(self, sql, params=()):
        with self.lock:
            return self.conn.execute(sql, params).fetchall()

    def query_one(self, sql, params=()):
        with self.lock:
            return self.conn.execute(sql, params).fetchone()

    # ---- 业务 ----

    def create_user(self, account, password, trial_days):
        now = now_i()
        pw_hash, salt = hash_password(password)
        paid_until = now + trial_days * DAY_SECONDS if trial_days and trial_days > 0 else None
        with self.lock:
            cur = self.conn.execute(
                "INSERT INTO users(account,password_hash,password_salt,paid_until,"
                "ever_paid,plan_label,disabled,created_at,updated_at)"
                " VALUES(?,?,?,?,0,NULL,0,?,?)",
                (account, pw_hash, salt, paid_until, now, now))
            self.conn.commit()
            return cur.lastrowid

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
        """
        with self.lock:
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
            self.conn.commit()
            return new_until

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
# 限速 / 锁定（内存实现，进程重启即清零）
# ---------------------------------------------------------------------------

class Limiter:
    def __init__(self):
        self.lock = threading.Lock()
        self.login_fails = {}   # key -> [连续失败次数, 锁定截止时间戳]
        self.reg_hits = {}      # ip -> [时间戳列表]

    def locked_remaining(self, key):
        with self.lock:
            e = self.login_fails.get(key)
            if e and e[1] > now_i():
                return e[1] - now_i()
            return 0

    def record_fail(self, key, max_fails=LOGIN_MAX_FAILS, lock_seconds=LOGIN_LOCK_SECONDS):
        with self.lock:
            e = self.login_fails.setdefault(key, [0, 0])
            e[0] += 1
            if e[0] >= max_fails:
                e[1] = now_i() + lock_seconds
                e[0] = 0  # 锁定期满后重新计数

    def clear_fails(self, key):
        with self.lock:
            self.login_fails.pop(key, None)

    def allow_register(self, ip, limit=REGISTER_LIMIT_PER_HOUR, window=3600):
        now = now_i()
        with self.lock:
            hits = [t for t in self.reg_hits.get(ip, []) if now - t < window]
            if len(hits) >= limit:
                self.reg_hits[ip] = hits
                return False
            hits.append(now)
            self.reg_hits[ip] = hits
            return True


LIMITER = Limiter()

# 管理后台会话：token 摘要 -> 过期时间（内存，重启后需重新登录）
ADMIN_SESSIONS = {}
ADMIN_LOCK = threading.Lock()


def admin_create_session():
    token = secrets.token_urlsafe(32)
    with ADMIN_LOCK:
        ADMIN_SESSIONS[sha256_hex(token)] = now_i() + ADMIN_SESSION_TTL
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

    # main() 注入
    cfg = None
    db = None
    www_dir = DEFAULT_WWW_DIR

    # ---- 路由 ----

    def do_GET(self):
        self._route("GET")

    def do_POST(self):
        self._route("POST")

    def _route(self, method):
        try:
            self._dispatch(method)
        except ApiError as e:
            payload = {"error": e.message}
            if e.code:
                payload["code"] = e.code
            self.send_json(e.status, payload)
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True
        except Exception as e:  # noqa: BLE001 兜底，避免线程崩溃无响应
            sys.stderr.write("[error] %s: %r\n" % (self.path, e))
            try:
                self.send_json(500, {"error": "服务器内部错误"})
            except Exception:
                self.close_connection = True

    def _dispatch(self, method):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        qs = parse_qs(parsed.query)

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
        else:  # POST
            if path == "/api/register":
                return self._handle_register()
            if path == "/api/login":
                return self._handle_login()
            if path == "/api/logout":
                return self._handle_logout()
            if path == "/api/redeem":
                return self._handle_redeem()
            if path == "/api/admin/login":
                return self._handle_admin_login()
            if path == "/api/admin/users/grant":
                return self._handle_admin_grant()
            if path == "/api/admin/users/disable":
                return self._handle_admin_disable()
            if path == "/api/admin/codes/generate":
                return self._handle_admin_generate()
        raise ApiError(404, "接口不存在")

    # ---- 响应 / 请求体 ----

    def _send(self, status, body, content_type, extra_headers=None):
        # 若请求体尚未读取，先排空，保证 HTTP/1.1 keep-alive 不串包
        if not getattr(self, "_body_read", False):
            try:
                length = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                length = 0
            if length > MAX_BODY_BYTES:
                self.close_connection = True  # 过大不读，直接断开
            elif length > 0:
                remaining = length
                while remaining > 0:
                    data = self.rfile.read(min(65536, remaining))
                    if not data:
                        break
                    remaining -= len(data)
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra_headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def send_json(self, status, obj, extra_headers=None):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self._send(status, body, "application/json; charset=utf-8", extra_headers)

    def _serve_page(self, filename):
        fp = os.path.join(self.www_dir, filename)
        try:
            with open(fp, "rb") as f:
                body = f.read()
        except OSError:
            raise ApiError(404, "页面文件缺失: Server/www/%s" % filename)
        self._send(200, body, "text/html; charset=utf-8")

    def _read_json(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if length > MAX_BODY_BYTES:
            raise ApiError(413, "请求体过大")
        raw = self.rfile.read(length) if length > 0 else b""
        self._body_read = True
        if not raw:
            return {}
        try:
            data = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            raise ApiError(400, "请求体不是合法 JSON")
        if not isinstance(data, dict):
            raise ApiError(400, "请求体应为 JSON 对象")
        return data

    def _client_ip(self):
        xff = self.headers.get("X-Forwarded-For", "")
        if xff:
            return xff.split(",")[0].strip()
        return self.client_address[0]

    # ---- 鉴权 ----

    def _bearer(self):
        h = self.headers.get("Authorization", "")
        if h.startswith("Bearer "):
            return h[7:].strip()
        return ""

    def _require_user(self):
        """校验 Bearer token；通过则返回用户行，并对快过期的 token 滑动续期。"""
        token = self._bearer()
        if not token:
            raise ApiError(401, "缺少登录凭证（Bearer token）")
        row, th = self.db.lookup_token(token)
        if row is None:
            raise ApiError(401, "登录已过期或凭证无效，请重新登录")
        ttl = int(self.cfg.get("token_ttl_days", TOKEN_TTL_DAYS_DEFAULT)) * DAY_SECONDS
        if ttl > 0 and row["token_expires"] - now_i() < ttl // 2:
            self.db.execute("UPDATE tokens SET expires_at=? WHERE token_hash=?",
                            (now_i() + ttl, th))
        return row

    def _require_admin(self):
        if not admin_check_session(self._bearer()):
            raise ApiError(401, "管理员未登录或登录已过期")

    # ---- profile ----

    def _profile(self, row):
        paid_until = row["paid_until"] or 0
        if row["ever_paid"]:
            label = row["plan_label"] or "会员"
        else:
            label = "试用版"
        return {
            "user_id": row["id"],
            "account": row["account"],
            "plan_label": label,
            "paid_until": paid_until,
            "paid_until_display": fmt_ts(paid_until) if paid_until else "-",
            "days_left": days_left_of(paid_until),
            "source": "paid" if row["ever_paid"] else "trial",
            "disabled": bool(row["disabled"]),
            "created_at": row["created_at"],
        }

    # ---- 公开接口 ----

    def _handle_plans(self):
        plans = [{
            "id": p["id"],
            "name": p["name"],
            "days": int(p["days"]),
            "price_fen": int(p["price_fen"]),
            "price_display": price_display(p["price_fen"]),
            "tagline": p.get("tagline", ""),
        } for p in self.cfg.get("plans", [])]
        self.send_json(200, plans)

    def _handle_register(self):
        body = self._read_json()
        account = str(body.get("account") or "").strip()
        password = str(body.get("password") or "")
        if not ACCOUNT_RE.match(account):
            raise ApiError(400, "账号需为 4-40 位字母/数字/下划线/@/. 的组合")
        if len(password) < 6:
            raise ApiError(400, "密码至少 6 位")
        if len(password) > 128:
            raise ApiError(400, "密码过长（≤128 位）")
        if not LIMITER.allow_register(self._client_ip()):
            raise ApiError(429, "注册过于频繁，请 1 小时后再试")
        if self.db.query_one("SELECT id FROM users WHERE account=?", (account,)):
            raise ApiError(409, "该账号已被注册")
        trial_days = int(self.cfg.get("trial_days", TRIAL_DAYS_DEFAULT))
        try:
            user_id = self.db.create_user(account, password, trial_days)
        except sqlite3.IntegrityError:
            raise ApiError(409, "该账号已被注册")
        token = self.db.create_token(user_id, self.cfg.get("token_ttl_days", TOKEN_TTL_DAYS_DEFAULT))
        row = self.db.query_one("SELECT * FROM users WHERE id=?", (user_id,))
        self.send_json(200, {"token": token, "profile": self._profile(row),
                             "trial_days": trial_days})

    def _handle_login(self):
        body = self._read_json()
        account = str(body.get("account") or "").strip()
        password = str(body.get("password") or "")
        if not account or not password:
            raise ApiError(400, "请输入账号与密码")
        key = "login:" + account.lower()
        remain = LIMITER.locked_remaining(key)
        if remain > 0:
            raise ApiError(429, "登录失败次数过多，请 %d 分钟后再试" % (remain // 60 + 1))
        row = self.db.query_one("SELECT * FROM users WHERE account=?", (account,))
        if row is None or not verify_password(password, row["password_salt"],
                                              row["password_hash"]):
            LIMITER.record_fail(key)
            raise ApiError(401, "账号或密码错误")
        if row["disabled"]:
            raise ApiError(403, "账号已被禁用，请联系管理员", code="ACCOUNT_DISABLED")
        LIMITER.clear_fails(key)
        token = self.db.create_token(row["id"], self.cfg.get("token_ttl_days", TOKEN_TTL_DAYS_DEFAULT))
        self.send_json(200, {"token": token, "profile": self._profile(row)})

    def _handle_logout(self):
        token = self._bearer()
        if token:
            self.db.execute("DELETE FROM tokens WHERE token_hash=?", (sha256_hex(token),))
        self.send_json(200, {"ok": True})

    def _handle_me(self):
        row = self._require_user()
        if row["disabled"]:
            raise ApiError(403, "账号已被禁用，请联系管理员", code="ACCOUNT_DISABLED")
        self.send_json(200, self._profile(row))

    def _handle_redeem(self):
        row = self._require_user()
        if row["disabled"]:
            raise ApiError(403, "账号已被禁用，无法兑换", code="ACCOUNT_DISABLED")
        body = self._read_json()
        code = str(body.get("code") or "").strip().upper()
        if not code:
            raise ApiError(400, "请输入卡密")

        code_row = self.db.query_one("SELECT * FROM codes WHERE code=?", (code,))
        if code_row is None:
            raise ApiError(404, "卡密不存在，请检查后重试", code="CODE_NOT_FOUND")
        if code_row["status"] != "unused":
            raise ApiError(409, "卡密已被使用", code="CODE_USED")
        # 原子核销（DB 全局锁串行化，rowcount 双保险）
        claimed = self.db.execute(
            "UPDATE codes SET status='used', used_by=?, used_at=? WHERE id=? AND status='unused'",
            (row["id"], now_i(), code_row["id"]))
        if claimed.rowcount != 1:
            raise ApiError(409, "卡密已被使用", code="CODE_USED")
        # 收入记账（管理后台「累计兑换收入」来源）
        self.db.execute(
            "INSERT INTO redemptions(user_id,account,code,plan_id,plan_name,days,price_fen,created_at)"
            " VALUES(?,?,?,?,?,?,?,?)",
            (row["id"], row["account"], code_row["code"], code_row["plan_id"],
             code_row["plan_name"], code_row["days"], code_row["price_fen"], now_i()))
        # ★ PAY-GATEWAY：真实支付回调成功后同样调用 add_paid_days（见其文档注释）
        self.db.add_paid_days(row["id"], code_row["days"],
                              "%s会员" % code_row["plan_name"], is_purchase=True)
        new_row = self.db.query_one("SELECT * FROM users WHERE id=?", (row["id"],))
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
        ip = self._client_ip()
        key = "admin:" + ip
        remain = LIMITER.locked_remaining(key)
        if remain > 0:
            raise ApiError(429, "失败次数过多，请 %d 分钟后再试" % (remain // 60 + 1))
        if not verify_password(password, self.cfg["admin_password_salt"],
                               self.cfg["admin_password_hash"]):
            LIMITER.record_fail(key)
            raise ApiError(401, "管理密码错误")
        LIMITER.clear_fails(key)
        token = admin_create_session()
        self.send_json(200, {"admin_token": token, "expires_in": ADMIN_SESSION_TTL})

    def _handle_admin_overview(self):
        self._require_admin()
        now = now_i()
        db = self.db
        users_total = db.query_one("SELECT COUNT(*) AS n FROM users")["n"]
        valid_members = db.query_one(
            "SELECT COUNT(*) AS n FROM users WHERE ever_paid=1 AND paid_until>?", (now,))["n"]
        trial_users = db.query_one(
            "SELECT COUNT(*) AS n FROM users WHERE ever_paid=0 AND paid_until>?", (now,))["n"]
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
        q = (qs.get("q") or [""])[0].strip()
        sql = "SELECT * FROM users"
        params = []
        if q:
            sql += " WHERE account LIKE ?"
            params.append("%" + q + "%")
        sql += " ORDER BY id DESC LIMIT 500"
        users = []
        for r in self.db.query_all(sql, tuple(params)):
            p = self._profile(r)
            p.update({
                "created_at_display": fmt_ts(r["created_at"]),
                "status_label": "已禁用" if r["disabled"] else "正常",
            })
            users.append(p)
        self.send_json(200, {"users": users, "total": len(users)})

    def _handle_admin_grant(self):
        self._require_admin()
        body = self._read_json()
        try:
            user_id = int(body.get("user_id"))
        except (TypeError, ValueError):
            raise ApiError(400, "参数 user_id 无效")
        try:
            days = int(body.get("days"))
        except (TypeError, ValueError):
            raise ApiError(400, "参数 days 无效")
        if not 1 <= days <= 3650:
            raise ApiError(400, "补时长天数需在 1-3650 之间")
        note = str(body.get("note") or "").strip()
        user = self.db.query_one("SELECT * FROM users WHERE id=?", (user_id,))
        if user is None:
            raise ApiError(404, "用户不存在")
        # 客服补单 = 用户已在其他渠道付款，直接走与兑换相同的加时长逻辑
        new_until = self.db.add_paid_days(user_id, days, "手动开通", is_purchase=True)
        self.db.execute(
            "INSERT INTO grants_log(user_id,account,days,note,created_at) VALUES(?,?,?,?,?)",
            (user_id, user["account"], days, note, now_i()))
        self.send_json(200, {"ok": True, "paid_until": new_until,
                             "paid_until_display": fmt_ts(new_until)})

    def _handle_admin_disable(self):
        self._require_admin()
        body = self._read_json()
        try:
            user_id = int(body.get("user_id"))
        except (TypeError, ValueError):
            raise ApiError(400, "参数 user_id 无效")
        flag = 1 if body.get("disabled") in (True, 1, "1", "true", "True") else 0
        cur = self.db.execute("UPDATE users SET disabled=?, updated_at=? WHERE id=?",
                              (flag, now_i(), user_id))
        if cur.rowcount == 0:
            raise ApiError(404, "用户不存在")
        self.send_json(200, {"ok": True, "disabled": bool(flag)})

    def _handle_admin_generate(self):
        self._require_admin()
        body = self._read_json()
        plan_id = str(body.get("plan_id") or "")
        plan = next((p for p in self.cfg.get("plans", []) if p["id"] == plan_id), None)
        if plan is None:
            raise ApiError(400, "档位不存在，请检查 plan_id")
        try:
            count = int(body.get("count"))
        except (TypeError, ValueError):
            raise ApiError(400, "参数 count 无效")
        if not 1 <= count <= 500:
            raise ApiError(400, "生成数量需在 1-500 之间")
        note = str(body.get("note") or "").strip()
        letter = plan_letter(plan["id"])
        batch_id = time.strftime("%Y%m%d%H%M%S") + "-" + secrets.token_hex(3)
        codes = []
        with self.db.lock:
            for _ in range(count):
                made = None
                for _attempt in range(20):
                    candidate = gen_code(letter)
                    try:
                        self.db.execute(
                            "INSERT INTO codes(code,plan_id,plan_name,days,price_fen,note,batch_id,status,created_at)"
                            " VALUES(?,?,?,?,?,?,?,'unused',?)",
                            (candidate, plan["id"], plan["name"], int(plan["days"]),
                             int(plan["price_fen"]), note, batch_id, now_i()))
                        made = candidate
                        break
                    except sqlite3.IntegrityError:
                        continue  # 极小概率撞码，重试
                if made is None:
                    raise ApiError(500, "卡密生成冲突，请重试")
                codes.append(made)
        self.send_json(200, {
            "count": len(codes), "plan_id": plan["id"], "plan_name": plan["name"],
            "days": int(plan["days"]), "price_fen": int(plan["price_fen"]),
            "price_display": price_display(plan["price_fen"]),
            "batch_id": batch_id, "codes": codes,
        })

    def _codes_query(self, qs):
        status = (qs.get("status") or [""])[0].strip()
        q = (qs.get("q") or [""])[0].strip().upper()
        sql = ("SELECT c.*, u.account AS used_by_account FROM codes c "
               "LEFT JOIN users u ON u.id = c.used_by")
        conds, params = [], []
        if status in ("unused", "used"):
            conds.append("c.status=?")
            params.append(status)
        if q:
            conds.append("c.code LIKE ?")
            params.append("%" + q + "%")
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
            "status_label": "已使用" if r["status"] == "used" else "未使用",
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
                r["code"], r["plan_name"], r["days"], "%.2f" % (r["price_fen"] / 100.0),
                "已使用" if r["status"] == "used" else "未使用",
                r["note"], r["batch_id"], fmt_ts(r["created_at"]),
                r["used_by_account"] or "", fmt_ts(r["used_at"]) if r["used_at"] else "",
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

    # ---- 日志 ----

    def log_message(self, fmt, *args):
        sys.stdout.write("[%s] %s %s\n" % (
            time.strftime("%H:%M:%S"), self.client_address[0], fmt % args))
        sys.stdout.flush()


# ---------------------------------------------------------------------------
# 后台清理线程：定期删除过期 token
# ---------------------------------------------------------------------------

def start_bg_cleanup(db):
    def loop():
        while True:
            time.sleep(600)
            try:
                db.execute("DELETE FROM tokens WHERE expires_at < ?", (now_i(),))
            except Exception:
                pass
    t = threading.Thread(target=loop, daemon=True)
    t.start()


# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(description="QQ排程助手 商业化服务端")
    ap.add_argument("--host", default=None, help="监听地址，默认取配置或 127.0.0.1")
    ap.add_argument("--port", type=int, default=None, help="监听端口，默认取配置或 8790")
    ap.add_argument("--config", default=DEFAULT_CONFIG_PATH, help="配置文件路径")
    ap.add_argument("--data-dir", default=DEFAULT_DATA_DIR, help="数据目录（存放 billing.sqlite3）")
    ap.add_argument("--www-dir", default=DEFAULT_WWW_DIR, help="静态页面目录")
    args = ap.parse_args(argv)

    cfg = load_or_create_config(args.config, args.host or "127.0.0.1",
                                args.port or 8790)
    host = args.host or cfg.get("host", "127.0.0.1")
    port = args.port or int(cfg.get("port", 8790))

    db = Database(args.data_dir)
    start_bg_cleanup(db)

    BillingHandler.cfg = cfg
    BillingHandler.db = db
    BillingHandler.www_dir = args.www_dir

    server = ThreadingHTTPServer((host, port), BillingHandler)
    print("=" * 64)
    print("  QQ排程助手 商业化服务端 已启动")
    print("  官网落地页 : http://%s:%s/" % (host, port))
    print("  管理后台   : http://%s:%s/admin" % (host, port))
    print("  数据库     : %s" % db.path)
    print("  配置文件   : %s" % args.config)
    print("  按 Ctrl+C 停止")
    print("=" * 64)
    sys.stdout.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n正在停止…")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
