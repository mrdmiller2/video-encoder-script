# Windows/PowerShell port of orchestration/regional-survey/scripts/ves-dval-claim-lib.sh
# (bash, v6.0.2P). The D-val survey's shot-claim leases + search-worker admission
# registry + the node search/encode mutex, spoken directly to redis-ves on the
# coordinator (RANDYJ 10.10.10.100:6380) as RESP arrays over a raw TCP socket --
# NO redis-cli dependency on the worker, matching the bash lib's `/dev/tcp`
# approach.
#
# WHY this exists: the existing PS search port (VesPerShotQp.psm1) uses SMB
# lock-dir claims, so a PS worker cannot share the redis shot-lease namespace
# with the Linux fleet (two workers could grab the same shot), cannot register
# for admission/sizing, and cannot honor `dval:encnode:<host>` (the v6.0.2M
# search-XOR-encode-per-node mutex). This module closes that -- it is the exact
# bash contract, function for function.
#
# Deliberate Windows deviations (not oversights):
#  * bash opens a fresh `/dev/tcp` fd per call and never pipelines; this port
#    does the same with a fresh [System.Net.Sockets.TcpClient] per call. One
#    command, one reply, close. Simple + matches the bash failure surface.
#  * bash's `_ves_redis` returns rc 3 on any connect/write/read/-ERR failure and
#    every caller treats rc 3 as "WAIT / do not proceed unmanaged". This port
#    throws on those; the public functions catch and return the same
#    WAIT/STOP/`$false` fail-safe values. A redis outage must never let a worker
#    run unmanaged or double-claim.
#  * bash cannot parse a multi-bulk (`*N`) reply and every command it issues
#    avoids one (SET/GET/DEL/EXPIRE/PING/EVAL-returning-scalar). Same here --
#    Invoke-VesRedis returns the raw header line for `*N` and no function relies
#    on it. Coordinator-side multi-bulk work (target-set, --scan cleanup) stays
#    in redis-cli in dval_research.sh / dval_claim_reaper.sh, never here.
#  * timeout/no-op-on-failure discipline borrowed from VesTelegram.psm1;
#    stale-age + swallow-all-errors from VesSharedMutex.psm1.

# (no Set-StrictMode -- matches the rest of windows/modules/; the RESP parser
#  and fail-safe paths are written to tolerate $null / missing env vars.)

# --- config (env-var overridable, same names + defaults as the bash lib) ----
function Get-VesDvalCoord      { if ($env:VES_CLAIM_COORD)       { $env:VES_CLAIM_COORD }       else { '10.10.10.100' } }
function Get-VesDvalPort       { if ($env:VES_CLAIM_REDIS_PORT)  { [int]$env:VES_CLAIM_REDIS_PORT } else { 6380 } }
function Get-VesDvalClaimTtl   { if ($env:VES_CLAIM_TTL)         { [int]$env:VES_CLAIM_TTL }     else { 2700 } }   # shot-lease EX
function Get-VesDvalWregTtl    { if ($env:DVAL_WREG_TTL)         { [int]$env:DVAL_WREG_TTL }     else { 240 } }    # registration liveness window
function Get-VesDvalWregExpire { if ($env:DVAL_WREG_EXPIRE)      { [int]$env:DVAL_WREG_EXPIRE }  else { 3600 } }   # whole wreg-hash EXPIRE
function Get-VesDvalEncnodeTtl { if ($env:DVAL_ENCNODE_TTL)      { [int]$env:DVAL_ENCNODE_TTL }  else { 900 } }    # node-mutex EX

# canonical host key: dval_research.sh forwards DVAL_WREG_HOST (the fleet name,
# e.g. PRINCE) -- workers MUST use it, not COMPUTERNAME (which may be lowercased
# / FQDN'd), or the admission count never matches the coordinator's target.
function Get-VesDvalHost  { if ($env:DVAL_WREG_HOST) { $env:DVAL_WREG_HOST } else { $env:COMPUTERNAME } }
function Get-VesDvalOwner { "{0}:{1}" -f (Get-VesDvalHost), $PID }

# ---------------------------------------------------------------------------
# Invoke-VesRedis -- one RESP command, one reply. Throws on any failure
# (connect / write / read timeout / -ERR reply); callers translate that to the
# fail-safe value. Mirrors _ves_redis (ves-dval-claim-lib.sh:19-36).
#   +OK        -> 'OK'            :N            -> 'N'
#   $-1 (nil)  -> ''             $N\r\n<data>   -> '<data>'
#   -ERR ...   -> throw           *N (mbulk)    -> raw header line (unused)
# ---------------------------------------------------------------------------
function Invoke-VesRedis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromRemainingArguments)]
        [string[]]$CmdArgs,
        [int]$ConnectTimeoutMs = 2000,
        [int]$IoTimeoutMs      = 5000
    )
    $client = $null
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        # bounded connect -- this is also the _dval_reach() 2s pre-check, folded in
        $connect = $client.ConnectAsync((Get-VesDvalCoord), (Get-VesDvalPort))
        if (-not $connect.Wait($ConnectTimeoutMs) -or -not $client.Connected) {
            throw "redis connect timeout"
        }
        $client.ReceiveTimeout = $IoTimeoutMs
        $client.SendTimeout    = $IoTimeoutMs
        $stream = $client.GetStream()

        # --- request: RESP array of bulk strings, byte-length prefixed --------
        $enc = [System.Text.Encoding]::UTF8
        $sb  = [System.Text.StringBuilder]::new()
        [void]$sb.Append('*').Append($CmdArgs.Count).Append("`r`n")
        foreach ($a in $CmdArgs) {
            $blen = $enc.GetByteCount($a)
            [void]$sb.Append('$').Append($blen).Append("`r`n").Append($a).Append("`r`n")
        }
        $req = $enc.GetBytes($sb.ToString())
        $stream.Write($req, 0, $req.Length)
        $stream.Flush()

        # --- reply: read line-oriented, exactly like the bash `read -r` loop --
        $reader = [System.IO.StreamReader]::new($stream, $enc, $false, 1024, $true)
        $line = $reader.ReadLine()
        if ([string]::IsNullOrEmpty($line)) { throw "redis: empty reply" }
        switch ($line.Substring(0, 1)) {
            '+' { return $line.Substring(1) }
            ':' { return $line.Substring(1) }
            '$' {
                if ($line -eq '$-1') { return '' }
                $data = $reader.ReadLine()
                return [string]$data
            }
            '-' { throw "redis error: $line" }
            default { return $line }   # '*N' multi-bulk header (unused) or bare
        }
    }
    finally {
        if ($client) { try { $client.Close() } catch { } }
    }
}

# quick reachability check (bash _dval_reach). true = redis answered a PING.
function Test-VesDvalReach {
    try { return ((Invoke-VesRedis 'PING') -eq 'PONG') } catch { return $false }
}
function Test-VesDvalRedisUp { Test-VesDvalReach }

# ===========================================================================
# shot-claim leases  (bash: dval_claim / dval_release / dval_heartbeat)
# key: dval:<slug>:<idx>  value: <owner>  EX VES_CLAIM_TTL
# ===========================================================================

# Enter-VesDvalClaim <slug> <idx> [owner] -> 'OK' | 'TAKEN' | 'WAIT'
# (SET dval:<slug>:<idx> <owner> EX 2700 NX). WAIT = redis unreachable/error;
# caller pauses + retries, never treats it as "TAKEN".
function Enter-VesDvalClaim {
    param(
        [Parameter(Mandatory)][string]$Slug,
        [Parameter(Mandatory)][string]$Index,
        [string]$Owner = (Get-VesDvalOwner)
    )
    try {
        $r = Invoke-VesRedis 'SET' "dval:${Slug}:${Index}" $Owner 'EX' ([string](Get-VesDvalClaimTtl)) 'NX'
        if ($r -eq 'OK') { return 'OK' }
        return 'TAKEN'   # nil reply => key already held
    } catch {
        return 'WAIT'
    }
}

# Exit-VesDvalClaim -- owner-checked DEL (leave a peer-retaken lease alone).
function Exit-VesDvalClaim {
    param(
        [Parameter(Mandatory)][string]$Slug,
        [Parameter(Mandatory)][string]$Index,
        [string]$Owner = (Get-VesDvalOwner)
    )
    try {
        Invoke-VesRedis 'EVAL' `
            "if redis.call('GET',KEYS[1])==ARGV[1] then return redis.call('DEL',KEYS[1]) else return 0 end" `
            '1' "dval:${Slug}:${Index}" $Owner | Out-Null
    } catch { }
}

# Update-VesDvalLease -- owner-checked EXPIRE refresh (per-held-shot heartbeat).
function Update-VesDvalLease {
    param(
        [Parameter(Mandatory)][string]$Slug,
        [Parameter(Mandatory)][string]$Index,
        [string]$Owner = (Get-VesDvalOwner)
    )
    try {
        Invoke-VesRedis 'EVAL' `
            "if redis.call('GET',KEYS[1])==ARGV[1] then return redis.call('EXPIRE',KEYS[1],ARGV[2]) else return 0 end" `
            '1' "dval:${Slug}:${Index}" $Owner ([string](Get-VesDvalClaimTtl)) | Out-Null
    } catch { }
}

# ===========================================================================
# search-worker admission registry  (bash: dval_admit / dval_wreg_count)
# Lua strings ported BYTE-VERBATIM from ves-dval-claim-lib.sh:81-123 (incl. the
# leading newline) -- they run server-side; do not "tidy" them.
# ===========================================================================

$script:DvalAdmitLua = @'

local now=tonumber(ARGV[2]); local ttl=tonumber(ARGV[3])
local fb=tonumber(ARGV[4]); if not fb then fb=1 end
local member=ARGV[1]
-- v6.0.2M node mutex: this host is running a D-val ENCODE right now -> no
-- search worker may run on it (both are CPU-saturating). The search worker
-- bows out on its next beat; reconcile_host will not relaunch while the key
-- lives. Encode worker sets/renews dval:encnode:<host>, clears it on exit.
if redis.call("GET",KEYS[3]) then redis.call("HDEL",KEYS[1],member); return "STOP" end
local target=tonumber(redis.call("GET",KEYS[2])); if not target then target=fb end
if target<0 then target=0 end
local raw=redis.call("HGETALL",KEYS[1])
local live={}
for i=1,#raw,2 do
  local reg,hb=string.match(raw[i+1],"^(%d+),(%d+)$")
  reg=tonumber(reg); hb=tonumber(hb)
  if reg and hb and hb>=now-ttl then live[#live+1]={reg=reg,f=raw[i]}
  else redis.call("HDEL",KEYS[1],raw[i]) end
end
table.sort(live,function(a,b) if a.reg~=b.reg then return a.reg<b.reg end return a.f<b.f end)
local mypos=nil
for idx,e in ipairs(live) do if e.f==member then mypos=idx end end
if mypos then
  if mypos<=target then
    redis.call("HSET",KEYS[1],member,live[mypos].reg..","..now)
    redis.call("EXPIRE",KEYS[1],tonumber(ARGV[5])); return "GO"
  else
    redis.call("HDEL",KEYS[1],member); return "STOP"
  end
else
  if #live>=target then return "STOP" end
  redis.call("HSET",KEYS[1],member,now..","..now)
  redis.call("EXPIRE",KEYS[1],tonumber(ARGV[5])); return "GO"
end
'@

$script:DvalWregCountLua = @'

local now=tonumber(ARGV[1]); local ttl=tonumber(ARGV[2])
local raw=redis.call("HGETALL",KEYS[1]); local n=0
for i=1,#raw,2 do
  local reg,hb=string.match(raw[i+1],"^(%d+),(%d+)$")
  if hb and tonumber(hb)>=now-ttl then n=n+1 else redis.call("HDEL",KEYS[1],raw[i]) end
end
return n
'@

# Test-VesDvalAdmit <slug> <host> <pid> [fallbackTarget] -> 'GO' | 'STOP' | 'WAIT'
# GO   = registered (hb_epoch written -- this IS the wreg heartbeat) and within
#        seniority rank <= target: proceed.
# STOP = dval:encnode:<host> held (encode mutex), OR ranked beyond target
#        (seniority scale-down drops the youngest): bow out cleanly.
# WAIT = redis unreachable / error: do NOT proceed unmanaged (caller exits at
#        startup; mid-loop caller keeps its claimed work and retries).
function Test-VesDvalAdmit {
    param(
        [Parameter(Mandatory)][string]$Slug,
        [Parameter(Mandatory)][string]$DvalHost,
        [Parameter(Mandatory)][int]$WorkerPid,
        [int]$FallbackTarget = 1
    )
    try {
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $r = Invoke-VesRedis 'EVAL' $script:DvalAdmitLua '3' `
                "dval:wreg:${Slug}:${DvalHost}" "dval:target:${Slug}:${DvalHost}" "dval:encnode:${DvalHost}" `
                "${DvalHost}:${WorkerPid}" ([string]$now) ([string](Get-VesDvalWregTtl)) `
                ([string]$FallbackTarget) ([string](Get-VesDvalWregExpire))
        if ($r -eq 'GO') { return 'GO' }
        if ([string]::IsNullOrEmpty($r)) { return 'WAIT' }
        return 'STOP'
    } catch {
        return 'WAIT'
    }
}

# Get-VesDvalWregCount <slug> <host> -> live registration count, or -1 on failure.
function Get-VesDvalWregCount {
    param(
        [Parameter(Mandatory)][string]$Slug,
        [Parameter(Mandatory)][string]$DvalHost
    )
    try {
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $r = Invoke-VesRedis 'EVAL' $script:DvalWregCountLua '1' `
                "dval:wreg:${Slug}:${DvalHost}" ([string]$now) ([string](Get-VesDvalWregTtl))
        if ($r -match '^\d+$') { return [int]$r }
        return -1
    } catch {
        return -1
    }
}

# ===========================================================================
# node search/encode mutex  (bash: dval_encnode_claim / _renew / _clear)
# key: dval:encnode:<host>  value: "<CAT>|<slug>"  EX DVAL_ENCNODE_TTL (900),
# renewed ~every 60s by the encode heartbeat, cleared on exit.
# ===========================================================================

# Enter-VesDvalEncnodeClaim <host> <tag> -> $true if we now hold it (new, or it
# was already ours), $false if held by another encode / redis down.
function Enter-VesDvalEncnodeClaim {
    param(
        [Parameter(Mandatory)][string]$DvalHost,
        [Parameter(Mandatory)][string]$Tag   # "<CAT>|<slug>"
    )
    try {
        $r = Invoke-VesRedis 'SET' "dval:encnode:${DvalHost}" $Tag 'NX' 'EX' ([string](Get-VesDvalEncnodeTtl))
        if ($r -eq 'OK') { return $true }
        # already set -- ours (same tag) is fine, someone else's is not
        $cur = Invoke-VesRedis 'GET' "dval:encnode:${DvalHost}"
        if ($cur -eq $Tag) { Update-VesDvalEncnodeClaim -DvalHost $DvalHost -Tag $Tag; return $true }
        return $false
    } catch {
        return $false
    }
}

function Update-VesDvalEncnodeClaim {
    param(
        [Parameter(Mandatory)][string]$DvalHost,
        [Parameter(Mandatory)][string]$Tag
    )
    try {
        Invoke-VesRedis 'SET' "dval:encnode:${DvalHost}" $Tag 'EX' ([string](Get-VesDvalEncnodeTtl)) | Out-Null
    } catch { }
}

function Exit-VesDvalEncnodeClaim {
    param([Parameter(Mandatory)][string]$DvalHost)
    try { Invoke-VesRedis 'DEL' "dval:encnode:${DvalHost}" | Out-Null } catch { }
}

Export-ModuleMember -Function `
    Invoke-VesRedis, Test-VesDvalReach, Test-VesDvalRedisUp, `
    Enter-VesDvalClaim, Exit-VesDvalClaim, Update-VesDvalLease, `
    Test-VesDvalAdmit, Get-VesDvalWregCount, `
    Enter-VesDvalEncnodeClaim, Update-VesDvalEncnodeClaim, Exit-VesDvalEncnodeClaim, `
    Get-VesDvalHost, Get-VesDvalOwner
