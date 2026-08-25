# AlphaPicks Calculation Reference

**Purpose:** every displayed number on this dashboard has a formula and a data-source chain behind it. Most of the bugs found in this app (2026-08) were not wrong math — they were the RIGHT math fed a STALE or WRONG-SESSION input from one link in that chain. This doc exists so that the next time something "looks wrong," you check the chain here before reporting it as a bug — and so that when it IS a bug, whoever fixes it (human or Claude) starts from the real formula instead of reverse-engineering it from scratch again.

**How to use it:** each entry has an ID (e.g. `STAT-3`). Reference that ID in conversation — "STAT-3 looks off for QG&I" — instead of re-describing the whole metric. IDs are stable: new entries get appended to their section, existing IDs never get renumbered.

**Click the 📖 Reference button in the dashboard header to view this rendered.** Raw source lives at `CALC_REFERENCE.md` in the repo root.

---

## Index

- **SESS** — session / market-state detection (foundational, everything below depends on this)
- **STAT** — per-tab stat bar (Total Invested, Current Value, Daily Change, Annual Return, etc.)
- **ROW** — position table row columns (Current Price, Cash Invested, G/L, True IRR, etc.)
- **QGI** — QG&I-specific mechanics (closed-position pooling, VYM benchmark, shared-ticker splitting)
- **LOG** — daily log capture and Excel export (both the server-side `.xlsx` writer and the client-side one)
- **MOB** — mobile app data sync
- **ALLOC** — Allocation tab

---

## SESS — Session / Market State

### SESS-1 — Market Session (PRE / REGULAR / POST / CLOSED)

**What it drives:** almost everything below. Which price field to trust, which reference ("yesterday's close") to compare against, and whether a PRE/AH badge should render at all.

**Formula:** bucket the current ET wall-clock time:
- Saturday/Sunday → `CLOSED`
- 2:00 AM – 9:30 AM ET → `PRE`
- 9:30 AM – 4:00 PM ET → `REGULAR`
- 4:00 PM – 8:00 PM ET → `POST`
- anything else → `CLOSED`

**Source:** `getSessionFromClock()` — pure `Date` math on the browser's own clock, converted to `America/New_York`. **Never** the `marketState` field from Yahoo/FMP/Schwab API responses.

**Gotcha:** CORS proxies and cached quotes routinely return stale `marketState`. This clock function is the single source of truth for session across the whole app — if you're debugging a session-related bug, first confirm what `getSessionFromClock()` returns right now, don't trust what any quote object claims. Also: US market holidays are **not** accounted for here — a holiday reads as a normal trading day session-wise (holiday-awareness is handled separately, only in the log-capture path — see `LOG-1`).

---

## STAT — Per-Tab Stat Bar

Applies to the header stats shown on Brokerage / Retirement / Alpha Picks / QG&I (each tab has its own `tabStats[tabId]` object; the stat bar just renders whichever tab is active).

### STAT-1 — Total Invested

**Formula:** sum of every currently-held position's *economic* cost basis — **Net Invested = grossBuys − sellProceeds** (DRIP-reinvestment cost excluded) — **not** Schwab's raw `avgCost × shares`. For Alpha Picks/QG&I only, also includes a credit/debit from any fully-closed tagged position (see `QGI-1`).

**Sources:**
- Brokerage/IRA: `refreshSectionStats()` — sums `row.dataset.econCostBasis ?? row.dataset.costBasis` across all rendered rows, plus `closedPosInvested.brokerage`/`.ira` (currently always 0 — see `QGI-1` for why this was deliberately NOT extended to Brokerage/IRA).
- Alpha Picks/QG&I: `renderGroupFromSchwab()`'s `totCost` (Schwab avg-cost × shares) OR the post-`loadIRRData()` lightweight resum, which reads `row.dataset.cost` — the economic figure `loadIRRData()` already corrected per row — plus `closedPosInvested[group]`.

**Known gotcha (fixed 2026-08-25, commit `2c26278`):** before this fix, the live stat card only ever summed currently-held rows and never picked up `loadIRRData()`'s per-row corrections or a fully-closed position's credit — it silently drifted from the printed ledger's total (confirmed: QG&I showed $118,964.89 live vs. $118,586.39 correct, a $378 gap).

### STAT-2 — Current Value

**Formula:** sum of `shares × currentPrice` across currently-held positions. Closed positions contribute exactly `$0` (nothing left to hold).

**Source:** same per-tab render/refresh functions as `STAT-1` (`refreshSectionStats()` for Brokerage/IRA; `renderGroupFromSchwab()`/`refreshGroupPrices()` for Alpha Picks/QG&I). Price itself is `ROW-1`.

### STAT-3 — Daily Change ($ and %)

**Formula:** sum of each position's `(currentPrice − dayReferencePrice) × shares`, where `dayReferencePrice` is resolved per `ROW-1`'s reference chain — **not** simply "yesterday's close" naively, see that entry for why.

**Source:** accumulated inside the same row loop as `ROW-1`/`ROW-3` (`fetchPrices()` for Alpha Picks legacy path, `refreshGroupPrices()` for the group engine, `refreshBrokeragePrices()` for Brokerage/IRA), written into `tabStats[tabId].dailyGL`.

**Gotcha:** this is the single most fragile number in the app — see the entire `ROW-1` entry. If Daily Change looks implausible, check `ROW-1` first.

### STAT-4 — Total Change / % Change

**Formula:** `Total Change = Current Value − Total Invested` (i.e. `STAT-2 − STAT-1`). `% Change = Total Change / Total Invested × 100`.

**Source:** `renderTabStats()`, computed directly from `tabStats[tabId].totalGL` and `.invested` — no independent data source, purely derived from `STAT-1`/`STAT-2`.

### STAT-5 — Annual Return (True IRR)

**Formula:** a single pooled XIRR across **every** cash flow (buys negative, sells/dividends positive) from **every** position ever held in the tab — including fully-closed ones — with ONE combined terminal flow (today's `STAT-2`) appended. This is a money-weighted return of the whole tab as a sleeve, not an average of individual positions' IRRs.

**Source:** `computeTabIRRStats()` — pools `irrAuditData` entries' `.cashFlows` per section, sorts chronologically, runs `calcXIRR()`. Populated by `loadIRRData()` (manually triggered, not automatic on every price tick).

**Gotcha (fixed 2026-08-25, commits `325cc14`/`e057d70`):** `loadIRRData()` used to only process currently-*rendered* rows, so a position that got fully sold vanished from this pool entirely — not just its sale, its whole buy history too — understating "capital already at work." See `QGI-1` for the fix (virtual closed-position rows) and the G/L-sign bug that surfaced once closed positions were included.

### STAT-6 — S&P 500 Equivalent (benchmark)

**Formula:** simulates buying/selling SPY at each ACTUAL portfolio transaction's date/amount (opening price on that date), reinvesting SPY's own dividends, then values the resulting hypothetical SPY position today. Two numbers are shown: **Simple Return** = `(spyTerminalValue + sellProceeds − grossBuys) / grossBuys`, and **Annual Return** = XIRR of the same simulated SPY cash flows.

**Source:** `computeTabIRRStats()`, using `fetchSPYHistory()` for SPY's own opens/closes/dividends, matched against the SAME pooled cash flows as `STAT-5`. Cached in `spyAuditData[tabId]` (viewable via the "S&P Audit" button).

**Gotcha:** the denominator is deliberately the sum of flows that actually found a matching SPY price (a 7-day lookback in `nearestSPYPrice()`) — using the unfiltered total against a numerator that never saw that money was a real bug (understated returns, e.g. showed −30% during a period SPY was up) fixed prior to 2026-08-25.

### STAT-7 — VYM Equivalent (QG&I only)

**Formula/Source:** identical methodology to `STAT-6`, substituting VYM (Vanguard High Dividend Yield ETF) as the benchmark instead of SPY — QG&I is an income-focused sleeve, so VYM is the more relevant comparison. Cached in `benchAuditData.qgi`.

---

## ROW — Position Table Row Columns

### ROW-1 — Current Price + PRE/AH Badge + Daily %

**This is the fragile one. Read this entry fully before assuming a PRE/AH % is a genuine market move.**

**Price formula:** `q.isPre && preMarketPrice != null → preMarketPrice`, else `postMarketPrice != null → postMarketPrice`, else `regularMarketPrice`.

**% formula (as of commit `b4485e3`, 2026-08-25):**
```
ref = q._freshRef                                              // 1st choice: this fetch cycle's own
                                                                 //   candle-scanned / chartPreviousClose
                                                                 //   reference (see fetchExtendedHours())
    ?? closeMap[ticker]                                         // 2nd choice: alphapicks_close_map cache
                                                                 //   (populated after every non-PRE fetch)
    ?? (postMarketPrice != null                                 // 3rd choice, POST only
          ? (regularMarketPreviousClose ?? regularMarketPrice)
          : regularMarketPrice)

dayPct = isExt && ref ? (price − ref) / ref × 100 : regularMarketChangePercent
```
`isExt` = "any non-REGULAR session" (broader than "do we have a confirmed real tick" — this distinction was itself the last bug fixed, see below).

**Sources, in the order the app actually tries them:**
1. **Schwab** (`fetchSchwabQuotesBatched` → `normaliseSchwabQuote`) — primary. Its own `preMarketPrice`/`postMarketPrice` come from Schwab's `extended` quote block, populated only if `extended.tradeTime > 0` (i.e. Schwab actually has an extended-hours print). Its `regularMarketPreviousClose` is *derived*: `price − regular.regularMarketNetChange` — **this derivation itself is a session-behind trap, see gotcha below.**
2. **Yahoo v8 chart** (`fetchTickerChart`, `interval=1d&range=1d`) — per-symbol fallback for anything Schwab missed. Its `regularMarketPreviousClose` comes from `meta.chartPreviousClose ?? meta.previousClose` — reliable **at this specific range parameter** (see gotcha).
3. **FMP** — REGULAR hours only, quota-limited (250 calls/day).
4. **Yahoo v8 chart, extended** (`fetchExtendedHours`, `interval=1m&range=5d&includePrePost=true`) — the ONLY source that supplies a genuine intraday PRE/AH tick. Also computes its own careful reference (`_freshRef`): candle-scans yesterday's actual regular-session close window during PRE (2:00–4:30 PM ET the prior day), or uses `meta.chartPreviousClose` directly during POST (documented as correct for that case specifically).

**Known gotchas, most-recent first (all confirmed 2026-08-25):**

- **No real extended-hours tick at all** (fixed commit `b4485e3`): if NEITHER Schwab NOR Yahoo has a genuine PRE/AH print for a ticker, `price` falls back to `regularMarketPrice`, but the % used to fall all the way through to `regularMarketChangePercent` — the raw provider's own **regular-session** % change, which is exactly as session-behind as the next bullet. Confirmed on SPB: showed "+1.65%" (yesterday's *already-completed* gain) despite ten-plus hours of completely flat, untraded candles. Fixed by gating the reference-chain on `isExt` (any extended session) instead of `isExtHours` (a confirmed real tick) — a no-tick ticker now runs through the same reference chain and correctly lands at/near 0%.

- **`regularMarketPreviousClose` can point two sessions back, not one** (fixed commit `40276c4`): both Schwab's `price − netChange` derivation and Yahoo's `chartPreviousClose` field (at the wide `range=5d` parameter `fetchExtendedHours` uses) can resolve to the close from **before** yesterday's, not yesterday's own close — because `regularMarketLastPrice`/`netChange` reflect the last **completed** regular session, and during PRE that "last completed session" is still yesterday's, so subtracting its own net change reaches back one session too far. Confirmed on SPB: resolved to $86.91 (real two-sessions-back close) instead of $88.34 (real prior close), making a stale, already-realized gain look like a live pre-market move.

- **A persisted cache can simply go stale** (fixed commit `d2345e7`): `alphapicks_close_map` exists specifically to avoid the above by capturing a clean `regularMarketPrice` after every non-PRE fetch — but `refreshGroupPrices()` (the shared Alpha Picks/QG&I engine) used to only ever **read** this cache, never write it. A ticker that briefly sat in Brokerage right after purchase (before being tagged into a group) got a one-time snapshot that then froze indefinitely. Confirmed on LMT: cached close frozen at $598.01 from ~2 weeks earlier while the real prior close was $563.57, showing a fabricated "-6.10%" loss neither Yahoo nor Google Finance agreed with.

- **Thin pre-market liquidity is real, not a bug:** even after all the above is fixed, a large-cap's price can legitimately swing several dollars between consecutive 1-minute candles in the first hour of PRE (confirmed on LMT: $561.31 → $564.88 → $565.18 within 10 minutes, single-digit share sizes per print). If the *reference* math checks out but the *price itself* looks like an outlier, it's probably just a real, thin trade — check the next fetch cycle before assuming a bug.

**Diagnostic recipe:** if a PRE/AH % looks implausible for a name you'd expect to move less, compute `(displayedPrice − impliedRef) / impliedRef` by hand and see which of the sources above it matches — that tells you which link in the chain is stale, without needing to re-read the code.

### ROW-2 — Cash Invested / Net Invested (row level)

**Formula:** `grossBuys − sellProceeds`, DRIP-reinvestment cost excluded. Deliberately **not** Schwab's `avgCost × remainingShares` — that silently drops the realized gain/loss on any partial sell.

**Sign convention:** can legitimately go **negative** for a position sold for more than it cost (net cash already returned, with profit). This is correct, not a bug — see `QGI-1`'s "Net Invested sign" note for how this is displayed.

**Fallback:** if a position has genuinely zero trade history (`grossBuys === 0`, brand new), falls back to Schwab's raw cost basis + the stored buy date, synthesizing one buy flow. This fallback is gated on **still holding shares** — a fully-closed position's `netInvested` (even negative) is trusted directly, never overridden by this fallback (fixed 2026-08-25, commit `e057d70` — see `QGI-1`).

**Source:** `loadIRRData()`'s per-row loop, reconciling `schwab_tx_journal` (ongoing delta-detection) + `schwab_csv_txns` (one-time historical bootstrap).

### ROW-3 — Gain/Loss ($ and %)

**Formula:** `G/L $ = currentValue − Net Invested (ROW-2)`. `G/L % = G/L $ / max(grossBuys, Net Invested) × 100` — the denominator floors at `grossBuys` (total capital ever deployed), not the shrinking remaining balance, specifically so a mostly-sold position doesn't show an absurd inflated percentage (a real incident: a position showed +1268% on a real $968 gain before this floor was added).

**Source:** `loadIRRData()`, written to `row.dataset.econGrossBuys`/`.econCostBasis`, rendered via `glCellHTML()`.

### ROW-4 — DRIP Value

**Formula:** `dripUnits × currentPricePerShare` — the current market value of shares acquired via dividend reinvestment specifically (not the cash cost of those shares, which is `dripCost`, excluded from `ROW-2`/`ROW-3`).

**Source:** `dripUnits` accumulated from `Reinvest Shares` journal/CSV entries. For a fixed set of known income tickers (ARCC, BSM, DIVO, QQQI, JAAA, JEPQ, JEPI, QYLD, XYLD, RYLD, NEOS, CGDV) with zero recorded DRIP units but live shares, a separate reconstruction (`reconstructDistributions()`) fills in a display-only estimate when the authoritative CSV was lost — this reconstruction never touches `ROW-2`/`ROW-3`/IRR, display only.

### ROW-5 — True IRR (row level)

**Formula:** XIRR of that single position's own buy/sell/dividend cash flows plus its current value as the terminal flow.

**Source:** same `loadIRRData()` per-row loop as `ROW-2`, via `calcXIRR()`.

### ROW-6 — Simple Return (ETF rows only)

**Formula:** `(currentValue − Net Invested) / Net Invested × 100` — only computed when `Net Invested > 0` (i.e. **not** shown for a fully-closed position with negative Net Invested; that case shows `—`, see `QGI-1`).

**Source:** `loadIRRData()`, alongside `ROW-2`/`ROW-3`/`ROW-5`.

---

## QGI — QG&I-Specific Mechanics

QG&I and Alpha Picks share the same rendering/calc engine (`GROUPS` config, `renderGroupFromSchwab()`, `refreshGroupPrices()`), parametrized by group. These entries cover behavior specific to that shared "tagged group" architecture, most visible on QG&I because it has by far the most tagging/rotation activity.

### QGI-1 — Closed (fully-sold) tagged positions still count toward the tab

**Formula:** any symbol still in `qgi_tagged`/`alphapicks_tagged` with real `schwab_tx_journal`/`schwab_csv_txns` history but **no current Schwab position** gets a virtual row injected (terminal value `$0`) into `loadIRRData()`'s processing, so its real buy/sell dates and amounts feed `STAT-1` and `STAT-5`'s pooled calculations exactly like a live position would.

**Why this matters:** without it, swapping one pick for another (e.g. selling RBCAA/R/COP to fund LMT/SPB/PSTL) made the new capital look like a fresh injection with zero track record — the sold positions' entire history, not just the sale, silently vanished from the tab's IRR and Net Invested the moment they closed.

**Net Invested sign for a closed position:** since `mktVal = 0`, `Net Invested (ROW-2)` for a closed position IS its total realized gain/loss with the sign flipped — sold at a profit → negative Net Invested → the ledger correctly shows it as a **credit** (reducing the tab's committed capital), displayed with an explicit `-` prefix rather than the usual sign-stripped dollar format (fixed commit `6114255` — a negative Net Invested rendered as a bare positive number used to read as ADDED capital instead of a deduction).

**Scope — deliberately NOT extended to Brokerage/IRA:** tried this (2026-08-13) and reverted it. Alpha Picks/QG&I have a bounded, curated tag list where "closed" cleanly means "swapped for a replacement pick." Brokerage/IRA have no such boundary, so the same logic pulled in the account's entire multi-year trade history — and worse, CUSIP-format bond/T-bill symbols collided with the pre-existing HGI-private-fund heuristic (any non-ticker-shaped symbol ≥5 chars routes into the HGI special path), injecting the real HGI fund's cash flows once per phantom bond row and inflating Brokerage's figure by over $1.5M. `closedPosInvested.brokerage`/`.ira` are permanently `0` in the shared wiring as a result.

**Sources:** the injection lives in `loadIRRData()` (rows array construction); the credit propagates through `STAT-1`/`STAT-5` via the module-level `closedPosInvested` object.

### QGI-2 — Ledger Cash-Flow sign (Buy vs. Sell)

**Formula:** the printed ledger colors/signs each row by `action` (`Buy`/`Reinvest Shares` → red outflow, else → green inflow) — **not** by the raw stored `amount`'s sign.

**Gotcha (fixed commit `cee8f76`):** the delta-detection journal (`detectPositionDeltas()`, the primary transaction source once a position is past its CSV bootstrap) stores **both** Buy and Sell `amount` as positive numbers — only `action` carries the real direction. CSV-bootstrap-sourced entries happen to store `amount` already negative for buys, so the same ledger table could show two different sign conventions side by side depending on which source produced the row, before this was normalized.

### QGI-3 — Shared-ticker splitting (e.g. "B" held in both Alpha Picks and QG&I)

**Formula:** `sliceForGroup(symbol, group, totalShares, totalCost)` — if a symbol is tagged into more than one group, the position's shares/cost are split via `group_alloc` (localStorage), which stores each group's explicit share/cost slice once the overlap was created. The group *without* an explicit slice owns "the remainder after the other groups' slices," so shares/cost are never double-counted across tabs.

**Source:** `group_alloc` localStorage key; consumed by `renderGroupFromSchwab()` and, for cash-flow attribution specifically, `attributeGroupTxns()` inside `loadIRRData()`.

---

## LOG — Daily Log Capture & Excel Export

This app maintains a running daily snapshot (`alphapicks_log`, one entry per trading day per tab) that gets exported to `!Alpha Picks Portfolio Log.xlsx`. There are **two independent code paths that write this Excel file** — a client-side one (browser, SheetJS) and a server-side one (PowerShell, ImportExcel) — and historically the most damaging bugs in this app have been in this subsystem specifically, because a fix made in the browser's `localStorage` copy doesn't automatically reach `store.json` (the server's copy, which is what the server-side exporter reads).

### LOG-1 — Daily entry capture (the "real" numbers)

**Formula:** for each tab, `totalInvested`/`currentValue` straight from that tab's live `tabStats`; `dailyChange` = `tabStats[tabId].dailyGL` (the exact live stat-bar figure, i.e. `STAT-3`); `spyPct`/`annualReturn`/`spyReturn` from `tabStats[tabId].spySimpleRet`/`.irrRate`/`.spyIrrRate` (i.e. `STAT-5`/`STAT-6`).

**Source:** `captureLogEntry()` — fires automatically once per trading day at/after 4:00 PM ET (`checkDailyLog()`), gated on a fresh price fetch having already completed that day. Always uses **today's** ET date; has no "backfill a specific past day" mode.

**Gotcha:** this is the ONLY path that captures genuinely live, accurate numbers (real intraday `dailyGL`, real IRR). Every other path below is a degraded reconstruction used only when this one didn't fire.

### LOG-2 — Unattended `/auto-log` fallback (server-side, browser wasn't open)

**Formula:** re-derives Total Invested/Current Value/Daily Change from a **fresh live Schwab+Yahoo/FMP fetch**, run entirely in PowerShell (no browser needed). `spyPct`/`annualReturn`/`spyReturn` are read from `mobile_data.json` (the browser's last pushed snapshot) — **not** recomputed, since replicating the full XIRR engine in PowerShell isn't attempted. `usdils` is fetched live from Yahoo's `USDILS=X` chart.

**Source:** `schwab_server.ps1`'s `/auto-log` POST handler, fired by a background timer job at exactly 4:05 PM ET on trading days.

**Gotchas (all fixed 2026-08-13 → 2026-08-25):**
- Used to read `$store.alphaPicksIrrRate` etc., which is never actually written by the browser (those fields go to the separate `mobile_data.json` file) — every unattended run therefore logged `null` reference rates forever, not just once (fixed commit `44982c7`).
- The `/mobile-data` endpoint's own live-compute fallback (fired by a phone check when its 10-min cache goes stale) used to overwrite `mobile_data.json` wholesale, wiping the very fields the fix above depends on — confirmed: a mid-afternoon phone check silently undid the morning's browser-sourced IRR data hours before the day's `/auto-log` run (fixed commit `858f779`).
- The unattended timer fires unconditionally at a fixed time regardless of whether the browser already captured a real `LOG-1` entry minutes earlier — it used to blindly overwrite that better entry with its own degraded one. Now checks for an existing same-day entry and skips if found (fixed commit `afbf0ae`).
- `usdils` source was `$store.usdils`, a key nothing has ever written — every unattended entry logged a blank rate regardless of the above fixes, until switched to a live fetch (fixed commit `afbf0ae`).

### LOG-3 — Historical backfill (`backfillHistoricalLog`, `backfillLogEntry`)

**Formula:** reconstructs `totalInvested`/`currentValue` from historical Yahoo daily closes (one 5-year fetch per ticker, then walks every trading day filling gaps) using **current** share counts reconstructed backward via `sharesAtDateGlobal()` against `schwab_tx_journal`. `dailyChange` = `thisDay'sValue − previousLoggedValue`, computed correctly during the backfill walk itself. `spyPct`/`annualReturn`/`spyReturn` are deliberately left blank (`''`) — a trustworthy historical IRR would require re-running the full XIRR engine per historical day, not attempted.

**Source:** `backfillHistoricalLog()` (multi-day gap-filler, manually triggered) and `backfillLogEntry()` (single-day version, auto-triggered by `checkMissingLogEntry()` for up to 30 days back on page load if a recent trading day has no real entry).

**Gotcha (fixed commit `d5e2f9d`):** `backfillGroupHistory()` (the QG&I/Alpha-Picks-group-aware variant of this) used to save the merged log in **ascending** date order while every other write path uses descending (newest-first) — this alone didn't corrupt data, but broke code that assumed `log[0]` is always the most recent entry.

### LOG-4 — Daily Change repair pass (`migrateLogDailyChanges`)

**Formula:** for any log entry with a genuinely blank `dailyChange` (checked explicitly — never overwrites a real captured value), fills it in as `thisDay'sCurrentValue − previousDay'sCurrentValue`, walking the log oldest-to-newest. This is what actually repairs the gap `LOG-3`'s backfill paths leave (they either skip `dailyChange` entirely, in the QG&I case, or leave it blank intentionally elsewhere).

**Source:** `migrateLogDailyChanges()`, called on every page load (after awaiting `window._storeReady`).

**Gotcha (fixed commit `c6052cd`, the most subtle bug found in this whole subsystem):** used to be gated by a one-shot version flag (`alphapicks_log_dc_migrated === '5'`) — once it ran ONE time, even if its output later got reverted by something else (an export pushing a stale browser copy back up, `loadStore()` overwriting local data from the server), the guard permanently blocked it from ever running again. **Worse**, the call site ran synchronously, not awaiting `window._storeReady` — since `loadStore()` unconditionally overwrites `alphapicks_log` from the server on every page load, running this migration *before* that fetch resolved meant it "fixed" a stale pre-load snapshot and then got silently clobbered by the server's still-broken copy moments later, on **every single load**, including a hard refresh explicitly meant to prove the fix worked. Now guard-free (runs every load, but only ever fills genuine gaps, so a clean log costs nothing) and correctly ordered after `_storeReady`.

### LOG-5 — Excel export, server-side (`Write-LogExcel`)

**Formula:** reads `store.alphapicks_log` (the server's copy), one worksheet per tab (Brokerage / Retirement / Alpha Picks / QG&I), columns: `Date, Total Invested, Current Value, Daily Change, Total Change, % Change, S&P500 %, Annual Return, S&P500 Return, [USD/ILS — Alpha Picks only], <per-ticker close prices...>`. Falls back to the pre-nested flat entry format (`e.totalInvested` etc. directly on the entry, no `e.alphapicks` sub-object) for ~157 historical days that predate the per-tab nested format.

**Source:** `schwab_server.ps1`'s `Write-LogExcel` function (PowerShell + ImportExcel module), called from both `/auto-log` code paths (`LOG-1`'s browser-push fast path and `LOG-2`'s unattended fallback) — this is the file you actually see on disk at `!Alpha Picks Portfolio Log.xlsx`.

**Gotcha:** this function trusts whatever `alphapicks_log` array it's handed completely — it does no independent recalculation. If a number is wrong in the Excel file, the bug is upstream (in whichever of `LOG-1`–`LOG-4` produced that log entry), never in this function itself.

### LOG-6 — Excel export, client-side (`buildLogWorkbook`, `exportLog`)

**Formula/columns:** identical shape to `LOG-5`, built via SheetJS (`XLSX.utils.aoa_to_sheet`) directly in the browser from `localStorage.alphapicks_log`. Same fallback for legacy flat-format entries.

**Source:** `buildLogWorkbook()`, called by `exportLog()` (the "Export Log" button — captures today's entry first if past 4 PM and not yet captured, then builds and saves the workbook, either via a remembered File System Access handle or a save-as dialog) and `autoSaveLog()` (silent background auto-save using the remembered handle).

**Gotcha:** `exportLog()` ALSO calls `pushLogToServer()`, which POSTs the browser's **entire** `alphapicks_log` array to `/auto-log` and **replaces** `store.alphapicks_log` wholesale. If the browser's local copy is stale relative to a server-side fix (e.g. one applied by hand via a diagnostic script, or reverted by another device), clicking Export Log **undoes that fix** — this exact sequence (server fixed → browser exports stale local copy → server reverted) has happened. Always hard-refresh (which pulls the server's current copy down via `loadStore()`) *before* clicking Export Log if a server-side correction was just applied.

### LOG-7 — usdils (per-entry USD/ILS rate)

**Formula:** read directly off the page's `.usdils-box` DOM element at capture time (`LOG-1`) — this is the SAME rate shown in the header chip, itself fetched via the forex-specific Yahoo path (skips FMP entirely, uses `USDILS=X` 1-minute chart, `meta.chartPreviousClose` as reference).

**Source:** `captureLogEntry()` for real captures; a live standalone fetch for `LOG-2`'s unattended path (fixed commit `afbf0ae` — previously always null, see `LOG-2`).

---

## MOB — Mobile App Data Sync

*(Full detail lives in `alphapicks-mobile`'s own repo — this is a brief pointer since the desktop app is this data's origin.)*

### MOB-1 — `mobile_data.json` / GitHub Gist push

**Formula:** `syncToCloud()` serializes live positions + `STAT-1`/`STAT-5`/`STAT-6` figures for all 4 tabs (plus QG&I's already-split positions, since mobile has no equivalent of `QGI-3`'s splitting logic) into one JSON payload, POSTed to the local server's `/save-mobile-data` (always) and, throttled to once per 5 minutes (or forced), PATCHed to a GitHub Gist for access when mobile can't reach the desktop server directly (`HOME_MODE = false`).

**Gotcha (fixed commit `1681d3e`):** the Gist push requires `GIST_TOKEN`, loaded from `schwab_secrets.js` via a `<script>` tag — the server had no route to actually serve that file (404 on every real launch), so `GIST_TOKEN` silently stayed empty and the Gist push was a **permanent no-op** for at least 4+ days before this was caught. Local `mobile_data.json` stayed fresh throughout (separate write path, doesn't need the token) — which is exactly why this was invisible: check the Gist's own raw URL timestamp against local `mobile_data.json`'s timestamp if mobile ever looks stale away from home; if local is fresh but the Gist isn't, suspect `GIST_TOKEN` first.

---

## ALLOC — Allocation Tab

### ALLOC-1 — Pooled totals across tabs

**Formula:** `invested`/`value`/`totalGL` = straight sum of `STAT-1`/`STAT-2`/derived-G-L across all 4 ready tabs, plus manual assets (`loadManualAssets()`, net to $0 gain since purchase price is unknown). `irrRate` = weighted average of each ready tab's `STAT-5`, weighted by that tab's current value. SPY/VYM benchmarks are **not** re-derived from the weighted average — they're computed once from the full pooled cash-flow set across all tabs (own dedicated pass in `computeTabIRRStats()`), then just carried forward.

**Source:** `updateAllocTabStats()`, called after every tab's own stat refresh.
