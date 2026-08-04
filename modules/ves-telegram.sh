#!/usr/bin/env bash
# ves-telegram.sh -- optional Telegram job-completion notifications.
# Opt-in only via CONVERT_TELEGRAM_BOT_TOKEN/CONVERT_TELEGRAM_CHAT_ID env
# vars, silently disabled otherwise. Pure move from the former monolithic
# script -- no logic changes.

# Best-effort Telegram job-completion notification. No-op unless both
# TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID are set (see the env-var comment at
# their declaration). Fire-and-forget in the background with a short
# timeout -- a slow or unreachable Telegram API must never block or fail
# the actual encode job, same "auxiliary operation degrades silently"
# principle as every other non-essential path in this script. Uses
# --data-urlencode (not string-concatenated into the URL) so a title
# containing spaces/parens/unicode can't produce a malformed request.
notify_telegram() {
  [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  local text="[${TELEGRAM_HOST_TAG:-$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)}] $1"
  (
    timeout 10 curl -s -m 8 \
      --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=${text}" \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      >/dev/null 2>&1 || true
  ) &
  disown 2>/dev/null || true
}
