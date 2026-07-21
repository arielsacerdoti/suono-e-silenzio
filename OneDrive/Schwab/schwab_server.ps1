# AlphaPicks Schwab Server
# Serves: /proxy (Yahoo CORS), /auth, /callback, /schwab/status, /schwab/api, /dashboard, /mobile, /store, /auto-log
# Run via "! Open AlphaPicks Portfolio.bat" (as Admin for all-interface binding)

$port       = 7843
$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$configFile = Join-Path $scriptDir 'schwab_config.json'
$tokenFile  = Join-Path $scriptDir 'schwab_tokens.json'
$dashFile   = Join-Path $scriptDir 'AlphaPicks Portfolio.html'
$mobileFile = Join-Path $scriptDir 'AlphaPicks Mobile.html'

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
$ALPHA_PICKS_SYMS = @('TTMI','MU','INCY','PARR','W','TIGO','B','NEM','DY','GM','FN','LITE')
$MARKET_HOLIDAYS  = @(
    '2026-01-01','2026-01-19','2026-02-16','2026-04-03',
    '2026-05-25','2026-07-03','2026-09-07','2026-11-26','2026-12-25',
    '2027-01-01','2027-01-18','2027-02-15','2027-04-02',
    '2027-05-31','2027-07-05','2027-09-06','2027-11-25','2027-12-24'
)
$LOG_XLSX_PATH = Join-Path $scriptDir 'AlphaPicks_Log.xlsx'

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

function Send-Html($res, $file) {
    if (-not (Test-Path $file)) { Send-Text $res 'Not found' 404; return }
    $bytes = [IO.File]::ReadAllBytes($file)
    $res.StatusCode  = 200
    $res.ContentType = 'text/html; charset=utf-8'
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
    $res.Close()
}

function Send-Cors($res) {
    $res.Headers.Add('Access-Control-Allow-Origin',  '*')
    $res.Headers.Add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
    $res.Headers.Add('Access-Control-Allow-Headers', 'Content-Type, Authorization')
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
            @{ id = 'alphapicks'; sheet = 'Alpha Picks'; extraKey = 'usdils' }
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

        $pkg = $null
        foreach ($tab in $tabDefs) {
            $tabId = $tab.id

            # Collect unique tickers (newest-first so most recent ticker set leads)
            $seen = @{}; $allTickers = @()
            foreach ($e in $sortedLog) {
                $sec = $e.$tabId
                if (-not $sec) { continue }
                $tickers = if ($sec._tickers) { $sec._tickers } else { @() }
                foreach ($t in $tickers) {
                    if (-not $seen.ContainsKey($t)) { $allTickers += $t; $seen[$t] = 1 }
                }
            }

            $rows = foreach ($e in $sortedLog) {
                $sec = $e.$tabId
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
    $listener.Prefixes.Add("http://*:${port}/")
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
    param($port, [string[]]$holidays)
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
                Invoke-WebRequest -Uri "http://localhost:$port/auto-log" -Method POST `
                    -UseBasicParsing -TimeoutSec 120 -ErrorAction SilentlyContinue | Out-Null
                Write-Output "Auto-log fired for $dk"
            }
        } catch {}
    }
} -ArgumentList $port, $MARKET_HOLIDAYS

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
            # Load store for sold/sales/alerts
            $store = @{}
            if (Test-Path $storeFile) { try { $store = Get-Content $storeFile -Raw | ConvertFrom-Json } catch {} }

            # Get Schwab positions
            $tok = Get-ValidToken
            $allSwPos = @()
            $iraTypes = @('IRA','ROTH_IRA','SEP_IRA','SIMPLE_IRA')
            if ($tok) {
                try {
                    $r = Invoke-WebRequest -Uri "${API_BASE}/trader/v1/accounts?fields=positions" `
                        -Headers @{ Authorization = "Bearer $($tok.access_token)"; Accept = 'application/json' } `
                        -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
                    $accounts = $r.Content | ConvertFrom-Json
                    foreach ($acct in $accounts) {
                        $aType = $acct.securitiesAccount.type
                        $pList = $acct.securitiesAccount.positions
                        if ($pList) {
                            foreach ($p in $pList) {
                                $allSwPos += [PSCustomObject]@{
                                    symbol   = $p.instrument.symbol
                                    shares   = [double]$p.longQuantity
                                    avgPrice = [double]$p.averageLongPrice
                                    acctType = $aType
                                }
                            }
                        }
                    }
                } catch { Write-Host "[Mobile] Schwab error: $_" -ForegroundColor Yellow }
            }

            # Collect all unique symbols for FMP
            $allSyms = ($ALPHA_PICKS_SYMS + ($allSwPos | ForEach-Object { $_.symbol })) | Sort-Object -Unique

            # Fetch FMP prices in parallel
            $fmpSB = [scriptblock]::Create(@'
param($s, $k)
# Jobs run in a separate runspace — ensure TLS 1.2 so HTTPS to FMP/Yahoo works.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# Primary: FMP, retried up to 3x. A burst of ~20 parallel jobs can trip FMP's 429 rate
# limit; a jittered backoff + retry lets a throttled request succeed on a later attempt
# instead of returning no price (which would zero the position's market value downstream).
for ($i = 0; $i -lt 3; $i++) {
    try {
        $url = "https://financialmodelingprep.com/stable/quote?symbol=$s&apikey=$k"
        $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
        $d = $r.Content | ConvertFrom-Json
        if ($d -and $d.Count -gt 0 -and $d[0].price) {
            return @{ price = [double]$d[0].price; prev = [double]$d[0].previousClose; name = [string]$d[0].name }
        }
    } catch {
        Start-Sleep -Milliseconds (400 + (Get-Random -Maximum 800))
    }
}

# Fallback: Yahoo v8 chart (server-side fetch, no CORS; more tolerant than v7, which 401s).
try {
    $yurl = "https://query1.finance.yahoo.com/v8/finance/chart/$($s)?interval=1d&range=1d"
    $yr = Invoke-WebRequest -Uri $yurl -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop -Headers @{ 'User-Agent' = 'Mozilla/5.0' }
    $yd = $yr.Content | ConvertFrom-Json
    $meta = $yd.chart.result[0].meta
    if ($meta -and $meta.regularMarketPrice) {
        return @{ price = [double]$meta.regularMarketPrice; prev = [double]$meta.chartPreviousClose; name = [string]$s }
    }
} catch {}

return $null
'@)
            $fmpJobs2 = @{}
            foreach ($sym in $allSyms) {
                $fmpJobs2[$sym] = Start-Job -ScriptBlock $fmpSB -ArgumentList $sym, $FMP_KEY_SERVER
            }
            $px = @{}
            foreach ($sym in $allSyms) {
                $j = $fmpJobs2[$sym]; Wait-Job $j -Timeout 30 | Out-Null
                $r2 = Receive-Job $j; Remove-Job $j -Force
                if ($r2) { $px[$sym] = $r2 }
            }

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
                $sw = $allSwPos | Where-Object { $_.symbol -eq $sym -and $iraTypes -notcontains $_.acctType } | Select-Object -First 1
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
            foreach ($sw in ($allSwPos | Where-Object { $iraTypes -notcontains $_.acctType })) {
                $sym = $sw.symbol
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
            $ira = @()
            foreach ($sw in ($allSwPos | Where-Object { $iraTypes -contains $_.acctType })) {
                $sym = $sw.symbol
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
            $bodyBytes = New-Object byte[] $req.ContentLength64
            [void]$req.InputStream.Read($bodyBytes, 0, $bodyBytes.Length)
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
                $bodyBytes = New-Object byte[] $req.ContentLength64
                [void]$req.InputStream.Read($bodyBytes, 0, $bodyBytes.Length)
                $bodyStr = [System.Text.Encoding]::UTF8.GetString($bodyBytes)
                $incoming = $bodyStr | ConvertFrom-Json
                # Key-value pair update: merge single key into existing store
                if ($incoming.PSObject.Properties['key'] -and $incoming.PSObject.Properties.Name.Count -le 3) {
                    # -AsHashtable does not exist on Windows PowerShell 5.1's ConvertFrom-Json (PS6+ only) —
                    # it was silently throwing here, swallowed by the catch below, so $store2 was ALWAYS
                    # empty and every single-key write was overwriting the entire store with just that key.
                    $store2 = @{}
                    if (Test-Path $storeFile) {
                        try {
                            $existing = Get-Content $storeFile -Raw | ConvertFrom-Json
                            foreach ($prop in $existing.PSObject.Properties) { $store2[$prop.Name] = $prop.Value }
                        } catch {}
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

    # ── /auto-log (POST — called by background job at 4:05 PM ET, or by browser Export Log) ────
    if ($path -eq '/auto-log' -and $meth -eq 'POST') {
        Write-Host "[Auto-log] Starting daily log capture..." -ForegroundColor Cyan
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
                    $bodyBytes = New-Object byte[] $bodyLen
                    [void]$ctx.Request.InputStream.Read($bodyBytes, 0, $bodyLen)
                    $bodyStr = [System.Text.Encoding]::UTF8.GetString($bodyBytes)
                    if ($bodyStr.Trim().StartsWith('{')) {
                        $browserPayload = $bodyStr | ConvertFrom-Json
                    }
                }
            } catch {}

            if ($browserPayload -and $browserPayload.entry) {
                Write-Host "[Auto-log] Using browser-provided entry (fast path)" -ForegroundColor Cyan
                $log = @()
                if ($browserPayload.fullLog) {
                    try { $log = @($browserPayload.fullLog) } catch {}
                } elseif ($store.alphapicks_log) {
                    try { $log = @($store.alphapicks_log) } catch {}
                }
                $entry = $browserPayload.entry
                $dateVal = if ($entry.date) { $entry.date } else { $entry._key }
                $log = @($log | Where-Object { $_.date -ne $dateVal -and $_._key -ne $dateVal })
                $log = @($entry) + $log
                if (-not ($store | Get-Member -Name alphapicks_log -ErrorAction SilentlyContinue)) {
                    $store | Add-Member -NotePropertyName alphapicks_log -NotePropertyValue $log -Force
                } else { $store.alphapicks_log = $log }
                $store | ConvertTo-Json -Depth 10 -Compress | Set-Content $storeFile -Encoding UTF8
                Write-LogExcel -Log $log -Path $LOG_XLSX_PATH
                Send-Json $res @{ ok = $true; date = $dateVal; source = 'browser' }
                continue
            }

            # Get Schwab positions first so we know all symbols to fetch
            $tok = Get-ValidToken
            $schwabPos = @()
            if ($tok) {
                try {
                    $r = Invoke-WebRequest -Uri "${API_BASE}/trader/v1/accounts?fields=positions" `
                        -Headers @{ Authorization = "Bearer $($tok.access_token)"; Accept = 'application/json' } `
                        -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
                    $accounts = $r.Content | ConvertFrom-Json
                    foreach ($acct in $accounts) {
                        $type = $acct.securitiesAccount.type
                        $positions = $acct.securitiesAccount.positions
                        if ($positions) {
                            foreach ($pos in $positions) {
                                $schwabPos += @{
                                    symbol   = $pos.instrument.symbol
                                    shares   = [double]$pos.longQuantity
                                    avgPrice = [double]$pos.averageLongPrice
                                    type     = $type
                                }
                            }
                        }
                    }
                } catch {
                    Write-Host "[Auto-log] Schwab API error: $_" -ForegroundColor Yellow
                }
            }

            # Fetch FMP prices for all symbols (sequential direct calls — no Start-Job overhead)
            $allFmpSyms = ($ALPHA_PICKS_SYMS + ($schwabPos | ForEach-Object { $_.symbol } | Where-Object { $_ })) |
                          Sort-Object -Unique
            $prices = @{}
            foreach ($sym in $allFmpSyms) {
                try {
                    $url  = "https://financialmodelingprep.com/stable/quote?symbol=$sym&apikey=$FMP_KEY_SERVER"
                    $data = Invoke-RestMethod -Uri $url -TimeoutSec 10 -ErrorAction Stop
                    if ($data -and $data.Count -gt 0) {
                        $prices[$sym] = @{ price = [double]$data[0].price; prev = [double]$data[0].previousClose }
                    }
                } catch {
                    Write-Host "[Auto-log] FMP miss: $sym" -ForegroundColor DarkGray
                }
            }

            $iraTypes = @('IRA','ROTH_IRA','SEP_IRA','SIMPLE_IRA')

            # Compute Alpha Picks tab value + per-ticker symbols
            $apValue = 0.0; $apPrevValue = 0.0
            $apTickers = @(); $apSymbols = @{}
            foreach ($sym in $ALPHA_PICKS_SYMS) {
                if (-not $prices.ContainsKey($sym)) { continue }
                $match = $schwabPos | Where-Object { $_.symbol -eq $sym } | Select-Object -First 1
                $shares = 0.0
                if ($match) { $shares = [double]$match.shares }
                if ($shares -eq 0 -and $store.alphapicks_price_cache) {
                    try {
                        $cached = $store.alphapicks_price_cache
                        if ($cached.$sym) { $shares = [double]$cached.$sym.shares }
                    } catch {}
                }
                $apValue     += $shares * $prices[$sym].price
                $apPrevValue += $shares * $prices[$sym].prev
                $apTickers   += $sym
                $apSymbols[$sym] = [Math]::Round($prices[$sym].price, 4)
            }

            # Compute Brokerage and IRA tab values + per-ticker symbols
            $brokerValue = 0.0; $brokerPrev = 0.0; $brokerInvested = 0.0
            $iraValue    = 0.0; $iraPrev    = 0.0; $iraInvested    = 0.0
            $brokTickers = @(); $brokSymbols = @{}
            $iraTickers  = @(); $iraSymbols  = @{}

            foreach ($pos in $schwabPos) {
                $sym = $pos.symbol
                if (-not $sym) { continue }
                $isIra    = $iraTypes -contains $pos.type
                # Alpha Picks symbols belong to the Alpha Picks tab only, not Brokerage
                if (-not $isIra -and ($ALPHA_PICKS_SYMS -contains $sym)) { continue }
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

            # Get Alpha Picks invested from store cache
            $apInvested = 0.0
            try {
                if ($store.alphapicks_price_cache -and $store.alphapicks_price_cache.tabStatsSnap) {
                    $snap = $store.alphapicks_price_cache.tabStatsSnap
                    if ($snap.alphapicks -and $snap.alphapicks.invested) {
                        $apInvested = [double]$snap.alphapicks.invested
                    }
                }
            } catch {}

            # USD/ILS from store cache
            $usdils = $null
            try { if ($store.usdils) { $usdils = [double]$store.usdils } } catch {}

            # IRR + SPY benchmark rates — saved to store by browser via syncToCloud
            $apIrr     = $null; $apSpyIrr  = $null; $apSpySim  = $null
            $brkIrr    = $null; $brkSpyIrr = $null; $brkSpySim = $null
            $iraIrr    = $null; $iraSpyIrr = $null; $iraSpySim = $null
            try {
                if ($store.alphaPicksIrrRate    -ne $null) { $apIrr    = [double]$store.alphaPicksIrrRate    * 100 }
                if ($store.alphaPicksSpyIrrRate -ne $null) { $apSpyIrr = [double]$store.alphaPicksSpyIrrRate * 100 }
                if ($store.alphaPicksSpySimpleRet -ne $null) { $apSpySim = [double]$store.alphaPicksSpySimpleRet * 100 }
                if ($store.brokerageIrrRate     -ne $null) { $brkIrr   = [double]$store.brokerageIrrRate     * 100 }
                if ($store.brokerageSpyIrrRate  -ne $null) { $brkSpyIrr= [double]$store.brokerageSpyIrrRate  * 100 }
                if ($store.brokerageSpySimpleRet -ne $null) { $brkSpySim= [double]$store.brokerageSpySimpleRet * 100 }
                if ($store.iraIrrRate           -ne $null) { $iraIrr   = [double]$store.iraIrrRate           * 100 }
                if ($store.iraSpyIrrRate        -ne $null) { $iraSpyIrr= [double]$store.iraSpyIrrRate        * 100 }
                if ($store.iraSpySimpleRet      -ne $null) { $iraSpySim= [double]$store.iraSpySimpleRet      * 100 }
            } catch {}

            # Build log entry using browser-compatible field names
            $now   = [DateTimeOffset]::UtcNow
            $apTotalChg = [Math]::Round($apValue - $apInvested, 2)
            $brokTotalChg = [Math]::Round($brokerValue - $brokerInvested, 2)
            $iraTotalChg  = [Math]::Round($iraValue - $iraInvested, 2)
            $entry = @{
                ts         = $now.ToUnixTimeMilliseconds()
                date       = $now.ToString('yyyy-MM-dd')
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

            # Append to log in store
            $log = @()
            if ($store.alphapicks_log) {
                try { $log = @($store.alphapicks_log) } catch {}
            }
            # Remove existing entry for today to avoid duplicates
            $log = @($log | Where-Object { $_.date -ne $entry.date })
            $log += $entry

            # Save store
            if (-not ($store | Get-Member -Name alphapicks_log -ErrorAction SilentlyContinue)) {
                $store | Add-Member -NotePropertyName alphapicks_log -NotePropertyValue $log -Force
            } else {
                $store.alphapicks_log = $log
            }
            $store | ConvertTo-Json -Depth 10 -Compress | Set-Content $storeFile -Encoding UTF8

            Write-Host "[Auto-log] Done. AP=$([Math]::Round($apValue,0)) BRK=$([Math]::Round($brokerValue,0)) IRA=$([Math]::Round($iraValue,0))" -ForegroundColor Green

            # Write XLSX
            Write-LogExcel -Log $log -Path $LOG_XLSX_PATH

            Send-Json $res @{ ok = $true; date = $entry.date; alphapicks = $entry.alphapicks; brokerage = $entry.brokerage; ira = $entry.ira }
        } catch {
            Write-Host "[Auto-log] ERROR: $_" -ForegroundColor Red
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
            $res.Headers.Add('Content-Disposition', "attachment; filename=`"AlphaPicks_Log.xlsx`"")
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
