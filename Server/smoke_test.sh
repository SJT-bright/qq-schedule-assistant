#!/usr/bin/env bash
# ============================================================================
# QQ排程助手 服务端 · 冒烟测试
#   - 随机端口 + 临时数据目录/临时配置启动服务端
#   - 走通: 管理登录 → 批量生成3张月卡 → 注册(送试用) → /api/me → 兑换(+30天)
#           → 重复兑换/不存在卡密/错误密码/无token 全部被正确拒绝 → 管理统计对账
# 用法: bash smoke_test.sh
# ============================================================================
set -uo pipefail

SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_PY="${SERVER_DIR}/server.py"

TMP_DIR="$(mktemp -d /tmp/qp_smoke.XXXXXX)"
RESP="${TMP_DIR}/last_resp"
SERVER_PID=""
trap 'kill "${SERVER_PID}" 2>/dev/null || true; wait "${SERVER_PID}" 2>/dev/null; rm -rf "${TMP_DIR}"' EXIT

PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# 从 JSON 文件取字段: jget <file> <key>；jgetp <file> <a>.<b> 支持一层嵌套
jget()  { python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d.get(sys.argv[2],""))' "$1" "$2"; }
jgetp() { python3 -c 'import json,sys;a,b=sys.argv[2].split(".");d=json.load(open(sys.argv[1]));print(d[a][b])' "$1" "$2"; }

# 期望 HTTP 状态码: expect_status <描述> <期望码> <METHOD> <URL> [json数据] [token]
expect_status() {
  local desc="${1}" expected="${2}" method="${3}" url="${4}" data="${5:-}" token="${6:-}"
  local args=(-s -o "${RESP}" -w '%{http_code}' -X "${method}" "${url}")
  [ -n "${token}" ] && args+=(-H "Authorization: Bearer ${token}")
  [ -n "${data}" ]  && args+=(-H "Content-Type: application/json" -d "${data}")
  local code
  code="$(curl "${args[@]}" 2>/dev/null)"
  if [ "${code}" = "${expected}" ]; then
    ok "${desc} (HTTP ${code})"
  else
    fail "${desc} -- 期望 HTTP ${expected}，实际 HTTP ${code}，响应: $(head -c 200 "${RESP}" 2>/dev/null)"
  fi
}

echo "==> 冒烟测试开始"
echo "==> 临时目录: ${TMP_DIR}"

# ---------- 启动服务端（随机端口 + 临时数据目录） ----------
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
LOG="${TMP_DIR}/server.log"
BASE="http://127.0.0.1:${PORT}"
echo "==> 启动服务端: 端口 ${PORT}"

python3 "${SERVER_PY}" --host 127.0.0.1 --port "${PORT}" \
  --config "${TMP_DIR}/server.json" --data-dir "${TMP_DIR}/data" >"${LOG}" 2>&1 &
SERVER_PID=$!

# 等待就绪（最多 10 秒）
ready=""
for _ in $(seq 1 50); do
  if curl -fsS "${BASE}/api/plans" >/dev/null 2>&1; then ready=1; break; fi
  sleep 0.2
done
if [ -z "${ready}" ]; then
  echo "FAIL: 服务端未在 10 秒内就绪，服务端日志如下："
  cat "${LOG}"
  exit 1
fi
ok "服务端启动并就绪（随机端口 ${PORT}）"

# ---------- 1. 页面与公开接口 ----------
expect_status "官网落地页可访问" 200 GET "${BASE}/"
expect_status "管理后台页面可访问" 200 GET "${BASE}/admin"
curl -fsS "${BASE}/api/plans" >"${RESP}"
PLAN_COUNT="$(python3 -c "import json;print(len(json.load(open('${RESP}'))))")"
if [ "${PLAN_COUNT}" = "3" ]; then ok "/api/plans 返回 3 个档位"; else fail "/api/plans 档位数=${PLAN_COUNT}（期望 3）"; fi
MONTH_FEN="$(python3 -c "import json;print([p['price_fen'] for p in json.load(open('${RESP}')) if p['id']=='month'][0])")"
if [ "${MONTH_FEN}" = "990" ]; then ok "月卡价格 990 分（¥9.9）"; else fail "月卡价格=${MONTH_FEN}（期望 990）"; fi

# ---------- 2. 管理员登录（密码取自服务端首次运行的控制台输出） ----------
ADMIN_PW="$(sed -n 's/.*管理员初始密码: \([A-Za-z0-9]*\).*/\1/p' "${LOG}" | head -n1)"
if [ -n "${ADMIN_PW}" ]; then
  ok "从控制台日志捕获到 admin 初始密码（长度 ${#ADMIN_PW}）"
else
  echo "FAIL: 未从日志取得 admin 密码，服务端日志如下："; cat "${LOG}"; exit 1
fi
expect_status "错误管理密码被拒绝" 401 POST "${BASE}/api/admin/login" '{"password":"wrong-password"}'
curl -fsS -X POST "${BASE}/api/admin/login" -H "Content-Type: application/json" -d "{\"password\":\"${ADMIN_PW}\"}" >"${RESP}"
ADMIN_TOKEN="$(jget "${RESP}" admin_token)"
if [ -n "${ADMIN_TOKEN}" ]; then ok "管理登录成功，拿到 admin_token"; else fail "管理登录失败: $(cat "${RESP}")"; exit 1; fi
AH="Authorization: Bearer ${ADMIN_TOKEN}"

# ---------- 3. 批量生成 3 张月卡卡密 ----------
curl -fsS -X POST "${BASE}/api/admin/codes/generate" -H "${AH}" -H "Content-Type: application/json" \
  -d '{"plan_id":"month","count":3,"note":"smoke-test"}' >"${RESP}"
GEN_N="$(jget "${RESP}" count)"
CODE1="$(python3 -c "import json;print(json.load(open('${RESP}'))['codes'][0])")"
CODE2="$(python3 -c "import json;print(json.load(open('${RESP}'))['codes'][1])")"
if [ "${GEN_N}" = "3" ]; then ok "批量生成 3 张月卡卡密"; else fail "生成卡密数=${GEN_N}（期望 3）"; fi
case "${CODE1}" in
  QP-M-????-????) ok "卡密格式符合 QP-M-XXXX-XXXX（如 ${CODE1}）" ;;
  *) fail "卡密格式不符: ${CODE1}" ;;
esac
if [ "${CODE1}" != "${CODE2}" ]; then ok "卡密互不重复"; else fail "卡密重复: ${CODE1}"; fi

# ---------- 4. 注册（送 3 天试用） ----------
ACC="u${RANDOM}${RANDOM}"
curl -fsS -X POST "${BASE}/api/register" -H "Content-Type: application/json" \
  -d "{\"account\":\"${ACC}\",\"password\":\"test123456\"}" >"${RESP}"
TOKEN="$(jget "${RESP}" token)"
DAYS_BEFORE="$(jgetp "${RESP}" profile.days_left)"
if [ -n "${TOKEN}" ]; then ok "注册成功并返回 token（账号 ${ACC}）"; else fail "注册失败: $(cat "${RESP}")"; exit 1; fi
if [ "${DAYS_BEFORE}" = "3" ]; then ok "新用户自动获得 3 天试用（days_left=${DAYS_BEFORE}）"; else fail "试用天数=${DAYS_BEFORE}（期望 3）"; fi
TH="Authorization: Bearer ${TOKEN}"

expect_status "同账号重复注册被拒绝(409)" 409 POST "${BASE}/api/register" "{\"account\":\"${ACC}\",\"password\":\"test123456\"}"
expect_status "非法账号名被拒绝(400)" 400 POST "${BASE}/api/register" '{"account":"a","password":"test123456"}'

# ---------- 5. /api/me（试用态） ----------
curl -fsS "${BASE}/api/me" -H "${TH}" >"${RESP}"
ME_SRC="$(jget "${RESP}" source)"
ME_ACC="$(jget "${RESP}" account)"
if [ "${ME_SRC}" = "trial" ] && [ "${ME_ACC}" = "${ACC}" ]; then
  ok "/api/me 返回 source=trial 且账号正确"
else
  fail "/api/me 异常: source=${ME_SRC} account=${ME_ACC}"
fi

# ---------- 6. 兑换月卡（应 +30 天） ----------
curl -fsS -X POST "${BASE}/api/redeem" -H "${TH}" -H "Content-Type: application/json" \
  -d "{\"code\":\"${CODE1}\"}" >"${RESP}"
DAYS_AFTER="$(jgetp "${RESP}" profile.days_left)"
NEW_SRC="$(jgetp "${RESP}" profile.source)"
DELTA=$((DAYS_AFTER - DAYS_BEFORE))
if [ "${DELTA}" -eq 30 ]; then
  ok "兑换月卡后时长 +30 天（${DAYS_BEFORE} → ${DAYS_AFTER}）"
else
  fail "兑换后时长增量=${DELTA}（期望 30），before=${DAYS_BEFORE} after=${DAYS_AFTER}"
fi
if [ "${NEW_SRC}" = "paid" ]; then ok "兑换后 source 变为 paid"; else fail "兑换后 source=${NEW_SRC}（期望 paid）"; fi
PLAN_LABEL="$(jgetp "${RESP}" profile.plan_label)"
if [ "${PLAN_LABEL}" = "月卡会员" ]; then ok "plan_label = 月卡会员"; else fail "plan_label=${PLAN_LABEL}（期望 月卡会员）"; fi

# ---------- 7. 兑换错误分支 ----------
expect_status "同一张卡密二次兑换被拒绝(409 已被使用)" 409 POST "${BASE}/api/redeem" "{\"code\":\"${CODE1}\"}" "${TOKEN}"
expect_status "不存在的卡密返回 404" 404 POST "${BASE}/api/redeem" '{"code":"QP-M-0000-0000"}' "${TOKEN}"
expect_status "未登录兑换被拒绝(401)" 401 POST "${BASE}/api/redeem" "{\"code\":\"${CODE2}\"}"

# ---------- 8. 鉴权错误分支 ----------
expect_status "错误密码登录被拒绝(401)" 401 POST "${BASE}/api/login" "{\"account\":\"${ACC}\",\"password\":\"wrong-pass\"}"
expect_status "未带 token 访问 /api/me 被拒绝(401)" 401 GET "${BASE}/api/me"
expect_status "伪造 token 访问 /api/me 被拒绝(401)" 401 GET "${BASE}/api/me" "" "Bearer fake.token.value"

# ---------- 9. 禁用 / 恢复账号 ----------
curl -fsS "${BASE}/api/me" -H "${TH}" >"${RESP}"
USER_ID="$(jget "${RESP}" user_id)"
curl -fsS -X POST "${BASE}/api/admin/users/disable" -H "${AH}" -H "Content-Type: application/json" \
  -d "{\"user_id\":${USER_ID},\"disabled\":true}" >"${RESP}"
expect_status "禁用后 /api/me 返回 403" 403 GET "${BASE}/api/me" "" "${TOKEN}"
expect_status "禁用后兑换返回 403 账号被禁用" 403 POST "${BASE}/api/redeem" "{\"code\":\"${CODE2}\"}" "${TOKEN}"
if grep -q "ACCOUNT_DISABLED" "${RESP}"; then
  ok "禁用兑换错误码为 ACCOUNT_DISABLED（与卡密错误区分）"
else
  fail "未返回 ACCOUNT_DISABLED 错误码"
fi
curl -fsS -X POST "${BASE}/api/admin/users/disable" -H "${AH}" -H "Content-Type: application/json" \
  -d "{\"user_id\":${USER_ID},\"disabled\":false}" >"${RESP}"
expect_status "恢复后 /api/me 正常(200)" 200 GET "${BASE}/api/me" "" "${TOKEN}"

# ---------- 10. 管理端统计对账（1 用户 1 会员 收入 ¥9.9 卡密 2未用1已用） ----------
curl -fsS "${BASE}/api/admin/overview" -H "${AH}" >"${RESP}"
OV_USERS="$(jget "${RESP}" users_total)"; OV_MEMBERS="$(jget "${RESP}" valid_members)"
OV_REV="$(jget "${RESP}" revenue_yuan)";  OV_UNUSED="$(jget "${RESP}" codes_unused)"
OV_USED="$(jget "${RESP}" codes_used)"
if [ "${OV_USERS}" = "1" ]; then ok "概览: 用户总数=1"; else fail "概览: 用户总数=${OV_USERS}（期望 1）"; fi
if [ "${OV_MEMBERS}" = "1" ]; then ok "概览: 有效会员=1"; else fail "概览: 有效会员=${OV_MEMBERS}（期望 1）"; fi
if python3 -c "import sys;sys.exit(0 if abs(float('${OV_REV}')-9.9)<0.001 else 1)"; then
  ok "概览: 累计兑换收入=¥9.90"
else
  fail "概览: 累计收入=${OV_REV}（期望 9.9）"
fi
if [ "${OV_UNUSED}" = "2" ]; then ok "概览: 未用卡密=2"; else fail "概览: 未用卡密=${OV_UNUSED}（期望 2）"; fi
if [ "${OV_USED}" = "1" ]; then ok "概览: 已用卡密=1"; else fail "概览: 已用卡密=${OV_USED}（期望 1）"; fi

# ---------- 11. 卡密列表 / CSV 导出 / 兑换记录 / 用户补时长 ----------
curl -fsS "${BASE}/api/admin/codes?status=unused" -H "${AH}" >"${RESP}"
UNUSED_N="$(jget "${RESP}" total)"
if [ "${UNUSED_N}" = "2" ]; then ok "卡密列表(未使用)共 2 张"; else fail "未使用卡密数=${UNUSED_N}（期望 2）"; fi

code="$(curl -s -o "${RESP}" -w '%{http_code}' "${BASE}/api/admin/codes/export?status=unused" -H "${AH}")"
if [ "${code}" = "200" ] && grep -q "QP-M-" "${RESP}"; then
  ok "卡密 CSV 导出成功且包含卡密"
else
  fail "CSV 导出异常: HTTP=${code}"
fi

curl -fsS "${BASE}/api/admin/redemptions" -H "${AH}" >"${RESP}"
RED_N="$(jget "${RESP}" total)"
RED_ACC="$(python3 -c "import json;print(json.load(open('${RESP}'))['redemptions'][0]['account'])")"
if [ "${RED_N}" = "1" ] && [ "${RED_ACC}" = "${ACC}" ]; then
  ok "兑换记录 1 条且账号正确"
else
  fail "兑换记录: total=${RED_N} account=${RED_ACC}"
fi

curl -fsS -X POST "${BASE}/api/admin/users/grant" -H "${AH}" -H "Content-Type: application/json" \
  -d "{\"user_id\":${USER_ID},\"days\":7,\"note\":\"客服补单测试\"}" >"${RESP}"
G_OK="$(jget "${RESP}" ok)"
curl -fsS "${BASE}/api/me" -H "${TH}" >"${RESP}"
DAYS_GRANT="$(jget "${RESP}" days_left)"
if [ "${G_OK}" = "True" ] && [ "${DAYS_GRANT}" = "$((DAYS_AFTER + 7))" ]; then
  ok "客服补单 +7 天生效（days_left=${DAYS_GRANT}）"
else
  fail "补单异常: ok=${G_OK} days_left=${DAYS_GRANT}（期望 $((DAYS_AFTER + 7))）"
fi

# ---------- 12. 登录连续失败 5 次锁定 ----------
for _ in 1 2 3 4 5; do
  curl -s -o /dev/null -X POST "${BASE}/api/login" -H "Content-Type: application/json" \
    -d "{\"account\":\"${ACC}\",\"password\":\"bad-pass\"}"
done
expect_status "连错 5 次后正确密码也被锁定(429)" 429 POST "${BASE}/api/login" "{\"account\":\"${ACC}\",\"password\":\"test123456\"}"

# ---------- 汇总 ----------
echo
echo "=============================================================="
if [ "${FAIL}" -eq 0 ]; then
  echo "  ALL PASS -- 共 ${PASS} 项检查全部通过"
  echo "=============================================================="
  exit 0
else
  echo "  FAILED -- 通过 ${PASS} 项，失败 ${FAIL} 项。服务端日志: ${LOG}"
  echo "--------------------------------------------------------------"
  tail -n 40 "${LOG}"
  exit 1
fi
