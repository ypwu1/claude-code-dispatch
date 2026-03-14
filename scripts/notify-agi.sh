#!/bin/bash
# Claude Code Stop Hook: 任务完成后通知 AGI
# 触发时机: Stop (生成停止) + SessionEnd (会话结束)
# 支持 Agent Teams: lead 完成后自动触发

set -uo pipefail

LOG="/home/ubuntu/clawd/data/claude-code-results/hook.log"
RESULT_DIR="/home/ubuntu/clawd/data/claude-code-results"
META_FILE="${RESULT_DIR}/task-meta.json"
OPENCLAW_BIN="/home/ubuntu/.npm-global/bin/openclaw"

mkdir -p "$RESULT_DIR"

log() { echo "[$(date -Iseconds)] $*" >> "$LOG"; }

log "=== Hook fired ==="

# ---- 读 stdin ----
INPUT=""
if [ -t 0 ]; then
    log "stdin is tty, skip"
elif [ -e /dev/stdin ]; then
    INPUT=$(timeout 2 cat /dev/stdin 2>/dev/null || true)
fi

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")
CWD=$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null || echo "")
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // "unknown"' 2>/dev/null || echo "unknown")

log "session=$SESSION_ID cwd=$CWD event=$EVENT"

# ---- 防重复：只处理第一个事件（Stop），跳过后续的 SessionEnd ----
LOCK_FILE="${RESULT_DIR}/.hook-lock"
LOCK_AGE_LIMIT=30  # 30秒内重复触发视为同一任务

if [ -f "$LOCK_FILE" ]; then
    LOCK_TIME=$(stat -c %Y "$LOCK_FILE" 2>/dev/null || echo 0)
    NOW=$(date +%s)
    AGE=$(( NOW - LOCK_TIME ))
    if [ "$AGE" -lt "$LOCK_AGE_LIMIT" ]; then
        log "Duplicate hook within ${AGE}s, skipping"
        exit 0
    fi
fi
touch "$LOCK_FILE"

# ---- 读取 Claude Code 输出 ----
OUTPUT=""

# 等待 tee 管道 flush（hook 可能在 pipe 写完前触发）
sleep 1

# 来源1: task-output.txt (dispatch 脚本 tee 写入)
TASK_OUTPUT="${RESULT_DIR}/task-output.txt"
if [ -f "$TASK_OUTPUT" ] && [ -s "$TASK_OUTPUT" ]; then
    OUTPUT=$(tail -c 4000 "$TASK_OUTPUT")
    log "Output from task-output.txt (${#OUTPUT} chars)"
fi

# 来源2: /tmp/claude-code-output.txt
if [ -z "$OUTPUT" ] && [ -f "/tmp/claude-code-output.txt" ] && [ -s "/tmp/claude-code-output.txt" ]; then
    OUTPUT=$(tail -c 4000 /tmp/claude-code-output.txt)
    log "Output from /tmp fallback (${#OUTPUT} chars)"
fi

# 来源3: 工作目录
if [ -z "$OUTPUT" ] && [ -n "$CWD" ] && [ -d "$CWD" ]; then
    FILES=$(ls -1t "$CWD" 2>/dev/null | head -20 | tr '\n' ', ')
    OUTPUT="Working dir: ${CWD}\nFiles: ${FILES}"
    log "Output from dir listing"
fi

# ---- 读取任务元数据（仅当 meta 文件足够新时才信任）----
TASK_NAME="unknown"
TELEGRAM_GROUP=""

if [ -f "$META_FILE" ]; then
    # 检查 meta 文件是否在最近 2 小时内写入（防止复用旧任务的 meta）
    META_AGE=$(( $(date +%s) - $(stat -c %Y "$META_FILE" 2>/dev/null || echo 0) ))
    if [ "$META_AGE" -gt 7200 ]; then
        log "Meta file is ${META_AGE}s old (>2h), ignoring stale meta"
    else
        # 检查 meta 中的 session_id 是否匹配当前 session（如果有的话）
        META_SESSION=$(jq -r '.session_id // ""' "$META_FILE" 2>/dev/null || echo "")
        if [ -n "$META_SESSION" ] && [ "$META_SESSION" != "$SESSION_ID" ] && [ "$SESSION_ID" != "unknown" ]; then
            log "Meta session=$META_SESSION != current=$SESSION_ID, ignoring"
        else
            TASK_NAME=$(jq -r '.task_name // "unknown"' "$META_FILE" 2>/dev/null || echo "unknown")
            TELEGRAM_GROUP=$(jq -r '.telegram_group // ""' "$META_FILE" 2>/dev/null || echo "")
            CALLBACK_GROUP=$(jq -r '.callback_group // ""' "$META_FILE" 2>/dev/null || echo "")
            CALLBACK_DM=$(jq -r '.callback_dm // ""' "$META_FILE" 2>/dev/null || echo "")
            CALLBACK_ACCOUNT=$(jq -r '.callback_account // ""' "$META_FILE" 2>/dev/null || echo "")
            log "Meta: task=$TASK_NAME group=$TELEGRAM_GROUP callback_group=$CALLBACK_GROUP callback_dm=$CALLBACK_DM callback_account=$CALLBACK_ACCOUNT age=${META_AGE}s"
        fi
    fi
fi

# ---- 如果没有有效的 telegram 目标，跳过通知 ----
if [ -z "$TELEGRAM_GROUP" ]; then
    log "No valid telegram_group, skipping notification (non-dispatch run)"
fi

# ---- 写入结果 JSON ----
jq -n \
    --arg sid "$SESSION_ID" \
    --arg ts "$(date -Iseconds)" \
    --arg cwd "$CWD" \
    --arg event "$EVENT" \
    --arg output "$OUTPUT" \
    --arg task "$TASK_NAME" \
    --arg group "$TELEGRAM_GROUP" \
    '{session_id: $sid, timestamp: $ts, cwd: $cwd, event: $event, output: $output, task_name: $task, telegram_group: $group, status: "done"}' \
    > "${RESULT_DIR}/latest.json" 2>/dev/null

log "Wrote latest.json"

# ---- 方式1: 直接发 Telegram 消息（如果有目标群组）----
if [ -n "$TELEGRAM_GROUP" ] && [ -x "$OPENCLAW_BIN" ]; then

    # ---- 提取丰富信息 ----
    PROJECT_DIR=""
    DURATION=""
    AGENT_TEAMS_ENABLED="false"
    AGENTS_INFO=""
    TEST_SUMMARY=""
    FEATURES_DONE=""
    EXIT_CODE_VAL="0"

    # 从 task-meta.json 提取
    if [ -f "$META_FILE" ]; then
        PROJECT_DIR=$(jq -r '.workdir // ""' "$META_FILE" 2>/dev/null || echo "")
        AGENT_TEAMS_ENABLED=$(jq -r '.agent_teams // false' "$META_FILE" 2>/dev/null || echo "false")
        EXIT_CODE_VAL=$(jq -r '.exit_code // 0' "$META_FILE" 2>/dev/null || echo "0")

        # 计算耗时
        STARTED=$(jq -r '.started_at // ""' "$META_FILE" 2>/dev/null || echo "")
        COMPLETED=$(jq -r '.completed_at // ""' "$META_FILE" 2>/dev/null || echo "")
        if [ -n "$STARTED" ] && [ -n "$COMPLETED" ]; then
            START_TS=$(date -d "$STARTED" +%s 2>/dev/null || echo 0)
            END_TS=$(date -d "$COMPLETED" +%s 2>/dev/null || echo 0)
            if [ "$START_TS" -gt 0 ] && [ "$END_TS" -gt 0 ]; then
                ELAPSED=$(( END_TS - START_TS ))
                MINS=$(( ELAPSED / 60 ))
                SECS=$(( ELAPSED % 60 ))
                DURATION="${MINS}m${SECS}s"
            fi
        fi
    fi

    # 从 task-output.txt 提取结构化信息
    if [ -f "$TASK_OUTPUT" ] && [ -s "$TASK_OUTPUT" ]; then
        # 提取 Agent 信息（查找包含 agent 的表格行或列表）
        AGENTS_INFO=$(grep -iE '(agent|developer|testing).*\|.*✅' "$TASK_OUTPUT" 2>/dev/null | head -6 || true)
        # 提取测试结果
        TEST_SUMMARY=$(grep -iE '(tests? (passed|failed)|test_|pytest|✅.*test|tests passing)' "$TASK_OUTPUT" 2>/dev/null | tail -5 || true)
        # 提取 Feature/功能状态
        FEATURES_DONE=$(grep -E '✅' "$TASK_OUTPUT" 2>/dev/null | grep -ivE 'agent|developer' | head -10 || true)
    fi

    # ---- 构建丰富的消息 ----
    STATUS_EMOJI="✅"
    [ "$EXIT_CODE_VAL" != "0" ] && STATUS_EMOJI="❌"

    MSG="${STATUS_EMOJI} *Claude Code 任务完成*

📋 *任务:* \`${TASK_NAME}\`"

    # 项目路径
    [ -n "$PROJECT_DIR" ] && MSG="${MSG}
📂 *路径:* \`${PROJECT_DIR}\`"

    # 耗时
    [ -n "$DURATION" ] && MSG="${MSG}
⏱ *耗时:* ${DURATION}"

    # Exit code (只在失败时显示)
    [ "$EXIT_CODE_VAL" != "0" ] && MSG="${MSG}
⚠️ *Exit Code:* ${EXIT_CODE_VAL}"

    # Agent Teams 信息
    if [ "$AGENT_TEAMS_ENABLED" = "true" ]; then
        MSG="${MSG}

👥 *Agent Teams:* 已启用"
        if [ -n "$AGENTS_INFO" ]; then
            # 清理表格格式，转为列表
            AGENTS_LIST=$(echo "$AGENTS_INFO" | sed 's/|//g; s/  */ /g; s/^ //; s/ $//' | while IFS= read -r line; do echo "  • $line"; done)
            MSG="${MSG}
${AGENTS_LIST}"
        fi
    fi

    # 测试结果
    if [ -n "$TEST_SUMMARY" ]; then
        # 提取关键测试行
        TESTS_CLEAN=$(echo "$TEST_SUMMARY" | head -4 | sed 's/^[[:space:]]*//' | tr '\n' '; ' | sed 's/; $//')
        MSG="${MSG}

🧪 *测试:* ${TESTS_CLEAN}"
    fi

    # 功能列表
    if [ -n "$FEATURES_DONE" ]; then
        FEAT_COUNT=$(echo "$FEATURES_DONE" | wc -l)
        MSG="${MSG}

📦 *完成功能:* ${FEAT_COUNT} 项"
        FEAT_LIST=$(echo "$FEATURES_DONE" | head -8 | sed 's/|//g; s/  */ /g; s/^ //; s/ $//' | while IFS= read -r line; do echo "  $line"; done)
        MSG="${MSG}
${FEAT_LIST}"
    fi

    # 生成的文件列表
    if [ -n "$PROJECT_DIR" ] && [ -d "$PROJECT_DIR" ]; then
        FILE_TREE=$(find "$PROJECT_DIR" -maxdepth 3 -type f \
            ! -path '*/venv/*' ! -path '*/__pycache__/*' ! -path '*/.git/*' ! -path '*.pyc' \
            2>/dev/null | sort | sed "s|${PROJECT_DIR}/||" | head -20 | while IFS= read -r f; do echo "  📄 $f"; done)
        if [ -n "$FILE_TREE" ]; then
            MSG="${MSG}

📁 *项目文件:*
${FILE_TREE}"
        fi
    fi

    "$OPENCLAW_BIN" message send \
        --channel telegram \
        --target "$TELEGRAM_GROUP" \
        --message "$MSG" 2>/dev/null && log "Sent rich Telegram message to $TELEGRAM_GROUP" || log "Telegram send failed"

    # ---- 回调通知: 发到调用者 agent 的群（如果不同于通知群）----
    if [ -n "$CALLBACK_GROUP" ] && [ "$CALLBACK_GROUP" != "$TELEGRAM_GROUP" ]; then
        CALLBACK_MSG="🔔 *Claude Code 任务完成回调*

📋 *任务:* \`${TASK_NAME}\`
📊 *状态:* ${STATUS_EMOJI} 完成"
        [ -n "$DURATION" ] && CALLBACK_MSG="${CALLBACK_MSG}
⏱ *耗时:* ${DURATION}"

        # 摘要 output（限500字符）
        SUMMARY=$(echo "$OUTPUT" | head -c 500 | tr '\n' ' ')
        [ -n "$SUMMARY" ] && CALLBACK_MSG="${CALLBACK_MSG}

📝 *摘要:* ${SUMMARY}"

        "$OPENCLAW_BIN" message send \
            --channel telegram \
            --target "$CALLBACK_GROUP" \
            --message "$CALLBACK_MSG" 2>/dev/null && log "Sent callback to agent group $CALLBACK_GROUP" || log "Callback to $CALLBACK_GROUP failed"
    fi

    # ---- DM 回调: 通过指定 bot account 发 DM 给调用者 ----
    if [ -n "$CALLBACK_DM" ]; then
        CALLBACK_MSG="🔔 *Claude Code 任务完成*

📋 *任务:* \`${TASK_NAME}\`
📊 *状态:* ${STATUS_EMOJI} 完成"
        [ -n "$DURATION" ] && CALLBACK_MSG="${CALLBACK_MSG}
⏱ *耗时:* ${DURATION}"

        SUMMARY=$(echo "$OUTPUT" | head -c 500 | tr '\n' ' ')
        [ -n "$SUMMARY" ] && CALLBACK_MSG="${CALLBACK_MSG}

📝 *摘要:* ${SUMMARY}"

        DM_CMD=("$OPENCLAW_BIN" message send --channel telegram --target "$CALLBACK_DM" --message "$CALLBACK_MSG")
        [ -n "$CALLBACK_ACCOUNT" ] && DM_CMD+=(--account "$CALLBACK_ACCOUNT")

        "${DM_CMD[@]}" 2>/dev/null && log "Sent DM callback to $CALLBACK_DM (account=${CALLBACK_ACCOUNT:-default})" || log "DM callback to $CALLBACK_DM failed"
    fi
fi

# ---- 方式2: 唤醒 AGI 主会话 ----
# 写入 wake 标记文件，AGI 在下次 heartbeat 时读取
WAKE_FILE="${RESULT_DIR}/pending-wake.json"
jq -n \
    --arg task "$TASK_NAME" \
    --arg group "$TELEGRAM_GROUP" \
    --arg ts "$(date -Iseconds)" \
    --arg summary "$(echo "$OUTPUT" | head -c 500 | tr '\n' ' ')" \
    '{task_name: $task, telegram_group: $group, timestamp: $ts, summary: $summary, processed: false}' \
    > "$WAKE_FILE" 2>/dev/null

log "Wrote pending-wake.json"

# ---- 方式3: 唤醒 AGI 主会话（通过 /hooks/wake REST API）----
# 旧方案 `openclaw agent --session-id` 有两个 bug:
#   1) session UUID 在 /new 或 /reset 后会变，解析不可靠
#   2) openclaw agent 命令本身会挂起/超时
# 新方案: POST /hooks/wake — 注入系统事件到主会话，可靠且无阻塞

GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
HOOK_TOKEN=""

# 从 config 文件读取 webhook token
OPENCLAW_CONFIG="/home/ubuntu/.openclaw/openclaw.json"
if [ -f "$OPENCLAW_CONFIG" ]; then
    HOOK_TOKEN=$(jq -r '.hooks.token // ""' "$OPENCLAW_CONFIG" 2>/dev/null || echo "")
fi

WAKE_TEXT="[CLAUDE_CODE_DONE] task=${TASK_NAME} status=done group=${TELEGRAM_GROUP:-none} ts=$(date -Iseconds)"

if [ -n "$HOOK_TOKEN" ]; then
    (
      HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
          "http://localhost:${GATEWAY_PORT}/hooks/wake" \
          -H "Content-Type: application/json" \
          -H "Authorization: Bearer ${HOOK_TOKEN}" \
          -d "{\"text\":\"${WAKE_TEXT}\",\"mode\":\"now\"}" 2>/dev/null)

      if [ "$HTTP_CODE" = "200" ]; then
          log "Wake event sent via /hooks/wake (HTTP $HTTP_CODE)"
      else
          log "Wake failed (HTTP $HTTP_CODE), trying DM fallback"
          # Fallback: 直接发 Telegram DM 给 Master
          CALLBACK_DM=""
          if [ -f "$META_FILE" ]; then
              CALLBACK_DM=$(jq -r '.callback_dm // ""' "$META_FILE" 2>/dev/null || echo "")
          fi
          DM_TARGET="${CALLBACK_DM:-8009709280}"
          timeout 10 "$OPENCLAW_BIN" message send \
              --channel telegram \
              --target "$DM_TARGET" \
              --message "🔔 $WAKE_TEXT" </dev/null >>"$LOG" 2>&1 && \
              log "Sent DM fallback to $DM_TARGET" || \
              log "DM fallback also failed"
      fi
    ) &
    log "Dispatching async wake notification via /hooks/wake"
else
    log "No hook token found, skipping wake notification"
fi

log "=== Hook completed ==="
exit 0
