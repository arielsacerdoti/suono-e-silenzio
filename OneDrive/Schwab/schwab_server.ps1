# AlphaPicks Schwab Server
# Serves: /proxy (Yahoo CORS), /auth, /callback, /schwab/status, /schwab/api, /dashboard, /mobile, /store, /auto-log
# Run via "! Open AlphaPicks Portfolio.bat" (as Admin for all-interface binding)

$port       = 7843
$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$configFile = Join-Path $scriptDir 'schwab_config.json'
$tokenFile  = Join-Path $scriptDir 'schwab_tokens.json'
$dashFile   = Join-Path $scriptDir 'AlphaPicks Portfolio.html'
# Points OUTSIDE this folder, at the actual GitHub Pages deploy source
# (github.com/arielsacerdoti/alphapicks-mobile, cloned locally to
# OneDrive\alphapicks-mobile) -- deliberately not a second local copy. A
# duplicate "AlphaPicks Mobile.html" living here, edited here, and pushed to a
# DIFFERENT repo than the one Pages actually serves is exactly what let a
# week of real mobile fixes silently never reach the phone (confirmed
# 2026-08-10: the deployed repo was still on an 2026-08-03 commit). One file,
# edited in place, is what makes that class of bug structurally impossible
# instead of just less likely.
$mobileFile = 'C:\Users\sacer\OneDrive\alphapicks-mobile\index.html'

# store.json lives OUTSIDE the OneDrive-synced folder on purpose: this file has exactly one
# legitimate writer (this server process). Keeping it in the synced folder let a second
# schwab_server.ps1 instance running on another device (e.g. via the launcher .bat run by
# mistake on a client machine) silently clobber this server's copy via OneDrive sync/conflict
# resolution, wiping keys like alphapicks_tagged without any error.
$storeFile = Join-Path $scriptDir 'store.json' # fallback if the ProgramData relocation below fails
try {
    $storeDir = Join-Path $env:ProgramData 'AlphaPicksServer'
    if (-not (Test-Path $storeDir)) { New-Item -ItemType Directory -Path $storeDir -Force | Out-Null }
    $newStoreFile = Join-Path $storeDir 'store.json'
    if (-not (Test-Path $newStoreFile) -and (Test-Path $storeFile)) {
        Copy-Item $storeFile $newStoreFile
    }
    $storeFile = $newStoreFile
} catch {
    Write-Host "[Server] WARNING: couldn't relocate store.json to ProgramData, using OneDrive folder: $_" -ForegroundColor Yellow
}

# --- Schwab OAuth config -------------------------------------------------------
$cfg          = Get-Content $configFile -Raw | ConvertFrom-Json
$CLIENT_ID    = $cfg.client_id
$CLIENT_SECRET= $cfg.client_secret
$REDIRECT_URI = 'https://127.0.0.1:7843/callback'
$AUTH_URL     = 'https://api.schwabapi.com/v1/oauth/authorize'
$TOKEN_URL    = 'https://api.schwabapi.com/v1/oauth/token'
$API_BASE     = 'https://api.schwabapi.com'

# --- Auto-log constants -------------------------------------------------------
$FMP_KEY_SERVER   = 'RifQbMNRIh92cgRC44u30scmkMK0l0gK'
# There is no live sync from the browser's `alphapicks_tagged` (localStorage) to this server --
# it has no access to that. This list is a hand-maintained snapshot and WILL go stale again the
# next time a ticker is added via the Buy flow. Missed CNC (bought 2026-08-03) for several days --
# the unattended /auto-log fallback would have undercounted Alpha Picks by ~$10k on any day it
# ran for real in that window. When adding a new Alpha Pick, add it here too.
$ALPHA_PICKS_SYMS = @('TTMI','MU','INCY','PARR','W','TIGO','B','NEM','DY','GM','FN','LITE','CSTM','NEXA','MXL','SNDK','SNEX','ICHR','BTSG','CRDO','CNC')
# Mirror of INITIAL_TAGGED_QGI in AlphaPicks Portfolio.html. Needed so the unattended raw
# fallback path (below) excludes QG&I's own holdings from the Brokerage bucket the same way it
# already excludes Alpha Picks' -- without this, QG&I's real positions (same physical brokerage
# account, no separate account number to key off) got silently counted as Brokerage instead.
$QGI_SYMS = @('KIM','COP','MPC','VLO','CVX','B','RTX','PSX','ADC','FRT','CTRE','XHR','RY','THG',
              'AEP','EWBC','AGM','THFF','GRC','FAF','DRH','R','MDLZ','RBCAA','EPR','RLJ','XOM','JBSS','PNC','SRCE')
$MARKET_HOLIDAYS  = @(
    '2026-01-01','2026-01-19','2026-02-16','2026-04-03',
    '2026-05-25','2026-07-03','2026-09-07','2026-11-26','2026-12-25',
    '2027-01-01','2027-01-18','2027-02-15','2027-04-02',
    '2027-05-31','2027-07-05','2027-09-06','2027-11-25','2027-12-24'
)
$LOG_XLSX_PATH = Join-Path $scriptDir '!Alpha Picks Portfolio Log.xlsx'
$PRICE_ALERT_LOG = Join-Path $scriptDir 'price_alerts.log'

# Persistent record of a degraded/skipped auto-log price fetch (e.g. FMP quota exhausted with
# Yahoo also failing) -- appends to a small durable log file and also stashes the same info in
# the store so the dashboard can show a banner about it next time it's opened, since this path
# only ever runs unattended (no browser open to notice in real time otherwise).
function Write-PriceAlert($pricedCount, $totalCount, $store, $storeFile) {
    try {
        $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  Degraded auto-log: $pricedCount/$totalCount symbols priced -- entry skipped"
        Add-Content -Path $PRICE_ALERT_LOG -Value $line -Encoding UTF8
        if ((Get-Item $PRICE_ALERT_LOG -ErrorAction SilentlyContinue).Length -gt 64KB) {
            $lines = Get-Content $PRICE_ALERT_LOG
            $lines | Select-Object -Last 100 | Set-Content $PRICE_ALERT_LOG -Encoding UTF8
        }
    } catch {}
    try {
        $alert = @{ ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); pricedCount = $pricedCount; totalCount = $totalCount }
        if (-not ($store | Get-Member -Name price_source_alert -ErrorAction SilentlyContinue)) {
            $store | Add-Member -NotePropertyName price_source_alert -NotePropertyValue $alert -Force
        } else {
            $store.price_source_alert = $alert
        }
        $store | ConvertTo-Json -Depth 10 -Compress | Set-Content $storeFile -Encoding UTF8
    } catch {}
}

# Server-side mirror of getSessionFromClock() in both HTML files (ET clock, ignores API
# marketState -- see the comment on that JS function for why). Needed here now that FMP usage
# is restricted to REGULAR session only: 2:00-9:30am PRE, 9:30am-4:00pm REGULAR, 4:00-8:00pm
# POST, else/weekends CLOSED.
function Get-MarketSession {
    $etNow = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([datetime]::UtcNow, 'Eastern Standard Time')
    if ($etNow.DayOfWeek -eq 'Saturday' -or $etNow.DayOfWeek -eq 'Sunday') { return 'CLOSED' }
    $mins = $etNow.Hour * 60 + $etNow.Minute
    if ($mins -ge 120  -and $mins -lt 570)  { return 'PRE' }
    if ($mins -ge 570  -and $mins -lt 960)  { return 'REGULAR' }
    if ($mins -ge 960  -and $mins -lt 1200) { return 'POST' }
    return 'CLOSED'
}

$FMP_USAGE_LOG = Join-Path $scriptDir 'fmp_usage.log'

# Durable record of every time FMP actually gets used as a backup (client-reported via
# /fmp-usage-log, or server-side call sites below) -- lets us measure the REAL post-change call
# volume instead of just estimating it. One line per batch: timestamp, calling context, symbol
# count, and the symbols themselves.
function Write-FmpUsage($context, [string[]]$symbols) {
    if (-not $symbols -or $symbols.Count -eq 0) { return }
    try {
        $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  [$context] $($symbols.Count) symbols: $($symbols -join ',')"
        Add-Content -Path $FMP_USAGE_LOG -Value $line -Encoding UTF8
        if ((Get-Item $FMP_USAGE_LOG -ErrorAction SilentlyContinue).Length -gt 256KB) {
            $lines = Get-Content $FMP_USAGE_LOG
            $lines | Select-Object -Last 2000 | Set-Content $FMP_USAGE_LOG -Encoding UTF8
        }
    } catch {}
}

$YAHOO_FAILURE_LOG = Join-Path $scriptDir 'yahoo_failures.log'

# Durable record of every time Yahoo's v8 chart (client-reported via /yahoo-failure-log, through
# fetchTickerChart's own full fallback chain -- local proxy, direct, corsproxy.io, thingproxy,
# codetabs) came back with no usable price at all. Added 2026-08-01: discovered FMP can only
# serve ~5 of our ~60 real holdings on the current plan tier (402 for everything else), so Yahoo
# is the only real price source for most positions -- "positions not updating" is a Yahoo-
# reliability question, and there was no visibility into Yahoo failures at all before this.
function Write-YahooFailure($symbol) {
    if (-not $symbol) { return }
    try {
        $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $symbol"
        Add-Content -Path $YAHOO_FAILURE_LOG -Value $line -Encoding UTF8
        if ((Get-Item $YAHOO_FAILURE_LOG -ErrorAction SilentlyContinue).Length -gt 256KB) {
            $lines = Get-Content $YAHOO_FAILURE_LOG
            $lines | Select-Object -Last 2000 | Set-Content $YAHOO_FAILURE_LOG -Encoding UTF8
        }
    } catch {}
}

$AUTO_LOG_LOG = Join-Path $scriptDir 'autolog.log'

# Durable run history for /auto-log — added 2026-08-06 after a day (2026-08-05) where BOTH the
# browser's 4:05pm capture and this endpoint's own unattended fallback silently failed to produce
# a real entry, and there was nothing to diagnose it from except Write-Host output that only ever
# went to a console window nobody was watching. checkMissingLogEntry() quietly papered over the
# gap the next morning with a degraded Alpha-Picks-only backfillLogEntry() placeholder (no
# Brokerage/IRA/QG&I, no SPY/IRR) -- which is a fine safety net, but it means a real failure can
# go completely unnoticed unless someone happens to compare that day's entry shape by hand.
# One line per /auto-log call: who triggered it (the background timer vs. the browser's own
# capture), and how it ended (browser fast-path, computed + written, degraded/aborted, or errored).
# The background timer job also writes its own "decided to fire" line directly (see $autoLogJob
# below) -- so a fire with no matching endpoint line means the HTTP call itself never landed,
# and no fire line around 4:05pm ET on a trading day means the timer job itself was not alive.
function Write-AutoLogEvent($msg) {
    try {
        $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg"
        Add-Content -Path $AUTO_LOG_LOG -Value $line -Encoding UTF8
        if ((Get-Item $AUTO_LOG_LOG -ErrorAction SilentlyContinue).Length -gt 256KB) {
            $lines = Get-Content $AUTO_LOG_LOG
            $lines | Select-Object -Last 2000 | Set-Content $AUTO_LOG_LOG -Encoding UTF8
        }
    } catch {}
}

# --- ImportExcel check/install ------------------------------------------------
$script:hasImportExcel = $false
if (Get-Module -ListAvailable -Name ImportExcel -ErrorAction SilentlyContinue) {
    $script:hasImportExcel = $true
    Write-Host "[Server] ImportExcel available." -ForegroundColor Green
} else {
    Write-Host "[Server] ImportExcel not found — auto-log will save JSON only. Run: Install-Module ImportExcel -Scope CurrentUser" -ForegroundColor Yellow
}

# --- Token helpers ------------------------------------------------------------
function Load-Tokens {
    if (Test-Path $tokenFile) {
        try { return Get-Content $tokenFile -Raw | ConvertFrom-Json } catch {}
    }
    return $null
}

function Save-Tokens($tok) {
    $tok | ConvertTo-Json -Depth 5 | Set-Content $tokenFile -Encoding UTF8
}

function Refresh-Tokens($tok) {
    try {
        $body = "grant_type=refresh_token&refresh_token=$([Uri]::EscapeDataString($tok.refresh_token))"
        $creds = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${CLIENT_ID}:${CLIENT_SECRET}"))
        $r = Invoke-WebRequest -Uri $TOKEN_URL -Method POST -Body $body `
            -Headers @{ Authorization = "Basic $creds"; 'Content-Type' = 'application/x-www-form-urlencoded' } `
            -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
        $newTok = $r.Content | ConvertFrom-Json
        $newTok | Add-Member -NotePropertyName saved_at -NotePropertyValue ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -Force
        Save-Tokens $newTok
        return $newTok
    } catch {
        return $null
    }
}

function Get-ValidToken {
    $tok = Load-Tokens
    if (-not $tok) { return $null }
    $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [long]$tok.saved_at
    if ($age -gt 1700) {   # refresh after ~28 min
        $tok = Refresh-Tokens $tok
    }
    return $tok
}

# Schwab Market Data (/marketdata/v1/quotes) as primary price source, replacing Yahoo -- same
# OAuth token already used for positions, one call covers every symbol (confirmed 2026-08-01:
# all 58 real holdings in 530ms, including tickers FMP's plan can't serve at all).
#
# Field mapping, cross-validated against Yahoo for AAPL on 2026-08-01:
#   regular.regularMarketLastPrice / quote.closePrice == Yahoo's regularMarketPrice (both are
#   the latest completed regular-session close/current-price reference). Schwab doesn't expose
#   a standalone "previous close" field, but regular.regularMarketNetChange is computed against
#   it (confirmed: price - netChange landed within ~0.4 of Yahoo's chartPreviousClose for the
#   same instant), so prevClose is derived from it. Returns a hashtable keyed by symbol with the
#   same {price, prev, name} shape the existing Yahoo/FMP job scriptblock already returns, so it
#   drops into /mobile-data and /auto-log's $px map without touching downstream code.
function Get-SchwabQuotes($tok, [string[]]$symbols) {
    $out = @{}
    if (-not $tok -or -not $symbols -or $symbols.Count -eq 0) { return $out }
    try {
        $symStr = ($symbols -join ',')
        $url = "${API_BASE}/marketdata/v1/quotes?symbols=$([Uri]::EscapeDataString($symStr))"
        $r = Invoke-WebRequest -Uri $url -Headers @{ Authorization = "Bearer $($tok.access_token)"; Accept = 'application/json' } `
            -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
        $data = $r.Content | ConvertFrom-Json
        foreach ($sym in $symbols) {
            $sq = $data.$sym
            if (-not $sq -or -not $sq.quote) { continue }
            $q = $sq.quote; $reg = $sq.regular
            $price = if ($reg -and $reg.regularMarketLastPrice) { [double]$reg.regularMarketLastPrice }
                     elseif ($q.closePrice) { [double]$q.closePrice }
                     elseif ($q.mark)       { [double]$q.mark }
                     elseif ($q.lastPrice)  { [double]$q.lastPrice }
                     else { $null }
            if (-not $price) { continue }
            $prev = if ($reg -and $null -ne $reg.regularMarketNetChange) { $price - [double]$reg.regularMarketNetChange }
                    elseif ($q.closePrice) { [double]$q.closePrice }
                    else { $price }
            # Sanity guard: quote.closePrice has been observed to drift to a stale/rolled-over
            # value over a weekend while regular.regularMarketLastPrice stays fixed (confirmed
            # 2026-08-01) -- if that ever produces an implausible swing, skip this symbol rather
            # than risk corrupting G/L; the caller's Yahoo/FMP fallback picks it up instead.
            if (-not $prev -or [Math]::Abs(($price - $prev) / $prev) -gt 0.5) { continue }
            $name = if ($sq.reference -and $sq.reference.description) { $sq.reference.description } else { $sym }
            $out[$sym] = @{ price = $price; prev = $prev; name = $name }
        }
    } catch { Write-Host "[Schwab Quotes] failed: $_" -ForegroundColor Yellow }
    return $out
}

# --- HTTP helpers -------------------------------------------------------------
function Send-Json($res, $obj, $status = 200) {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Depth 10 -Compress))
    $res.StatusCode  = $status
    $res.ContentType = 'application/json; charset=utf-8'
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
    $res.Close()
}

function Send-Text($res, $text, $status = 200, $ct = 'text/plain; charset=utf-8') {
    $bytes = [Text.Encoding]::UTF8.GetBytes($text)
    $res.StatusCode  = $status
    $res.ContentType = $ct
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
    $res.Close()
}

# Stream.Read() is NOT guaranteed to fill the buffer in one call -- for HttpListener request
# streams it reliably does for small bodies (worked by luck up to ~tens of KB) but silently
# returns a partial read for larger ones, truncating the body with no error. A truncated JSON
# body then fails to parse (or parses to something wrong) downstream. Loop until ContentLength64
# bytes are actually read (or the stream ends).
function Read-RequestBody($req) {
    $len = $req.ContentLength64
    if ($len -le 0) { return [byte[]]@() }
    $bodyBytes = New-Object byte[] $len
    $offset = 0
    while ($offset -lt $len) {
        $read = $req.InputStream.Read($bodyBytes, $offset, $len - $offset)
        if ($read -le 0) { break }  # stream closed early
        $offset += $read
    }
    if ($offset -lt $len) {
        Write-Host "[Server] WARNING: request body short read - expected $len bytes, got $offset" -ForegroundColor Yellow
    }
    return $bodyBytes
}

function Send-Html($res, $file) {
    if (-not (Test-Path $file)) { Send-Text $res 'Not found' 404; return }
    $bytes = [IO.File]::ReadAllBytes($file)
    $res.StatusCode  = 200
    $res.ContentType = 'text/html; charset=utf-8'
    # Never cache the HTML — a stale cached page is the #1 cause of "not loading" / old UI
    # after an edit (browser serves an old copy). Force a fresh fetch every load.
    $res.Headers.Add('Cache-Control', 'no-cache, no-store, must-revalidate')
    $res.Headers.Add('Pragma', 'no-cache')
    $res.Headers.Add('Expires', '0')
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
    $res.Close()
}

function Send-Cors($res) {
    $res.Headers.Add('Access-Control-Allow-Origin',  '*')
    $res.Headers.Add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
    $res.Headers.Add('Access-Control-Allow-Headers', 'Content-Type, Authorization')
}

# The browser ALWAYS writes alphapicks_log via localStorage.setItem(key, JSON.stringify(log)) --
# its write-through POST to /store therefore always sends a STRING value for this key. Whenever
# the server later reads $store.alphapicks_log back out, it's a [string], not a native array/
# object -- `@($store.alphapicks_log)` on a string just wraps the WHOLE STRING as one useless
# array element (never parses it), so every date/tab lookup on it silently returns nothing and
# Write-LogExcel produces a near-empty file. This was the actual root cause of the log "not
# working properly" for a long time -- confirmed 2026-07-26: store.json had the real ~161-entry
# history intact the whole time, just always skipped because it arrived as a string whenever the
# browser (not the server's own /auto-log write) had written it last. Always parse-if-string here.
function Get-LogArray($raw) {
    if ($null -eq $raw) { return @() }
    if ($raw -is [string]) {
        try { return @($raw | ConvertFrom-Json) } catch { return @() }
    }
    return @($raw)
}

# --- Excel log writer ---------------------------------------------------------
function Write-LogExcel {
    param([array]$Log, [string]$Path)
    if (-not $script:hasImportExcel) { return }
    try {
        Import-Module ImportExcel -ErrorAction Stop

        $tabDefs = @(
            @{ id = 'brokerage';  sheet = 'Brokerage';   extraKey = $null },
            @{ id = 'ira';        sheet = 'Retirement';  extraKey = $null },
            @{ id = 'alphapicks'; sheet = 'Alpha Picks'; extraKey = 'usdils' },
            @{ id = 'qgi';        sheet = 'QG&I';        extraKey = $null }
        )

        # Helper: parse any date string to DateTime for sorting/formatting
        function Parse-LogDate([string]$d) {
            $formats = @('yyyy-MM-dd','dd-MMM-yyyy','dd-MMM-yy','MM/dd/yyyy')
            foreach ($fmt in $formats) {
                $dt = [datetime]::MinValue
                if ([datetime]::TryParseExact($d, $fmt, $null, 'None', [ref]$dt)) { return $dt }
            }
            $dt = [datetime]::MinValue
            if ([datetime]::TryParse($d, [ref]$dt)) { return $dt }
            return [datetime]::MinValue
        }

        # Sort log newest-first for all tab processing
        $sortedLog = $Log | Sort-Object { Parse-LogDate $_.date } -Descending

        # Many historical entries predate the nested per-tab log format and store Alpha Picks
        # data directly on the entry (e.data.totalInvested etc., no e.alphapicks sub-object) —
        # the single-day backfillLogEntry() has always written this old flat shape. The client's
        # buildLogWorkbook() already falls back to it; mirror that here so these ~157 historical
        # days don't silently vanish from the Alpha Picks sheet.
        function Get-TabSection($e, $tabId) {
            $sec = $e.$tabId
            if ($sec) { return $sec }
            if ($tabId -eq 'alphapicks' -and $null -ne $e.totalInvested) {
                $symbols = @{}
                foreach ($t in @($e._tickers)) {
                    if ($null -ne $e.$t) { $symbols[$t] = $e.$t }
                }
                return [PSCustomObject]@{
                    totalInvested = $e.totalInvested; currentValue = $e.currentValue
                    dailyChange   = $e.dailyChange;    totalChange  = $e.totalChange
                    pctChange     = $e.pctChange;      spyPct       = $e.spyPct
                    annualReturn  = $e.annualReturn;   spyReturn    = $e.spyReturn
                    _tickers      = @($e._tickers);    _symbols     = $symbols
                }
            }
            return $null
        }

        $pkg = $null
        foreach ($tab in $tabDefs) {
            $tabId = $tab.id

            # Collect unique tickers (newest-first so most recent ticker set leads)
            $seen = @{}; $allTickers = @()
            foreach ($e in $sortedLog) {
                $sec = Get-TabSection $e $tabId
                if (-not $sec) { continue }
                $tickers = if ($sec._tickers) { $sec._tickers } else { @() }
                foreach ($t in $tickers) {
                    if (-not $seen.ContainsKey($t)) { $allTickers += $t; $seen[$t] = 1 }
                }
            }

            $rows = foreach ($e in $sortedLog) {
                $sec = Get-TabSection $e $tabId
                if (-not $sec) { continue }

                # Format date as DD-Mon-YYYY to match reference log format
                $dt = Parse-LogDate $e.date
                $dateDisp = if ($dt -ne [datetime]::MinValue) { $dt.ToString('dd-MMM-yyyy') } else { $e.date }

                # Normalise field names — server entries use value/invested/change;
                # browser entries use totalInvested/currentValue/dailyChange etc.
                $invested  = if ($null -ne $sec.totalInvested)  { $sec.totalInvested  } else { $sec.invested }
                $curVal    = if ($null -ne $sec.currentValue)   { $sec.currentValue   } else { $sec.value    }
                $dayChg    = if ($null -ne $sec.dailyChange)    { $sec.dailyChange    } else { $sec.change   }
                $totChg    = if ($null -ne $sec.totalChange)    { $sec.totalChange    } elseif ($null -ne $invested -and $null -ne $curVal) { $curVal - $invested } else { $null }
                $pctChg    = if ($null -ne $sec.pctChange)      { $sec.pctChange      } elseif ($null -ne $invested -and $invested -ne 0 -and $null -ne $totChg) { $totChg / $invested * 100 } else { $null }

                $row = [ordered]@{
                    'Date'           = $dateDisp
                    'Total Invested' = $invested
                    'Current Value'  = $curVal
                    'Daily Change'   = $dayChg
                    'Total Change'   = $totChg
                    '% Change'       = $pctChg
                    'S&P500 %'       = $sec.spyPct
                    'Annual Return'  = $sec.annualReturn
                    'S&P500 Return'  = $sec.spyReturn
                }
                if ($tab.extraKey) { $row[$tab.extraKey] = $e.($tab.extraKey) }
                foreach ($t in $allTickers) {
                    $row[$t] = if ($sec._symbols -and $null -ne $sec._symbols.$t) { $sec._symbols.$t } else { $null }
                }
                [PSCustomObject]$row
            }

            if (-not $rows) { continue }
            if ($pkg) {
                $pkg = $rows | Export-Excel -ExcelPackage $pkg -WorksheetName $tab.sheet -PassThru -ClearSheet -AutoSize -BoldTopRow
            } else {
                $pkg = $rows | Export-Excel -Path $Path -WorksheetName $tab.sheet -PassThru -ClearSheet -AutoSize -BoldTopRow
            }

            # Number formats: $ columns (Total Invested/Current Value/Daily Change/Total Change,
            # plus every per-ticker price column) get whole-dollar $, % columns get a "%" suffix,
            # and the optional USD/ILS rate column keeps decimal precision.
            $wsFmt = $pkg.Workbook.Worksheets[$tab.sheet]
            $lastRow = $wsFmt.Dimension.End.Row
            $lastCol = $wsFmt.Dimension.End.Column
            $extraCol = if ($tab.extraKey) { 10 } else { 0 }
            for ($c = 2; $c -le $lastCol; $c++) {
                $fmt = if ($c -ge 2 -and $c -le 5) { '$#,##0' }
                       elseif ($c -ge 6 -and $c -le 9) { '0.00"%"' }
                       elseif ($c -eq $extraCol) { '0.000' }
                       else { '$#,##0' }
                $wsFmt.Cells[2, $c, $lastRow, $c].Style.Numberformat.Format = $fmt
            }
        }
        if ($pkg) { Close-ExcelPackage $pkg }
        Write-Host "[Auto-log] Excel written to $Path" -ForegroundColor Green
    } catch {
        Write-Host "[Auto-log] Excel write failed: $_" -ForegroundColor Red
    }
}

# --- Listener setup -----------------------------------------------------------
$listener = New-Object System.Net.HttpListener

# Try all-interface binding (requires Admin)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if ($isAdmin) {
    $listener.Prefixes.Add("http://+:${port}/")
    Write-Host "[Server] Listening on all interfaces (admin mode) — port $port" -ForegroundColor Green
} else {
    $listener.Prefixes.Add("http://localhost:${port}/")
    Write-Host "[Server] Listening on localhost only (non-admin) — port $port" -ForegroundColor Yellow
}

try {
    $listener.Start()
} catch {
    Write-Host "[Server] ERROR: Port $port already in use or access denied. $_" -ForegroundColor Red
    exit 1
}

Write-Host "[Server] Dashboard : http://localhost:$port/dashboard" -ForegroundColor Cyan
Write-Host "[Server] Auth      : http://localhost:$port/auth" -ForegroundColor Cyan

# --- Auto-log background job --------------------------------------------------
$autoLogJob = Start-Job -ScriptBlock {
    param($port, [string[]]$holidays, [string]$logPath)
    # Runs in its own runspace -- can't call the parent scope's Write-AutoLogEvent, so this
    # writes directly. No trimming here (fires at most once/day); Write-AutoLogEvent's trimming
    # on the far more frequent endpoint-side writes keeps the shared file bounded regardless.
    function Log($m) {
        try { Add-Content -Path $logPath -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  [timer] $m" -Encoding UTF8 } catch {}
    }
    $firedDate = ''
    while ($true) {
        Start-Sleep -Seconds 30
        try {
            $et  = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([datetime]::UtcNow, 'Eastern Standard Time')
            $dow = $et.DayOfWeek
            $dk  = $et.ToString('yyyy-MM-dd')
            if ($dow -eq 'Saturday' -or $dow -eq 'Sunday') { continue }
            if ($holidays -contains $dk) { continue }
            if ($et.Hour -eq 16 -and $et.Minute -eq 5 -and $firedDate -ne $dk) {
                $firedDate = $dk
                Log "decided to fire for $dk -- POSTing /auto-log"
                try {
                    $r = Invoke-WebRequest -Uri "http://localhost:$port/auto-log" -Method POST `
                        -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
                    Log "POST returned HTTP $($r.StatusCode) for $dk"
                } catch {
                    Log "POST FAILED for $dk -- $_"
                }
                Write-Output "Auto-log fired for $dk"
            }
        } catch {}
    }
} -ArgumentList $port, $MARKET_HOLIDAYS, $AUTO_LOG_LOG

Write-Host "[Server] Auto-log job started (fires at 4:05 PM ET on trading days)" -ForegroundColor Cyan

# --- Keep-alive job: refreshes Schwab token every 20 min -----------------------
$keepAliveJob = Start-Job -ScriptBlock {
    param($port)
    while ($true) {
        Start-Sleep -Seconds 1200
        try {
            Invoke-WebRequest -Uri "http://localhost:$port/schwab/status" `
                -UseBasicParsing -TimeoutSec 10 -ErrorAction SilentlyContinue | Out-Null
        } catch {}
    }
} -ArgumentList $port
Write-Host "[Server] Keep-alive job started (pings Schwab every 20 min)" -ForegroundColor Cyan

# --- Request loop -------------------------------------------------------------
while ($listener.IsListening) {
    $ctx = $null
    try { $ctx = $listener.GetContext() } catch { break }

    $req  = $ctx.Request
    $res  = $ctx.Response
    $path = $req.Url.AbsolutePath
    $meth = $req.HttpMethod

    Send-Cors $res

    if ($meth -eq 'OPTIONS') {
        $res.StatusCode = 200
        $res.Close()
        continue
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $meth $path" -ForegroundColor DarkGray

    # ── /shutdown ─────────────────────────────────────────────────────────────
    # Graceful stop for the watchdog to call BEFORE ever resorting to Stop-Process -Force.
    # A hard kill skips $listener.Stop()/Close(), leaving the http://*:7843/ URL registration
    # orphaned in HTTP.sys — every subsequent restart attempt then fails with "port already
    # in use", which is what caused hours-long watchdog restart-loop outages. Localhost only.
    if ($path -eq '/shutdown' -and $meth -eq 'POST') {
        if ($req.RemoteEndPoint.Address.ToString() -notin @('127.0.0.1', '::1')) {
            Send-Text $res 'Forbidden' 403
            continue
        }
        Send-Json $res @{ ok = $true }
        Write-Host "[Server] Graceful shutdown requested" -ForegroundColor Yellow
        Start-Sleep -Milliseconds 200
        $listener.Stop()
        $listener.Close()
        exit 0
    }

    # ── /proxy ────────────────────────────────────────────────────────────────
    if ($path -eq '/proxy') {
        $target = ''
        if ($req.Url.Query -match '[?&]url=([^&]+)') {
            $target = [Uri]::UnescapeDataString($Matches[1])
        }
        if (-not $target) { Send-Text $res 'Missing url param' 400; continue }
        try {
            $wr = Invoke-WebRequest -Uri $target -UseBasicParsing -TimeoutSec 12 `
                -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/122.0 Safari/537.36' } `
                -ErrorAction Stop
            Send-Text $res $wr.Content 200 'application/json; charset=utf-8'
        } catch {
            Send-Text $res '{"error":"proxy fetch failed"}' 502 'application/json'
        }
        continue
    }

    # ── /auth ─────────────────────────────────────────────────────────────────
    if ($path -eq '/auth') {
        $scope    = 'readonly'
        $authLink = "${AUTH_URL}?response_type=code&client_id=${CLIENT_ID}&redirect_uri=$([Uri]::EscapeDataString($REDIRECT_URI))&scope=$scope"
        # Redirect the requesting browser tab straight to Schwab's login page — do NOT use
        # Start-Process here. That opens a browser on whichever machine runs this server
        # process, which silently fails when the server runs under an elevated scheduled
        # task (can't hand a URL to an already-running non-elevated browser).
        $res.Redirect($authLink)
        $res.Close()
        continue
    }

    # ── /exchange (called by dashboard dialog with just the code) ─────────────
    if ($path -eq '/exchange') {
        $code = ''
        if ($req.Url.Query -match '[?&]code=([^&]+)') { $code = [Uri]::UnescapeDataString($Matches[1]) }
        if (-not $code) { Send-Json $res @{ connected = $false; error = 'Missing code' } 400; continue }
        try {
            $body  = "grant_type=authorization_code&code=$([Uri]::EscapeDataString($code))&redirect_uri=$([Uri]::EscapeDataString($REDIRECT_URI))"
            $creds = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${CLIENT_ID}:${CLIENT_SECRET}"))
            $r     = Invoke-WebRequest -Uri $TOKEN_URL -Method POST -Body $body `
                -Headers @{ Authorization = "Basic $creds"; 'Content-Type' = 'application/x-www-form-urlencoded' } `
                -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
            $tok = $r.Content | ConvertFrom-Json
            $tok | Add-Member -NotePropertyName saved_at -NotePropertyValue ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -Force
            Save-Tokens $tok
            Send-Json $res @{ connected = $true }
        } catch {
            Send-Json $res @{ connected = $false; error = "$_" } 500
        }
        continue
    }

    # ── /callback ─────────────────────────────────────────────────────────────
    if ($path -eq '/callback') {
        $code = ''
        if ($req.Url.Query -match '[?&]code=([^&]+)') { $code = [Uri]::UnescapeDataString($Matches[1]) }
        if (-not $code) { Send-Text $res 'Missing code' 400; continue }
        try {
            $body  = "grant_type=authorization_code&code=$([Uri]::EscapeDataString($code))&redirect_uri=$([Uri]::EscapeDataString($REDIRECT_URI))"
            $creds = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${CLIENT_ID}:${CLIENT_SECRET}"))
            $r     = Invoke-WebRequest -Uri $TOKEN_URL -Method POST -Body $body `
                -Headers @{ Authorization = "Basic $creds"; 'Content-Type' = 'application/x-www-form-urlencoded' } `
                -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
            $tok = $r.Content | ConvertFrom-Json
            $tok | Add-Member -NotePropertyName saved_at -NotePropertyValue ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -Force
            Save-Tokens $tok
            Send-Text $res '<html><body><h2 style="color:green">✓ Schwab connected! You may close this tab.</h2></body></html>' 200 'text/html'
        } catch {
            Send-Text $res "Token exchange failed: $_" 500
        }
        continue
    }

    # ── /schwab/status ────────────────────────────────────────────────────────
    if ($path -eq '/schwab/status') {
        $tok = Load-Tokens
        if (-not $tok) { Send-Json $res @{ connected = $false; reason = 'No tokens' }; continue }
        $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [long]$tok.saved_at
        $tok = Get-ValidToken
        $accountCount = 0
        try {
            $r = Invoke-WebRequest -Uri "${API_BASE}/trader/v1/accounts" `
                -Headers @{ Authorization = "Bearer $($tok.access_token)"; Accept = 'application/json' } `
                -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
            $accts = $r.Content | ConvertFrom-Json
            $accountCount = @($accts).Count
        } catch {}
        Send-Json $res @{ connected = $true; age_seconds = $age; expires_in = (1800 - $age); accountCount = $accountCount }
        continue
    }

    # ── /schwab/api ───────────────────────────────────────────────────────────
    if ($path -eq '/schwab/api') {
        $apiPath = ''
        if ($req.Url.Query -match '[?&]path=([^&]+)') { $apiPath = [Uri]::UnescapeDataString($Matches[1]) }
        if (-not $apiPath) { Send-Text $res 'Missing path param' 400; continue }
        $tok = Get-ValidToken
        if (-not $tok) { Send-Json $res @{ error = 'Not authenticated' } 401; continue }
        try {
            $apiUrl = "${API_BASE}${apiPath}"
            $wr = Invoke-WebRequest -Uri $apiUrl -UseBasicParsing -TimeoutSec 20 `
                -Headers @{ Authorization = "Bearer $($tok.access_token)"; Accept = 'application/json' } `
                -ErrorAction Stop
            Send-Text $res $wr.Content 200 'application/json; charset=utf-8'
        } catch {
            $sc = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 500 }
            Send-Text $res "{`"error`":`"Schwab API failed: $_`"}" $sc 'application/json'
        }
        continue
    }

    # ── /mobile-data (GET) — serve cache if fresh; otherwise compute live ─────
    if ($path -eq '/mobile-data') {
        $mobileDataFile = Join-Path $scriptDir 'mobile_data.json'

        # Serve cached file if < 10 minutes old
        if (Test-Path $mobileDataFile) {
            $ageMin = ([DateTimeOffset]::UtcNow - [DateTimeOffset](Get-Item $mobileDataFile).LastWriteTimeUtc).TotalMinutes
            if ($ageMin -lt 10) {
                $bytes = [IO.File]::ReadAllBytes($mobileDataFile)
                $res.StatusCode  = 200
                $res.ContentType = 'application/json; charset=utf-8'
                $res.OutputStream.Write($bytes, 0, $bytes.Length)
                $res.Close()
                continue
            }
        }

        Write-Host "[Mobile] Cache stale — computing live data from Schwab + FMP..." -ForegroundColor Cyan
        try {
            # This live-compute path has no PowerShell equivalent of the desktop's IRR engine or
            # QG&I group-split logic (see /auto-log's identical comment), so it can only ever
            # rebuild activePositions/brokerage/ira/prices -- never the *IrrRate/*SpyIrrRate/
            # *SpySimpleRet fields or qgiPositions. Whichever browser tab last ran syncToCloud()
            # wrote those into THIS SAME FILE via /save-mobile-data. Writing $payload2 over the
            # file unconditionally therefore blanks them out the moment a phone check (or anything
            # else hitting this endpoint) goes >10 min without a browser sync -- confirmed
            # 2026-08-11: a mid-afternoon phone check clobbered the morning's browser-sourced IRR
            # data, so that night's unattended /auto-log run (which reads mobile_data.json, per the
            # 08:36am fix) logged nulls again despite that fix being live all day. Carry the prior
            # file's browser-only fields forward so a live-compute refresh degrades gracefully
            # (stale IRR numbers) instead of erasing them outright.
            $prevMobileData = $null
            if (Test-Path $mobileDataFile) { try { $prevMobileData = Get-Content $mobileDataFile -Raw | ConvertFrom-Json } catch {} }

            # Load store for sold/sales/alerts
            $store = @{}
            if (Test-Path $storeFile) { try { $store = Get-Content $storeFile -Raw | ConvertFrom-Json } catch {} }

            # Get Schwab positions
            $tok = Get-ValidToken
            $allSwPos = @()
            # Schwab's securitiesAccount.type is the registration type (CASH/MARGIN), not tax status —
            # it never matches an IRA-sounding string. IRA classification must go by account number
            # (same source of truth the browser uses: schwab_retirement_accounts).
            $iraAccountNums = Get-LogArray $store.schwab_retirement_accounts
            if ($tok) {
                try {
                    $r = Invoke-WebRequest -Uri "${API_BASE}/trader/v1/accounts?fields=positions" `
                        -Headers @{ Authorization = "Bearer $($tok.access_token)"; Accept = 'application/json' } `
                        -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
                    $accounts = $r.Content | ConvertFrom-Json
                    foreach ($acct in $accounts) {
                        $acctNum = "$($acct.securitiesAccount.accountNumber)"
                        $isIraAcct = $iraAccountNums -contains $acctNum
                        $pList = $acct.securitiesAccount.positions
                        if ($pList) {
                            foreach ($p in $pList) {
                                $allSwPos += [PSCustomObject]@{
                                    symbol   = $p.instrument.symbol
                                    shares   = [double]$p.longQuantity
                                    avgPrice = [double]$p.averageLongPrice
                                    isIra    = $isIraAcct
                                }
                            }
                        }
                    }
                } catch { Write-Host "[Mobile] Schwab error: $_" -ForegroundColor Yellow }
            }

            # Collect all unique symbols for FMP
            $allSyms = ($ALPHA_PICKS_SYMS + ($allSwPos | ForEach-Object { $_.symbol })) | Sort-Object -Unique

            # Schwab Market Data PRIMARY -- one call covers every symbol (same OAuth token as
            # positions, already fetched above). Only symbols Schwab misses fall through to the
            # per-symbol Yahoo/FMP jobs below.
            $px = Get-SchwabQuotes -tok $tok -symbols $allSyms
            $remainingSyms = $allSyms | Where-Object { -not $px.ContainsKey($_) }

            # Fetch remaining prices in parallel. Yahoo v8 chart is fallback; FMP only fills a
            # symbol Yahoo missed too, and only during REGULAR market hours -- FMP's free tier is
            # 250 calls/day total (confirmed 2026-07-30), and this endpoint alone could burn
            # through that in one cache-refresh cycle under the old FMP-first order. $session is
            # computed once here (outside the job) since Start-Job runspaces can't see outer-scope
            # state.
            $mobileSession = Get-MarketSession
            $fmpSB = [scriptblock]::Create(@'
param($s, $k, $sess)
# Jobs run in a separate runspace — ensure TLS 1.2 so HTTPS to FMP/Yahoo works.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# Primary: Yahoo v8 chart (server-side fetch, no CORS; more tolerant than v7, which 401s).
try {
    $yurl = "https://query1.finance.yahoo.com/v8/finance/chart/$($s)?interval=1d&range=1d"
    $yr = Invoke-WebRequest -Uri $yurl -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop -Headers @{ 'User-Agent' = 'Mozilla/5.0' }
    $yd = $yr.Content | ConvertFrom-Json
    $meta = $yd.chart.result[0].meta
    if ($meta -and $meta.regularMarketPrice) {
        return @{ price = [double]$meta.regularMarketPrice; prev = [double]$meta.chartPreviousClose; name = [string]$s }
    }
} catch {}

if ($sess -ne 'REGULAR') { return $null } # FMP off-limits outside market hours

# Backup: FMP, retried up to 3x. A burst of ~20 parallel jobs can trip FMP's 429 rate
# limit; a jittered backoff + retry lets a throttled request succeed on a later attempt
# instead of returning no price (which would zero the position's market value downstream).
for ($i = 0; $i -lt 3; $i++) {
    try {
        $url = "https://financialmodelingprep.com/stable/quote?symbol=$s&apikey=$k"
        $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
        $d = $r.Content | ConvertFrom-Json
        if ($d -and $d.Count -gt 0 -and $d[0].price) {
            return @{ price = [double]$d[0].price; prev = [double]$d[0].previousClose; name = [string]$d[0].name; usedFmp = $true }
        }
    } catch {
        Start-Sleep -Milliseconds (400 + (Get-Random -Maximum 800))
    }
}

return $null
'@)
            $fmpJobs2 = @{}
            foreach ($sym in $remainingSyms) {
                $fmpJobs2[$sym] = Start-Job -ScriptBlock $fmpSB -ArgumentList $sym, $FMP_KEY_SERVER, $mobileSession
            }
            $fmpUsedSyms = @()
            foreach ($sym in $remainingSyms) {
                $j = $fmpJobs2[$sym]; Wait-Job $j -Timeout 30 | Out-Null
                $r2 = Receive-Job $j; Remove-Job $j -Force
                if ($r2) {
                    $px[$sym] = $r2
                    if ($r2.usedFmp) { $fmpUsedSyms += $sym }
                }
            }
            Write-FmpUsage 'mobile-data' $fmpUsedSyms

            # Buy dates (mirror of INITIAL_BUY_DATES in Portfolio.html)
            $bd = @{
                TTMI='2025-12-03'; MU='2025-12-03'; INCY='2025-12-03'; PARR='2025-12-03'
                W='2025-12-03'; TIGO='2025-12-16'; B='2026-01-05'; NEM='2026-01-16'
                DY='2026-02-02'; GM='2026-02-17'; FN='2026-03-02'; LITE='2026-03-16'
                SPY='2023-09-12'; MSFT='2024-12-04'; AIRR='2024-08-02'
                NEOS='2025-09-11'; LDQH='2025-04-14'; CRDO='2026-05-01'; CGDV='2026-05-13'
                ARCC='2024-11-08'; JAAA='2024-06-04'; BSM='2025-03-04'
                DIVO='2026-02-18'; QQQI='2025-09-11'; HGI='2022-09-30'; HGIII='2026-06-02'
            }

            # Build activePositions (Alpha Picks tab)
            $activePositions = @()
            foreach ($sym in $ALPHA_PICKS_SYMS) {
                $sw = $allSwPos | Where-Object { $_.symbol -eq $sym -and -not $_.isIra } | Select-Object -First 1
                $shares   = if ($sw) { [double]$sw.shares }   else { 0 }
                $avgPrice = if ($sw) { [double]$sw.avgPrice } else { 0 }
                $p        = if ($px.ContainsKey($sym)) { $px[$sym] } else { $null }
                $curPrice = if ($p) { $p.price } else { 0 }
                $prev     = if ($p) { $p.prev  } else { 0 }
                $dayPct   = if ($prev -gt 0) { [Math]::Round(($curPrice - $prev) / $prev * 100, 3) } else { $null }
                $activePositions += [ordered]@{
                    id = $sym; ticker = $sym; symbol = $sym
                    company      = if ($p) { $p.name } else { $sym }
                    shares       = $shares
                    cost         = [Math]::Round($avgPrice * $shares, 2)
                    pps          = $avgPrice
                    date         = if ($bd.ContainsKey($sym)) { $bd[$sym] } else { '' }
                    currentPrice = $curPrice
                    mktVal       = [Math]::Round($curPrice * $shares, 2)
                    dayPct       = $dayPct
                }
            }

            # Build brokerage positions (non-AP Schwab positions)
            $brokerage = @()
            foreach ($sw in ($allSwPos | Where-Object { -not $_.isIra })) {
                $sym = $sw.symbol
                if (-not $sym) { continue }
                if ($ALPHA_PICKS_SYMS -contains $sym) { continue }
                $p      = if ($px.ContainsKey($sym)) { $px[$sym] } else { $null }
                $curPrice = if ($p) { $p.price } else { 0 }
                $prev   = if ($p) { $p.prev } else { 0 }
                $dayPct = if ($prev -gt 0) { [Math]::Round(($curPrice - $prev) / $prev * 100, 3) } else { $null }
                $brokerage += [ordered]@{
                    symbol = $sym; company = if ($p) { $p.name } else { $sym }
                    shares = [double]$sw.shares
                    mktVal = [Math]::Round($curPrice * [double]$sw.shares, 2)
                    costBasis = [Math]::Round([double]$sw.avgPrice * [double]$sw.shares, 2)
                    currentPrice = $curPrice; date = if ($bd.ContainsKey($sym)) { $bd[$sym] } else { '' }
                    dayPct = $dayPct; irrRate = $null
                }
            }

            # Build IRA positions
            # KNOWN LIMITATION: HGI private-fund positions have no exchange symbol ($sym is
            # null) and are skipped here -- same limitation /auto-log's equivalent loop already
            # documents. Without this guard, $px.ContainsKey($null) throws, which was silently
            # caught by this endpoint's outer try/catch and masked by falling back to a
            # (progressively stale) cached mobile_data.json -- confirmed 2026-08-01 when forcing
            # a fresh compute (deleting the cache) surfaced the throw for the first time.
            $ira = @()
            foreach ($sw in ($allSwPos | Where-Object { $_.isIra })) {
                $sym = $sw.symbol
                if (-not $sym) { continue }
                $p      = if ($px.ContainsKey($sym)) { $px[$sym] } else { $null }
                $curPrice = if ($p) { $p.price } else { 0 }
                $prev   = if ($p) { $p.prev } else { 0 }
                $dayPct = if ($prev -gt 0) { [Math]::Round(($curPrice - $prev) / $prev * 100, 3) } else { $null }
                $ira += [ordered]@{
                    symbol = $sym; company = if ($p) { $p.name } else { $sym }
                    shares = [double]$sw.shares
                    mktVal = [Math]::Round($curPrice * [double]$sw.shares, 2)
                    costBasis = [Math]::Round([double]$sw.avgPrice * [double]$sw.shares, 2)
                    currentPrice = $curPrice; date = if ($bd.ContainsKey($sym)) { $bd[$sym] } else { '' }
                    dayPct = $dayPct; irrRate = $null
                }
            }

            # Sold/sales/alerts from store
            $soldRows = @(); $sales2 = @(); $alerts2 = [PSCustomObject]@{}
            if ($store.alphapicks_sold_rows)  { try { $soldRows = @($store.alphapicks_sold_rows)  } catch {} }
            if ($store.alphapicks_sales)      { try { $sales2   = @($store.alphapicks_sales)      } catch {} }
            if ($store.alphapicks_div_alerts) { try { $alerts2  = $store.alphapicks_div_alerts    } catch {} }

            $payload2 = [ordered]@{
                ts              = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                activePositions = $activePositions
                soldRows        = $soldRows
                sales           = $sales2
                alerts          = $alerts2
                brokerage       = $brokerage
                ira             = $ira
                serverComputed  = $true
            }

            # Carry forward the browser-only fields this endpoint can't compute (see comment
            # above) so they survive a live-compute refresh instead of being dropped to null.
            if ($prevMobileData) {
                foreach ($k in @('qgiPositions','allocation',
                                  'brokerageIrrRate','brokerageSpyIrrRate','brokerageSpySimpleRet',
                                  'iraIrrRate','iraSpyIrrRate','iraSpySimpleRet',
                                  'alphaPicksIrrRate','alphaPicksSpyIrrRate','alphaPicksSpySimpleRet',
                                  'qgiIrrRate','qgiSpyIrrRate','qgiSpySimpleRet',
                                  'qgiBenchIrrRate','qgiBenchSimpleRet',
                                  'spyChipText','spyChipColor','spyChipLabel')) {
                    $val = $prevMobileData.$k
                    if ($null -ne $val) { $payload2[$k] = $val }
                }
            }

            $json2 = $payload2 | ConvertTo-Json -Depth 10 -Compress
            [IO.File]::WriteAllText($mobileDataFile, $json2, [Text.Encoding]::UTF8)
            Write-Host "[Mobile] Live data ready: $($activePositions.Count) AP, $($brokerage.Count) brok, $($ira.Count) IRA" -ForegroundColor Green
            Send-Text $res $json2 200 'application/json; charset=utf-8'
        } catch {
            Write-Host "[Mobile] ERROR: $_" -ForegroundColor Red
            # Fall back to stale cache rather than 404
            if (Test-Path $mobileDataFile) {
                $bytes = [IO.File]::ReadAllBytes($mobileDataFile)
                $res.StatusCode = 200; $res.ContentType = 'application/json; charset=utf-8'
                $res.OutputStream.Write($bytes, 0, $bytes.Length); $res.Close()
            } else {
                Send-Json $res @{ error = 'No data available' } 503
            }
        }
        continue
    }

    # ── /save-mobile-data (POST) — desktop pushes snapshot for mobile ─────────
    if ($path -eq '/save-mobile-data' -and $meth -eq 'POST') {
        $mobileDataFile = Join-Path $scriptDir 'mobile_data.json'
        try {
            $bodyBytes = Read-RequestBody $req
            [IO.File]::WriteAllBytes($mobileDataFile, $bodyBytes)
            Send-Json $res @{ ok = $true }
        } catch {
            Send-Json $res @{ ok = $false; error = "$_" } 500
        }
        continue
    }

    # ── /store (GET / POST) ───────────────────────────────────────────────────
    if ($path -eq '/store') {
        if ($meth -eq 'GET') {
            if (Test-Path $storeFile) {
                $bytes = [IO.File]::ReadAllBytes($storeFile)
                $res.StatusCode  = 200
                $res.ContentType = 'application/json; charset=utf-8'
                $res.OutputStream.Write($bytes, 0, $bytes.Length)
                $res.Close()
            } else {
                Send-Json $res @{}
            }
        } elseif ($meth -eq 'POST') {
            try {
                $bodyBytes = Read-RequestBody $req
                $bodyStr = [System.Text.Encoding]::UTF8.GetString($bodyBytes)
                $incoming = $bodyStr | ConvertFrom-Json
                # Key-value pair update: merge single key into existing store
                if ($incoming.PSObject.Properties['key'] -and $incoming.PSObject.Properties.Name.Count -le 3) {
                    # -AsHashtable does not exist on Windows PowerShell 5.1's ConvertFrom-Json (PS6+ only) —
                    # it was silently throwing here, swallowed by the catch below, so $store2 was ALWAYS
                    # empty and every single-key write was overwriting the entire store with just that key.
                    $store2 = @{}
                    $existingReadOk = $true
                    if (Test-Path $storeFile) {
                        try {
                            $existing = Get-Content $storeFile -Raw | ConvertFrom-Json
                            foreach ($prop in $existing.PSObject.Properties) { $store2[$prop.Name] = $prop.Value }
                        } catch { $existingReadOk = $false }
                    }
                    # CRITICAL: if the existing store exists but couldn't be parsed, do NOT write —
                    # rebuilding from an empty hashtable would overwrite the whole store with just this
                    # one key, wiping everything else. This is what wiped schwab_csv_txns / retirement
                    # accounts when a corrupted alphapicks_log made the store unparseable. Abort instead.
                    if ((Test-Path $storeFile) -and -not $existingReadOk) {
                        Send-Json $res @{ ok = $false; error = 'existing store unparseable - write aborted to protect other keys' } 500
                        continue
                    }
                    if ($null -eq $incoming.value) {
                        $store2.Remove($incoming.key)
                    } else {
                        $store2[$incoming.key] = $incoming.value
                    }
                    $store2 | ConvertTo-Json -Depth 10 -Compress | Set-Content $storeFile -Encoding UTF8
                } else {
                    # Full store replacement (legacy)
                    [IO.File]::WriteAllBytes($storeFile, $bodyBytes)
                }
                Send-Json $res @{ ok = $true }
            } catch {
                Send-Json $res @{ ok = $false; error = "$_" } 500
            }
        } else {
            Send-Text $res 'Method not allowed' 405
        }
        continue
    }

    # ── /fmp-usage-log (POST — client reports every time it used FMP as a Yahoo-miss backup) ──
    # Purely for measuring real-world FMP call volume after the Yahoo-primary/FMP-backup change;
    # never blocks or affects the caller's own price fetch.
    if ($path -eq '/fmp-usage-log' -and $meth -eq 'POST') {
        try {
            $bodyBytes = Read-RequestBody $req
            $payload   = ([System.Text.Encoding]::UTF8.GetString($bodyBytes)) | ConvertFrom-Json
            $symbols   = @($payload.symbols)
            $context   = if ($payload.context) { "$($payload.context)" } else { 'unknown' }
            Write-FmpUsage $context $symbols
            Send-Json $res @{ ok = $true }
        } catch {
            Send-Json $res @{ ok = $false } 500
        }
        continue
    }

    # ── /fmp-usage-summary (GET — today's total FMP call count, for the daily dashboard toast) ──
    # alreadyShown/claim logic lives here (not in the client) so the "one toast per day" rule is
    # a single global fact in store.json, not a per-browser-origin localStorage flag -- accessing
    # the dashboard via localhost/LAN IP/Tailscale IP are three separate origins with separate
    # localStorage, which is exactly what produced three duplicate toasts (confirmed 2026-08-01).
    # Whichever client asks first on a given day "claims" the toast; every other client (any
    # origin, any tab) sees alreadyShown=true and skips it.
    if ($path -eq '/fmp-usage-summary' -and $meth -eq 'GET') {
        $todayStr = ([System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([datetime]::UtcNow, 'Eastern Standard Time')).ToString('yyyy-MM-dd')
        $totalCalls = 0
        if (Test-Path $FMP_USAGE_LOG) {
            Get-Content $FMP_USAGE_LOG | ForEach-Object {
                if ($_ -match '^(\d{4}-\d{2}-\d{2})\s+\d{2}:\d{2}:\d{2}\s+\[[^\]]+\]\s+(\d+)\s+symbols') {
                    if ($matches[1] -eq $todayStr) { $totalCalls += [int]$matches[2] }
                }
            }
        }
        $store = @{}
        if (Test-Path $storeFile) { try { $store = Get-Content $storeFile -Raw | ConvertFrom-Json } catch {} }
        $alreadyShown = ("$($store.fmp_toast_shown_date)" -eq $todayStr)
        if (-not $alreadyShown) {
            if (-not ($store | Get-Member -Name fmp_toast_shown_date -ErrorAction SilentlyContinue)) {
                $store | Add-Member -NotePropertyName fmp_toast_shown_date -NotePropertyValue $todayStr -Force
            } else {
                $store.fmp_toast_shown_date = $todayStr
            }
            try { $store | ConvertTo-Json -Depth 10 -Compress | Set-Content $storeFile -Encoding UTF8 } catch {}
        }
        Send-Json $res @{ date = $todayStr; totalCalls = $totalCalls; limit = 250; overLimit = ($totalCalls -gt 250); alreadyShown = $alreadyShown }
        continue
    }

    # ── /yahoo-failure-log (POST — client reports every time Yahoo's chart API had no price) ──
    # Purely diagnostic (see Write-YahooFailure); never blocks or affects the caller's own fetch.
    if ($path -eq '/yahoo-failure-log' -and $meth -eq 'POST') {
        try {
            $bodyBytes = Read-RequestBody $req
            $payload   = ([System.Text.Encoding]::UTF8.GetString($bodyBytes)) | ConvertFrom-Json
            Write-YahooFailure "$($payload.symbol)"
            Send-Json $res @{ ok = $true }
        } catch {
            Send-Json $res @{ ok = $false } 500
        }
        continue
    }

    # ── /auto-log (POST — called by background job at 4:05 PM ET, or by browser Export Log) ────
    if ($path -eq '/auto-log' -and $meth -eq 'POST') {
        Write-Host "[Auto-log] Starting daily log capture..." -ForegroundColor Cyan
        Write-AutoLogEvent "endpoint entered (caller=$(if ($ctx.Request.ContentLength64 -gt 0) { 'browser' } else { 'unattended/timer' }))"
        try {
            # Load store
            $store = @{}
            if (Test-Path $storeFile) {
                try { $store = Get-Content $storeFile -Raw | ConvertFrom-Json } catch {}
            }

            # Check if browser sent its own captured entry + full log (fast path — no FMP fetch needed)
            $browserPayload = $null
            try {
                $bodyLen = $ctx.Request.ContentLength64
                if ($bodyLen -gt 0) {
                    $bodyBytes = Read-RequestBody $ctx.Request
                    $bodyStr = [System.Text.Encoding]::UTF8.GetString($bodyBytes)
                    if ($bodyStr.Trim().StartsWith('{')) {
                        $browserPayload = $bodyStr | ConvertFrom-Json
                    }
                }
            } catch {}

            if ($browserPayload -and $browserPayload.entry) {
                Write-Host "[Auto-log] Using browser-provided entry (fast path)" -ForegroundColor Cyan
                Write-AutoLogEvent "browser fast-path: entry for $(if ($browserPayload.entry.date) { $browserPayload.entry.date } else { $browserPayload.entry._key })"
                $log = @()
                if ($browserPayload.fullLog) {
                    try { $log = Get-LogArray $browserPayload.fullLog } catch {}
                } elseif ($store.alphapicks_log) {
                    $log = Get-LogArray $store.alphapicks_log
                }
                $entry = $browserPayload.entry
                $dateVal = if ($entry.date) { $entry.date } else { $entry._key }
                # Match on _key AND .date, and check the incoming entry's OWN _key too --
                # a stray entry left over from the server's ISO-dated raw fallback (no
                # matching browser _key) would otherwise survive a same-day dedup that only
                # compared one field/format, producing a duplicate row for the same trading day.
                $entryKey = $entry._key
                $log = @($log | Where-Object {
                    $_.date -ne $dateVal -and $_._key -ne $dateVal -and
                    (-not $entryKey -or ($_.date -ne $entryKey -and $_._key -ne $entryKey))
                })
                $log = @($entry) + $log
                if (-not ($store | Get-Member -Name alphapicks_log -ErrorAction SilentlyContinue)) {
                    $store | Add-Member -NotePropertyName alphapicks_log -NotePropertyValue $log -Force
                } else { $store.alphapicks_log = $log }
                $store | ConvertTo-Json -Depth 10 -Compress | Set-Content $storeFile -Encoding UTF8
                Write-LogExcel -Log $log -Path $LOG_XLSX_PATH
                Send-Json $res @{ ok = $true; date = $dateVal; source = 'browser' }
                continue
            }

            # The unattended timer fires unconditionally at a fixed ET time every trading day,
            # with no idea whether a browser already captured+pushed today's REAL entry (fast
            # path above) earlier that evening. Without this guard it always recomputes this
            # endpoint's necessarily-degraded server-side approximation (no live IRR engine,
            # $store.usdils is never populated by anything) and blindly overwrites whatever's
            # already there -- confirmed 2026-08-12: the browser captured a correct entry (real
            # usdils) at 23:00:11 ET, then the 23:05:03 timer fired 5 minutes later anyway and
            # clobbered it with a null-usdils fallback entry. If today's trading day already has
            # ANY logged entry, there's nothing for this unattended run to do.
            $nowEt    = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTimeOffset]::UtcNow.UtcDateTime, 'Eastern Standard Time')
            $todayKey = $nowEt.ToString('yyyy-MM-dd')
            $existingLog = Get-LogArray $store.alphapicks_log
            if ($existingLog | Where-Object { $_._key -eq $todayKey -or $_.date -eq $todayKey }) {
                Write-Host "[Auto-log] Entry already exists for $todayKey -- skipping unattended fallback" -ForegroundColor Yellow
                Write-AutoLogEvent "skipped -- entry already exists for $todayKey (already captured, likely by browser)"
                Send-Json $res @{ ok = $true; date = $todayKey; source = 'skipped-already-logged' }
                continue
            }

            # Reference rates (SPY/IRR benchmarks) + QG&I positions, sourced from the browser's
            # own last sync snapshot. NOT from $store -- $store.alphaPicksIrrRate (and the
            # brokerage/ira/qgi equivalents) is never actually written by the browser; syncToCloud()
            # posts those fields to /save-mobile-data, which lands in this separate mobile_data.json
            # file, not store.json. Confirmed 2026-08-10: every one of those $store.* keys was
            # `undefined`, which is why alphapicks/brokerage/ira's spyPct/annualReturn/spyReturn came
            # back null on every unattended run, permanently, not just that one day. QG&I is worse --
            # this endpoint never computed a qgi block at all, because QG&I shares physical Schwab
            # positions with other tabs for some tickers (e.g. "B") and splits them via the desktop's
            # own group_alloc/sliceForGroup logic, which has no PowerShell equivalent here. Reading
            # mobile_data.json's already-split qgiPositions sidesteps reimplementing that logic.
            $mobileData = $null
            $mobileDataFile = Join-Path $scriptDir 'mobile_data.json'
            if (Test-Path $mobileDataFile) {
                try { $mobileData = Get-Content $mobileDataFile -Raw | ConvertFrom-Json } catch {}
            }

            # Get Schwab positions first so we know all symbols to fetch
            $tok = Get-ValidToken
            if (-not $tok) { Write-AutoLogEvent "no valid Schwab token -- proceeding without live positions" }
            $schwabPos = @()
            if ($tok) {
                try {
                    $r = Invoke-WebRequest -Uri "${API_BASE}/trader/v1/accounts?fields=positions" `
                        -Headers @{ Authorization = "Bearer $($tok.access_token)"; Accept = 'application/json' } `
                        -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
                    $accounts = $r.Content | ConvertFrom-Json
                    foreach ($acct in $accounts) {
                        $acctNum   = "$($acct.securitiesAccount.accountNumber)"
                        $positions = $acct.securitiesAccount.positions
                        if ($positions) {
                            foreach ($pos in $positions) {
                                $schwabPos += @{
                                    symbol        = $pos.instrument.symbol
                                    shares        = [double]$pos.longQuantity
                                    avgPrice      = [double]$pos.averageLongPrice
                                    accountNumber = $acctNum
                                }
                            }
                        }
                    }
                } catch {
                    Write-Host "[Auto-log] Schwab API error: $_" -ForegroundColor Yellow
                }
            }

            # Fetch prices for all symbols (sequential direct calls — no Start-Job overhead).
            # Yahoo v8 chart is now PRIMARY, FMP only fills a symbol Yahoo missed, and only during
            # REGULAR market hours -- FMP's free tier is 250 calls/day total (confirmed
            # 2026-07-30), which the OLD FMP-first order blew through in minutes across every
            # price-refresh path in the app combined. This endpoint fires at 4:05pm ET, i.e.
            # right at the REGULAR->POST boundary, so in practice it will rarely if ever reach
            # for FMP at all -- Yahoo's closing print should already be authoritative by then.
            $allFmpSyms = ($ALPHA_PICKS_SYMS + ($schwabPos | ForEach-Object { $_.symbol } | Where-Object { $_ })) |
                          Sort-Object -Unique
            $session = Get-MarketSession

            # Schwab Market Data PRIMARY -- one call covers every symbol (same OAuth token
            # already used for positions above). Only symbols Schwab misses fall through to the
            # per-symbol Yahoo/FMP loop below.
            $prices = Get-SchwabQuotes -tok $tok -symbols $allFmpSyms
            $remainingFmpSyms = $allFmpSyms | Where-Object { -not $prices.ContainsKey($_) }
            foreach ($sym in $remainingFmpSyms) {
                try {
                    $yurl = "https://query1.finance.yahoo.com/v8/finance/chart/$($sym)?interval=1d&range=1d"
                    $yr   = Invoke-WebRequest -Uri $yurl -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop -Headers @{ 'User-Agent' = 'Mozilla/5.0' }
                    $meta = ($yr.Content | ConvertFrom-Json).chart.result[0].meta
                    if ($meta -and $meta.regularMarketPrice) {
                        $prev = if ($meta.previousClose) { $meta.previousClose } else { $meta.chartPreviousClose }
                        $prices[$sym] = @{ price = [double]$meta.regularMarketPrice; prev = [double]$prev }
                        continue
                    }
                } catch {
                    Write-Host "[Auto-log] Yahoo miss: $sym" -ForegroundColor DarkGray
                }
                if ($session -ne 'REGULAR') { continue } # FMP off-limits outside market hours
                try {
                    $url  = "https://financialmodelingprep.com/stable/quote?symbol=$sym&apikey=$FMP_KEY_SERVER"
                    $data = Invoke-RestMethod -Uri $url -TimeoutSec 10 -ErrorAction Stop
                    if ($data -and $data.Count -gt 0) {
                        $prices[$sym] = @{ price = [double]$data[0].price; prev = [double]$data[0].previousClose }
                        Write-FmpUsage 'auto-log' @($sym)
                    }
                } catch {
                    Write-Host "[Auto-log] FMP fallback miss: $sym" -ForegroundColor DarkGray
                }
            }

            # Quality gate: if a price source outage (like the FMP quota hit above) left most
            # symbols without a real price, every position would fall back to curVal=invested
            # (0 daily/total change) -- a flat, useless snapshot that's worse than no snapshot at
            # all, since it silently pollutes the log rather than leaving today's entry for the
            # browser's own (better-sourced) capture or next-run backfill to fill in properly.
            $pricedCount = ($allFmpSyms | Where-Object { $prices.ContainsKey($_) }).Count
            if ($allFmpSyms.Count -gt 0 -and ($pricedCount / $allFmpSyms.Count) -lt 0.6) {
                Write-Host "[Auto-log] Aborting: only $pricedCount/$($allFmpSyms.Count) symbols priced (FMP/Yahoo both degraded) — not writing a flat snapshot" -ForegroundColor Red
                Write-AutoLogEvent "ABORTED -- only $pricedCount/$($allFmpSyms.Count) symbols priced (FMP/Yahoo both degraded); no entry written"
                Write-PriceAlert $pricedCount $allFmpSyms.Count $store $storeFile
                Send-Json $res @{ ok = $false; error = "price sources degraded: $pricedCount/$($allFmpSyms.Count) symbols priced" } 503
                continue
            }

            # Schwab's securitiesAccount.type is the registration type (CASH/MARGIN), not tax status —
            # it never matches an IRA-sounding string. IRA classification must go by account number
            # (same source of truth the browser uses: schwab_retirement_accounts).
            $iraAccountNums = Get-LogArray $store.schwab_retirement_accounts

            # Compute Alpha Picks tab value + per-ticker symbols
            $apValue = 0.0; $apPrevValue = 0.0; $apInvestedLive = 0.0; $apHasLiveCost = $false
            $apTickers = @(); $apSymbols = @{}
            foreach ($sym in $ALPHA_PICKS_SYMS) {
                $match = $schwabPos | Where-Object { $_.symbol -eq $sym } | Select-Object -First 1
                $shares = 0.0; $avgPrice = 0.0
                if ($match) { $shares = [double]$match.shares; $avgPrice = [double]$match.avgPrice; $apHasLiveCost = $true }
                if ($shares -eq 0 -and $store.alphapicks_price_cache) {
                    try {
                        $cached = $store.alphapicks_price_cache
                        if ($cached.$sym) { $shares = [double]$cached.$sym.shares }
                    } catch {}
                }
                if ($shares -eq 0) { continue }
                # FMP quota/outage fallback: degrade to avg cost rather than dropping the ticker
                $p         = if ($prices.ContainsKey($sym)) { $prices[$sym] } else { $null }
                $curPrice  = if ($p) { $p.price } else { $avgPrice }
                $prevPrice = if ($p) { $p.prev  } else { $avgPrice }
                $apValue     += $shares * $curPrice
                $apPrevValue += $shares * $prevPrice
                $apInvestedLive += $shares * $avgPrice
                $apTickers   += $sym
                $apSymbols[$sym] = [Math]::Round($curPrice, 4)
            }

            # Compute Brokerage and IRA tab values + per-ticker symbols
            # KNOWN LIMITATION: the two HGI private-fund positions (no exchange symbol, so
            # $pos.symbol is null) get skipped by "if (-not $sym) { continue }" below and are
            # NOT included in iraInvested/iraValue -- confirmed 2026-07-30, understates IRA by
            # ~$229k. Valuing them correctly requires the same equity/interest NAV computation
            # the desktop app's HGI IRR path does (see AlphaPicks Portfolio.html's "IRR HGI"
            # code), which isn't worth replicating here for a fallback path that's only ever
            # used when no browser was open at all -- the browser's own next capture overwrites
            # this entry with the real figure. Do not mistake a run of this path for ground truth
            # on IRA's total.
            $brokerValue = 0.0; $brokerPrev = 0.0; $brokerInvested = 0.0
            $iraValue    = 0.0; $iraPrev    = 0.0; $iraInvested    = 0.0
            $brokTickers = @(); $brokSymbols = @{}
            $iraTickers  = @(); $iraSymbols  = @{}

            foreach ($pos in $schwabPos) {
                $sym = $pos.symbol
                if (-not $sym) { continue }
                $isIra    = $iraAccountNums -contains $pos.accountNumber
                # Alpha Picks and QG&I symbols belong to their own tabs, not Brokerage
                if (-not $isIra -and (($ALPHA_PICKS_SYMS -contains $sym) -or ($QGI_SYMS -contains $sym))) { continue }
                $p        = if ($prices.ContainsKey($sym)) { $prices[$sym] } else { $null }
                $shares   = [double]$pos.shares
                $avgPrice = [double]$pos.avgPrice
                $curVal   = if ($p) { $shares * $p.price } else { $shares * $avgPrice }
                $prevVal  = if ($p) { $shares * $p.prev  } else { $curVal }
                $invested = $shares * $avgPrice
                $closePrice = if ($p) { [Math]::Round($p.price, 4) } else { [Math]::Round($avgPrice, 4) }

                if ($isIra) {
                    $iraValue    += $curVal;  $iraPrev    += $prevVal;  $iraInvested += $invested
                    if (-not $iraTickers.Contains($sym)) { $iraTickers += $sym; $iraSymbols[$sym] = $closePrice }
                } else {
                    $brokerValue += $curVal;  $brokerPrev += $prevVal;  $brokerInvested += $invested
                    if (-not $brokTickers.Contains($sym)) { $brokTickers += $sym; $brokSymbols[$sym] = $closePrice }
                }
            }

            # Alpha Picks invested: prefer the live figure computed above from real Schwab
            # avgPrice x shares (same method used for Brokerage/IRA) -- the browser-written
            # tabStatsSnap cache is only a fallback for when Schwab auth/positions aren't
            # available at all (e.g. token expired during an unattended run), since relying
            # on it as the primary source left this at 0 whenever the cache was stale/missing,
            # which is what silently zeroed out Total Invested for the unattended 4:05pm capture.
            $apInvested = 0.0
            if ($apHasLiveCost) {
                $apInvested = $apInvestedLive
            } else {
                try {
                    if ($store.alphapicks_price_cache -and $store.alphapicks_price_cache.tabStatsSnap) {
                        $snap = $store.alphapicks_price_cache.tabStatsSnap
                        if ($snap.alphapicks -and $snap.alphapicks.invested) {
                            $apInvested = [double]$snap.alphapicks.invested
                        }
                    }
                } catch {}
            }

            # USD/ILS -- $store.usdils is never populated by anything (only the browser's own
            # captureLogEntry() reads it, straight off the page's .usdils-box DOM element, and
            # that never gets written back to store.json). Confirmed 2026-08-13: every unattended
            # run has therefore always logged a blank usdils. Fetch the live rate directly instead
            # -- same Yahoo v8 1m-chart source the desktop dashboard itself uses for forex.
            $usdils = $null
            try {
                $yurl = 'https://query1.finance.yahoo.com/v8/finance/chart/USDILS=X?interval=1m&range=1d'
                $yr   = Invoke-WebRequest -Uri $yurl -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop -Headers @{ 'User-Agent' = 'Mozilla/5.0' }
                $fxMeta = ($yr.Content | ConvertFrom-Json).chart.result[0].meta
                if ($fxMeta -and $fxMeta.regularMarketPrice) { $usdils = [double]$fxMeta.regularMarketPrice }
            } catch { Write-Host "[Auto-log] USDILS fetch failed: $_" -ForegroundColor DarkGray }

            # IRR + SPY benchmark rates — from mobile_data.json (see comment above; $store never
            # has these keys).
            $apIrr     = $null; $apSpyIrr  = $null; $apSpySim  = $null
            $brkIrr    = $null; $brkSpyIrr = $null; $brkSpySim = $null
            $iraIrr    = $null; $iraSpyIrr = $null; $iraSpySim = $null
            $qgiIrr    = $null; $qgiSpyIrr = $null; $qgiSpySim = $null
            if ($mobileData) {
                try {
                    if ($mobileData.alphaPicksIrrRate    -ne $null) { $apIrr    = [double]$mobileData.alphaPicksIrrRate    * 100 }
                    if ($mobileData.alphaPicksSpyIrrRate -ne $null) { $apSpyIrr = [double]$mobileData.alphaPicksSpyIrrRate * 100 }
                    if ($mobileData.alphaPicksSpySimpleRet -ne $null) { $apSpySim = [double]$mobileData.alphaPicksSpySimpleRet * 100 }
                    if ($mobileData.brokerageIrrRate     -ne $null) { $brkIrr   = [double]$mobileData.brokerageIrrRate     * 100 }
                    if ($mobileData.brokerageSpyIrrRate  -ne $null) { $brkSpyIrr= [double]$mobileData.brokerageSpyIrrRate  * 100 }
                    if ($mobileData.brokerageSpySimpleRet -ne $null) { $brkSpySim= [double]$mobileData.brokerageSpySimpleRet * 100 }
                    if ($mobileData.iraIrrRate           -ne $null) { $iraIrr   = [double]$mobileData.iraIrrRate           * 100 }
                    if ($mobileData.iraSpyIrrRate        -ne $null) { $iraSpyIrr= [double]$mobileData.iraSpyIrrRate        * 100 }
                    if ($mobileData.iraSpySimpleRet      -ne $null) { $iraSpySim= [double]$mobileData.iraSpySimpleRet      * 100 }
                    if ($mobileData.qgiIrrRate           -ne $null) { $qgiIrr   = [double]$mobileData.qgiIrrRate           * 100 }
                    if ($mobileData.qgiSpyIrrRate        -ne $null) { $qgiSpyIrr= [double]$mobileData.qgiSpyIrrRate        * 100 }
                    if ($mobileData.qgiSpySimpleRet      -ne $null) { $qgiSpySim= [double]$mobileData.qgiSpySimpleRet      * 100 }
                } catch {}
            }

            # QG&I positions — aggregated directly from the browser's already-split snapshot
            # (see comment above for why this doesn't get recomputed from raw Schwab positions).
            $qgiValue = 0.0; $qgiInvested = 0.0; $qgiDailyChange = 0.0
            $qgiTickers = @(); $qgiSymbols = @{}
            if ($mobileData -and $mobileData.qgiPositions) {
                foreach ($pos in $mobileData.qgiPositions) {
                    if (-not $pos.ticker) { continue }
                    $mktVal = [double]$pos.mktVal
                    $cost   = [double]$pos.cost
                    $qgiValue    += $mktVal
                    $qgiInvested += $cost
                    if ($pos.dayPct -ne $null) {
                        $prevVal = $mktVal / (1 + [double]$pos.dayPct / 100)
                        $qgiDailyChange += ($mktVal - $prevVal)
                    }
                    if (-not $qgiTickers.Contains($pos.ticker)) {
                        $qgiTickers += $pos.ticker
                        $qgiSymbols[$pos.ticker] = [Math]::Round([double]$pos.currentPrice, 4)
                    }
                }
            }

            # Build log entry using browser-compatible field names.
            # Date must be the ET trading day this data is the close for, not whatever UTC
            # calendar day happens to be "now" -- this endpoint only fires at exactly 4:05pm ET
            # on a trading day (see $autoLogJob), so ET "now" IS that trading day's close.
            $now   = [DateTimeOffset]::UtcNow
            $etNow = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId($now.UtcDateTime, 'Eastern Standard Time')
            $dateKey = $etNow.ToString('yyyy-MM-dd')
            $apTotalChg = [Math]::Round($apValue - $apInvested, 2)
            $brokTotalChg = [Math]::Round($brokerValue - $brokerInvested, 2)
            $iraTotalChg  = [Math]::Round($iraValue - $iraInvested, 2)
            $entry = @{
                ts         = $now.ToUnixTimeMilliseconds()
                date       = $dateKey
                _key       = $dateKey
                usdils     = $usdils
                alphapicks = @{
                    totalInvested = [Math]::Round($apInvested, 2)
                    currentValue  = [Math]::Round($apValue, 2)
                    dailyChange   = [Math]::Round($apValue - $apPrevValue, 2)
                    totalChange   = $apTotalChg
                    pctChange     = if ($apInvested -gt 0) { [Math]::Round($apTotalChg / $apInvested * 100, 4) } else { 0 }
                    spyPct        = $apSpySim
                    annualReturn  = $apIrr
                    spyReturn     = $apSpyIrr
                    _tickers      = $apTickers
                    _symbols      = $apSymbols
                }
                brokerage  = @{
                    totalInvested = [Math]::Round($brokerInvested, 2)
                    currentValue  = [Math]::Round($brokerValue, 2)
                    dailyChange   = [Math]::Round($brokerValue - $brokerPrev, 2)
                    totalChange   = $brokTotalChg
                    pctChange     = if ($brokerInvested -gt 0) { [Math]::Round($brokTotalChg / $brokerInvested * 100, 4) } else { 0 }
                    spyPct        = $brkSpySim
                    annualReturn  = $brkIrr
                    spyReturn     = $brkSpyIrr
                    _tickers      = $brokTickers
                    _symbols      = $brokSymbols
                }
                ira        = @{
                    totalInvested = [Math]::Round($iraInvested, 2)
                    currentValue  = [Math]::Round($iraValue, 2)
                    dailyChange   = [Math]::Round($iraValue - $iraPrev, 2)
                    totalChange   = $iraTotalChg
                    pctChange     = if ($iraInvested -gt 0) { [Math]::Round($iraTotalChg / $iraInvested * 100, 4) } else { 0 }
                    spyPct        = $iraSpySim
                    annualReturn  = $iraIrr
                    spyReturn     = $iraSpyIrr
                    _tickers      = $iraTickers
                    _symbols      = $iraSymbols
                }
            }
            # QG&I is only added when the browser's snapshot actually had positions -- an empty
            # zeroed-out block would look like a real (if bad) data point instead of what it is:
            # no snapshot available, same as this whole fallback silently omitting it before.
            if ($qgiTickers.Count -gt 0) {
                $qgiTotalChg = [Math]::Round($qgiValue - $qgiInvested, 2)
                $entry.qgi = @{
                    totalInvested = [Math]::Round($qgiInvested, 2)
                    currentValue  = [Math]::Round($qgiValue, 2)
                    dailyChange   = [Math]::Round($qgiDailyChange, 2)
                    totalChange   = $qgiTotalChg
                    pctChange     = if ($qgiInvested -gt 0) { [Math]::Round($qgiTotalChg / $qgiInvested * 100, 4) } else { 0 }
                    spyPct        = $qgiSpySim
                    annualReturn  = $qgiIrr
                    spyReturn     = $qgiSpyIrr
                    _tickers      = $qgiTickers
                    _symbols      = $qgiSymbols
                }
            }

            # Append to log in store
            $log = Get-LogArray $store.alphapicks_log
            # Remove any existing entry for this trading day, matched by _key (ISO, what the
            # browser's captureLogEntry sets) OR by .date -- browser entries use dd-MMM-yyyy for
            # .date while this entry uses ISO, so comparing only .date (as before) let both
            # coexist as separate rows instead of the later one replacing the earlier one.
            $log = @($log | Where-Object { $_._key -ne $dateKey -and $_.date -ne $dateKey })
            $log += $entry

            # Save store
            if (-not ($store | Get-Member -Name alphapicks_log -ErrorAction SilentlyContinue)) {
                $store | Add-Member -NotePropertyName alphapicks_log -NotePropertyValue $log -Force
            } else {
                $store.alphapicks_log = $log
            }
            $store | ConvertTo-Json -Depth 10 -Compress | Set-Content $storeFile -Encoding UTF8

            Write-Host "[Auto-log] Done. AP=$([Math]::Round($apValue,0)) BRK=$([Math]::Round($brokerValue,0)) IRA=$([Math]::Round($iraValue,0))" -ForegroundColor Green
            Write-AutoLogEvent "OK -- wrote $($entry.date): AP=$([Math]::Round($apValue,0)) BRK=$([Math]::Round($brokerValue,0)) IRA=$([Math]::Round($iraValue,0)) priced=$pricedCount/$($allFmpSyms.Count)"

            # Write XLSX
            Write-LogExcel -Log $log -Path $LOG_XLSX_PATH

            Send-Json $res @{ ok = $true; date = $entry.date; alphapicks = $entry.alphapicks; brokerage = $entry.brokerage; ira = $entry.ira }
        } catch {
            Write-Host "[Auto-log] ERROR: $_" -ForegroundColor Red
            Write-AutoLogEvent "ERROR -- $_"
            Send-Json $res @{ ok = $false; error = "$_" } 500
        }
        continue
    }

    # ── /dashboard ────────────────────────────────────────────────────────────
    if ($path -eq '/dashboard' -or $path -eq '/') {
        Send-Html $res $dashFile
        continue
    }

    # ── /mobile ───────────────────────────────────────────────────────────────
    if ($path -eq '/mobile') {
        Send-Html $res $mobileFile
        continue
    }

    # ── /log-xlsx (GET) — download the server-generated Excel log ────────────
    if ($path -eq '/log-xlsx') {
        if (Test-Path $LOG_XLSX_PATH) {
            $bytes = [System.IO.File]::ReadAllBytes($LOG_XLSX_PATH)
            $res.ContentType = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
            $res.Headers.Add('Content-Disposition', "attachment; filename=`"!Alpha Picks Portfolio Log.xlsx`"")
            Send-Cors $res
            $res.ContentLength64 = $bytes.Length
            $res.OutputStream.Write($bytes, 0, $bytes.Length)
            $res.Close()
        } else {
            Send-Text $res 'Log file not found — trigger /auto-log first.' 404
        }
        continue
    }

    # ── 404 ───────────────────────────────────────────────────────────────────
    Send-Text $res "Not found: $path" 404
}

$listener.Stop()
if ($autoLogJob)   { Stop-Job $autoLogJob;   Remove-Job $autoLogJob }
if ($keepAliveJob) { Stop-Job $keepAliveJob; Remove-Job $keepAliveJob }
Write-Host "[Server] Stopped." -ForegroundColor Yellow
