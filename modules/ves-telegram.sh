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
  # v6.0.8 (2026-09-14 peer review finding #4): this function was the
  # system's ONLY human-facing channel with zero delivery confirmation or
  # audit trail anywhere -- if credentials ever went stale or the API was
  # unreachable, every notification fleet-wide would vanish silently
  # forever with no trace it was even attempted. A local per-host log line
  # (HTTP status code from curl, not the message body) doesn't change the
  # fire-and-forget/never-block contract at all -- still backgrounded,
  # still `|| true`, still silent to the CALLER -- it just leaves something
  # for a human/agent to check when messages stop arriving. Path is a bare
  # /tmp default (not $SHARED) since this module is shared by the main
  # pipeline too and runs on arbitrary hosts, not just the D-val coordinator.
  local _tglog="${TELEGRAM_SEND_LOG:-/tmp/ves-telegram-send.log}"
  (
    _code="$(timeout 10 curl -s -m 8 -o /dev/null -w '%{http_code}' \
      --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=${text}" \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      2>/dev/null)"
    printf '%s http=%s\n' "$(date -u +%FT%TZ)" "${_code:-curl_failed}" >> "$_tglog" 2>/dev/null || true
  ) &
  disown 2>/dev/null || true
}
