# Windows port of convert-v5.0.33S.sh's Telegram notifications
# (notify_telegram(), line ~1024; call sites in end_convert_job(),
# lines ~3085-3118).
#
# Config is env-var-only, deliberately, matching bash's own stated
# reasoning (verbatim from its --help text): a CLI flag value is
# visible to any local user via `ps aux`/Get-Process's CommandLine; an
# env var isn't. Never add a -BotToken/-ChatId parameter to any public
# function here.
#
# Windows deviation, deliberate (per team design review 2026-08-03):
# bash backgrounds the curl call in a subshell + `disown` specifically
# because bash has no other lightweight "fire and forget with a
# timeout" primitive, and Start-Job is documented elsewhere in this
# port (VesSharedMutex.psm1) as hitting a persistent Access-Denied
# writing to the real NAS from a child process. This call never touches
# the NAS at all (a single small HTTPS POST), so a synchronous call
# with a hard timeout gives the same "never blocks the caller for more
# than a few seconds" guarantee without that risk. Accepted tradeoff:
# unlike bash's disowned call, a slow/unreachable Telegram API adds a
# few seconds of delay per notification rather than zero -- judged
# acceptable for a low-stakes fire-and-forget notification, not worth
# reintroducing Start-Job risk to avoid.

function Send-VesTelegramNotification {
    <#
    .SYNOPSIS
    Port of notify_telegram(). Silent no-op if either env var is unset
    or the call fails for any reason -- a notification failure must
    never break the caller's actual work.
    #>
    param(
        [Parameter(Mandatory)][string]$Message,
        [int]$TimeoutSeconds = 10
    )
    $token = $env:VES_TELEGRAM_BOT_TOKEN
    $chatId = $env:VES_TELEGRAM_CHAT_ID
    if (-not $token -or -not $chatId) { return }

    $text = "[$env:COMPUTERNAME] $Message"
    $uri = "https://api.telegram.org/bot$token/sendMessage"
    $body = @{ chat_id = $chatId; text = $text }

    try {
        $params = @{
            Uri         = $uri
            Method      = 'Post'
            Body        = $body
            TimeoutSec  = $TimeoutSeconds
            ErrorAction = 'Stop'
        }
        # -OperationTimeoutSeconds (PS7.4+) bounds a connected-but-stalled
        # response body -- -TimeoutSec alone only bounds connect+headers
        # on 7.4+ (ConnectionTimeoutSeconds), found during team review.
        # Parameter-checked since it doesn't exist on earlier PS7
        # releases this port might still run under.
        if ((Get-Command Invoke-RestMethod).Parameters.ContainsKey('OperationTimeoutSeconds')) {
            $params['OperationTimeoutSeconds'] = $TimeoutSeconds
        }
        Invoke-RestMethod @params | Out-Null
    } catch {
        # Deliberately swallowed -- matches bash's `|| true` on the curl
        # call. A dead Telegram bot/chat must never fail a real encode job.
    }
}

Export-ModuleMember -Function Send-VesTelegramNotification
