#!/bin/sh
# TRMNL calendar screen for Kindle, run as a KUAL extension.
#
# The battery plan: suspend the device to RAM between refreshes and wake on an RTC
# alarm. E-ink holds the last image with no power, so the agenda stays visible while
# the device sleeps. That is what buys months-class battery instead of days.
#
# The suspend cycle is UNPROVEN on this device. The 2026-08-02 probe confirmed the
# wakealarm interface exists and is writable from this script's context; it did not
# prove suspend enters, the alarm fires, resume is clean, or Wi-Fi comes back. So:
#
#   1. "suspendtest" is the one-shot diagnostic: arm +120s, suspend once, report a
#      PASS/FAIL card on the panel and a verdict line in calendar.log.
#   2. The refresh loop only attempts suspend when the file suspend.enabled exists
#      next to this log. Nothing creates that file automatically - not even a
#      passing suspendtest. It is placed by hand, over USB, after the diagnostic
#      verdict has been read. Without it the loop refreshes fully awake.
#
# Fail-safe rules the loop obeys, in order of importance:
#   - Never suspend without reading the armed alarm back from the RTC.
#   - A failed cycle (Wi-Fi did not come back, or the fetch failed) NEVER stops the
#     loop and NEVER restores the framework. It first hard-cycles the radio and
#     retries; if still down it keeps the last good image and suspends the interval
#     anyway, then retries on the next wake. Handing the device back to powerd on an
#     error is what sleeps it with no alarm and freezes the watchdog (the 2026-08-09
#     dark-screen outage). Suspending through an outage keeps months-class battery.
#   - Three consecutive suspend failures (the RTC refuses the sleep, a separate
#     hardware fault): keep refreshing but stay awake this run (battery becomes
#     days-class; the display keeps working). This is the only awake-fallback left.
#   - stop.flag next to the log ends the loop at the next wake. It can be created
#     over plain USB mass storage, so there is always a way in without a shell.
#
# Every wake logs battery percentage, so an overnight run yields drain-per-wake.
#
# The TRMNL_* environment overrides exist for the host-side test harness; they are
# never set on the device, so every default below is the real device value -
# except SERVER, which is a placeholder in this public repo on purpose. The
# real address is never committed here; it lives only in the private server's
# served copy of this file.
#
# Usage: calendar.sh once | suspendtest [seconds] | start | stop | probe | ruler

SERVER="${TRMNL_SERVER:-http://CHANGE_ME_SERVER_HOST:8484}"
DEVICE="kindle-01"
BASE="${TRMNL_BASE:-/mnt/us/calendar}"
OUT="$BASE/screen.png"
TMP="$BASE/screen.png.part"
LOG="$BASE/calendar.log"
PIDFILE="$BASE/loop.pid"
STATEFILE="$BASE/takeover.active"
STOPFLAG="$BASE/stop.flag"
SUSPEND_ENABLED="$BASE/suspend.enabled"
STAY_AWAKE_FILE="$BASE/stay_awake_until"   # absolute epoch; command channel's stay-awake
LAST_COMMAND_FILE="$BASE/last_command_id"  # id of the last command actually acted on
PENDING_ACK_FILE="$BASE/pending_ack"       # id owed an ack on the next successful push_log
PREV_SCRIPT_FILE="$BASE/calendar.sh.prev"      # last-known-good, saved before every swap
UPDATE_PROBATION_FILE="$BASE/update_probation" # absolute deadline epoch; presence = "on probation"
UPDATE_OK_FILE="$BASE/update_ok"               # presence = a post-update cycle actually completed
RESTART_REASON_FILE="$BASE/restart_reason"     # why the PREVIOUS process ended, written by
                                                # whichever code path is about to kill/replace it
LOG_BASE_LINES_FILE="$BASE/calendar.log.baselines" # cumulative lines rotated away BEFORE the
                                                    # current live calendar.log (2026-08-26)
LOG_UPLOADED_FILE="$BASE/calendar.log.uploaded"    # highest cumulative log line confirmed
                                                    # delivered to the server with no gap before it
FBINK="${TRMNL_FBINK:-/mnt/us/libkh/bin/fbink}"

INTERVAL="${TRMNL_INTERVAL:-900}"    # fallback seconds between refreshes; the live
                                     # value comes from the server's refresh_rate
                                     # field on /api/display when it is sane
MIN_INTERVAL="${TRMNL_MIN_INTERVAL:-300}"    # served values outside these bounds are
MAX_INTERVAL="${TRMNL_MAX_INTERVAL:-21600}"  # ignored and INTERVAL is used instead
FULL_REFRESH_EVERY=4                 # flash the panel every Nth draw to clear ghosting
FIRST_DRAW_DELAY="${TRMNL_FIRST_DRAW_DELAY:-3}"  # let KUAL finish repainting first
WIFI_MAX_WAIT="${TRMNL_WIFI_MAX_WAIT:-60}"       # seconds to wait for Wi-Fi after resume
WIFI_PROBE_WAIT="${TRMNL_WIFI_PROBE_WAIT:-10}"   # quick UNHELD first probe; a healthy
                                                 # cycle associates in a few s, so it
                                                 # passes here and never holds the radio
                                                 # awake (keeps normal suspends untouched)
WIFI_RESET_TRIES="${TRMNL_WIFI_RESET_TRIES:-3}"  # hard radio resets before a cycle is failed
FAIL_BACKOFF="${TRMNL_FAIL_BACKOFF:-60}"         # awake pause after a failed cycle
REDRAW_EVERY="${TRMNL_REDRAW_EVERY:-30}"         # re-blit cadence during awake sleeps
HEARTBEAT_EVERY="${TRMNL_HEARTBEAT_EVERY:-30}"  # log a liveness line this often while waiting
AWAKE_WALL_BUDGET_MULT="${TRMNL_AWAKE_WALL_BUDGET_MULT:-2}"    # awake_sleep bails out once REAL
AWAKE_WALL_BUDGET_GRACE="${TRMNL_AWAKE_WALL_BUDGET_GRACE:-120}" # elapsed time exceeds total*MULT+GRACE
SUSPEND_OVERSLEEP_MULT="${TRMNL_SUSPEND_OVERSLEEP_MULT:-2}"     # slept > iv*MULT flags a suspend as overslept
KILL_WINDOW="${TRMNL_KILL_WINDOW:-5}"            # pause before suspend so stop can win
MAX_FAILS=3
SUSPEND_RETRIES="${TRMNL_SUSPEND_RETRIES:-5}"   # transient display/wifi locks clear in seconds
SUSPEND_RETRY_WAIT="${TRMNL_SUSPEND_RETRY_WAIT:-4}"
PUSH_LOG_MAX_LINES="${TRMNL_PUSH_LOG_MAX_LINES:-200}"  # a push_log tail bigger than this is
                                                        # split into numbered POSTs (2026-08-26)
LOG_MAX_BYTES="${TRMNL_LOG_MAX_BYTES:-1000000}"  # calendar.log rotates past this (2026-08-26);
                                                  # ~1MB is weeks of normal cycle logging, so this
                                                  # only ever trims genuinely old history
WIFI_LADDER_RUNG1_FAILS="${TRMNL_WIFI_LADDER_RUNG1_FAILS:-2}"  # consecutive wifi-failed cycles
WIFI_LADDER_RUNG2_FAILS="${TRMNL_WIFI_LADDER_RUNG2_FAILS:-4}"  # before escalating to the next
WIFI_LADDER_RUNG3_FAILS="${TRMNL_WIFI_LADDER_RUNG3_FAILS:-6}"  # rung (2026-08-26 self-heal ladder)

RTC_ALARM="${TRMNL_RTC_ALARM:-/sys/class/rtc/rtc0/wakealarm}"
RTC_ALARM_BACKUP="${TRMNL_RTC_ALARM_BACKUP:-/sys/class/rtc/rtc1/wakealarm}"
POWER_STATE="${TRMNL_POWER_STATE:-/sys/power/state}"

# ---------------------------------------------------------------- watchdog
#
# 2026-08-06: the loop ran 88 clean cycles, then stopped between fetching
# /api/display (server saw the 200) and requesting the image. It logged NOTHING
# after that, not even one of the ERROR paths, so the script did not fail - the
# process stopped existing. With the loop gone, nothing held the device awake,
# powerd suspended it, and because the loop dies BEFORE it arms the next alarm
# the device slept with no wake alarm at all. It stayed dark for four hours until
# Jonathan held the power button.
#
# Two independent guards, because either one alone leaves a hole:
#   1. SAFETY ALARM, armed at the TOP of every cycle for interval+grace. If the
#      process dies mid-cycle the device still has a pending wake, so it comes
#      back instead of sleeping forever.
#   2. WATCHDOG PROCESS, separate from the loop, checking a heartbeat file. The
#      safety alarm wakes the hardware, but a dead loop cannot restart itself,
#      so something outside it has to. It is deliberately tiny: sleep, read a
#      number, compare, restart. Nothing it does can block.
#
# The watchdog is frozen along with everything else during suspend-to-RAM and
# resumes with the device, so it measures wall-clock age from the heartbeat file
# rather than counting its own iterations. That means STALE must comfortably
# exceed one whole sleep: a normal heartbeat is ~interval seconds old at wake.
HBFILE="$BASE/heartbeat"
WDPIDFILE="$BASE/watchdog.pid"
WDLOG="$BASE/watchdog.log"
WD_POLL="${TRMNL_WD_POLL:-120}"          # how often the watchdog looks
WD_STALE="${TRMNL_WD_STALE:-2400}"       # 40 min: > one 900s sleep plus slack
SAFETY_GRACE="${TRMNL_SAFETY_GRACE:-600}"  # safety alarm = interval + this

# Host to ping when checking Wi-Fi is back, derived from SERVER unless overridden.
# Empty means "skip the check".
if [ -n "${TRMNL_WIFI_TEST_IP+set}" ]; then
    WIFI_TEST_IP="$TRMNL_WIFI_TEST_IP"
else
    WIFI_TEST_IP=$(echo "$SERVER" | sed -e 's|^[a-z]*://||' -e 's|[:/].*$||')
fi

mkdir -p "$BASE"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

# The watchdog keeps its own file so a wedged/huge calendar.log can never stop it
# writing, but it ALSO writes into the main log, because push_log only ships the
# main log and a watchdog that restarts things invisibly is worse than no
# watchdog. Every decision it makes ends up on the server.
wdlog() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') WD $*" >> "$WDLOG"
    echo "$(date '+%Y-%m-%d %H:%M:%S') WATCHDOG $*" >> "$LOG"
}

# Liveness marker. Written as a bare epoch so the watchdog's check is a single
# integer compare with nothing to parse and nothing to go wrong.
heartbeat() {
    date +%s > "$HBFILE" 2>/dev/null
}

# ---------------------------------------------------------------- log retention
#
# calendar.log itself has never been truncated by this script - log() only ever
# appends. What actually loses evidence (2026-08-26: a cycle-counter reset from
# n=95 to n=2 destroyed the ability to re-pull an earlier window) is that a big
# pull only ever asks for the last N lines: once enough new cycles accumulate
# after an interesting window, that window ages out of any tail request nobody
# has made yet. These functions close that gap: a size cap so calendar.log can
# never fill the Kindle's flash, and a durable cursor so a startup backlog
# upload (see upload_backlog_if_any, called from main_loop) always ships
# whatever was written but never confirmed delivered before this process
# started - without anyone having to ask for it before it ages out.

# Cumulative count of every line ever written to calendar.log, unaffected by
# rotation truncating the live file: LOG_BASE_LINES_FILE holds whatever was
# rotated away before now, and this adds however many lines are in the current
# live file on top of that.
total_log_lines() {
    base=$(cat "$LOG_BASE_LINES_FILE" 2>/dev/null)
    case "$base" in ''|*[!0-9]*) base=0 ;; esac
    cur=$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')
    case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
    echo $(( base + cur ))
}

# Keeps calendar.log from growing without bound on the Kindle's limited flash.
# One rotation generation only (calendar.log -> calendar.log.1): this is a
# diagnostic log that needs recent history, not an archive. Called once per
# main_loop iteration, not per log() line, so normal logging never pays for it.
rotate_log_if_needed() {
    [ -f "$LOG" ] || return 0
    size=$(wc -c < "$LOG" 2>/dev/null | tr -d ' ')
    case "$size" in ''|*[!0-9]*) return 0 ;; esac
    [ "$size" -le "$LOG_MAX_BYTES" ] && return 0

    rotated_lines=$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')
    case "$rotated_lines" in ''|*[!0-9]*) rotated_lines=0 ;; esac
    base=$(cat "$LOG_BASE_LINES_FILE" 2>/dev/null)
    case "$base" in ''|*[!0-9]*) base=0 ;; esac
    echo $(( base + rotated_lines )) > "$LOG_BASE_LINES_FILE" 2>/dev/null

    mv "$LOG" "$LOG.1" 2>/dev/null
    log "calendar.log rotated at ${size} bytes (cap ${LOG_MAX_BYTES}); history before this point is in calendar.log.1"
}

# On startup, calendar.log may already hold lines that were written but never
# confirmed delivered - most often because the PREVIOUS process ended (crash,
# watchdog kill, update) before its next scheduled push_log call went out.
# Called once, from the first successful network cycle after this process
# started (see main_loop): ships that backlog automatically, tagged distinctly,
# instead of waiting for someone to notice and ask for a large pull before it
# ages out of range.
upload_backlog_if_any() {
    total=$(total_log_lines)
    uploaded=$(cat "$LOG_UPLOADED_FILE" 2>/dev/null)
    case "$uploaded" in ''|*[!0-9]*) uploaded=0 ;; esac
    gap=$(( total - uploaded ))
    [ "$gap" -le 0 ] && return 0

    # A gap this large usually means LOG_UPLOADED_FILE predates a rotation (the
    # lines it refers to no longer exist in the live file) rather than a real
    # backlog - cap to what the live file actually holds so this can never ask
    # push_log for more lines than calendar.log has.
    live=$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')
    case "$live" in ''|*[!0-9]*) live=0 ;; esac
    [ "$gap" -gt "$live" ] && gap="$live"
    [ "$gap" -le 0 ] && return 0

    # Logged AFTER push_log, deliberately: push_log's tail read happens first
    # thing inside that call, and a log() line written before it would itself
    # land inside the tail window and push the oldest wanted line back out -
    # exactly the off-by-one this feature exists to stop causing elsewhere.
    push_log "backlog-recovery" "$gap"
    log "startup backlog: $gap line(s) written before this process started were uploaded (tag backlog-recovery)"
}

# Ship the tail of the log to the server. This exists so that diagnosing this
# device NEVER requires another USB pass: every plug/unplug cycle costs Jonathan
# real time and broke his patience on 2026-08-04, fairly. Best effort only - it
# must never fail a cycle, never block, and never be the reason a refresh dies.
# Read it back on the server with:
#   docker logs trmnl-server 2>&1 | grep KINDLE_LOG
#
# Also carries the wifi update channel's check-in fields: version and script_md5
# go out on every call so the server can confirm an update actually applied, and
# ack_command_id (when ACK_ID is set by apply_pending_command) is how the device
# tells the server it received and acted on a command. All flat top-level keys,
# not nested, mirroring the cmd_* fields on /api/display - the device never needs
# a JSON library, only sed/awk key:value extraction, in either direction.
ACK_ID=""

# Post one already-built JSON payload to $SERVER/api/log. The payload travels via
# a temp file read with curl/wget's "read the body from a file" form, never as a
# single inline -d/--post-data shell argument. 2026-08-26: the 1000-line
# upload-full-log slice vanished between the device logging "starting the
# upload" and the server ever seeing a POST, with no error either side - a large
# inline argument is the one part of the old push_log that could fail silently
# like that. Sets push_rc; on failure also logs the exit status and payload size
# in bytes, so the NEXT silent-looking failure explains itself from calendar.log
# alone. $2 is only used in that failure log line, to name which part failed.
_push_log_post() {   # $1 = JSON payload string, $2 = label for the failure log line
    payload_file="$BASE/push_log.payload.$$"
    printf '%s' "$1" > "$payload_file"
    payload_bytes=$(wc -c < "$payload_file" 2>/dev/null | tr -d ' ')
    push_rc=1
    case "$HTTP" in
        curl) curl -s -m 15 -X POST -H "Content-Type: application/json" \
                   --data-binary "@$payload_file" "$SERVER/api/log" >/dev/null 2>&1
              push_rc=$? ;;
        wget) wget -q -T 15 -O /dev/null --header="Content-Type: application/json" \
                   --post-file="$payload_file" "$SERVER/api/log" >/dev/null 2>&1
              push_rc=$? ;;
    esac
    [ "$push_rc" -ne 0 ] && log "ERROR push_log[$2] POST failed rc=$push_rc bytes=${payload_bytes:-unknown}"
    # Per-call scratch file, not device state - no trash-put on this firmware, and
    # nothing here is worth a rename-don't-delete audit trail like stop.flag/pidfile.
    rm -f "$payload_file" 2>/dev/null
    return "$push_rc"
}

push_log() {   # $1 = short reason tag, $2 = how many trailing lines
    [ -n "$HTTP" ] || return 0
    tail_n="${2:-40}"
    lines_file="$BASE/push_log.lines.$$"
    tail -n "$tail_n" "$LOG" 2>/dev/null > "$lines_file"
    total_lines=$(wc -l < "$lines_file" 2>/dev/null | tr -d ' ')
    case "$total_lines" in ''|*[!0-9]*) total_lines=0 ;; esac

    # A tail within PUSH_LOG_MAX_LINES goes out as one POST, same as before. A
    # bigger one (the 1000-line upload-full-log diagnostic) is split into several
    # numbered parts, none of them big enough to risk the same silent failure -
    # the server (commands.receive_log_part) buffers and joins them back in order.
    if [ "$total_lines" -le "$PUSH_LOG_MAX_LINES" ]; then
        parts=1
    else
        parts=$(( (total_lines + PUSH_LOG_MAX_LINES - 1) / PUSH_LOG_MAX_LINES ))
    fi
    batch_id="$$-$(date +%s)"

    all_ok=1   # flips to 0 on any part's failure; the owed ack only clears when every part went out
    part=1
    start=1
    while [ "$part" -le "$parts" ]; do
        end=$(( start + PUSH_LOG_MAX_LINES - 1 ))
        [ "$end" -gt "$total_lines" ] && end="$total_lines"
        body=$(sed -n "${start},${end}p" "$lines_file" | tr -d '\\"' | tr '\t' ' ' | awk '{printf "%s | ", $0}')

        extra=""
        [ -n "$SCRIPT_VERSION" ] && extra="$extra,\"version\":\"$SCRIPT_VERSION\""
        [ -n "$SCRIPT_MD5" ] && extra="$extra,\"script_md5\":\"$SCRIPT_MD5\""
        [ -n "$ACK_ID" ] && extra="$extra,\"ack_command_id\":\"$ACK_ID\""
        [ "$parts" -gt 1 ] && extra="$extra,\"part_index\":$part,\"part_total\":$parts,\"batch_id\":\"$batch_id\""
        payload="{\"device\":\"$DEVICE\",\"tag\":\"KINDLE_LOG ${1:-tick}\",\"body\":\"$body\"$extra}"

        _push_log_post "$payload" "${1:-tick} $part/$parts" || all_ok=0

        part=$((part + 1))
        start=$((end + 1))
    done
    rm -f "$lines_file" 2>/dev/null

    # Only clear the owed ack once every part has actually gone out. A failed POST
    # leaves ACK_ID (and PENDING_ACK_FILE, which survives a restart) set so the
    # very next push_log call - or the next loop process, after a restart - tries
    # again.
    if [ "$all_ok" -eq 1 ] && [ -n "$ACK_ID" ]; then
        log "ack sent for command id=$ACK_ID"
        ACK_ID=""
        : > "$PENDING_ACK_FILE" 2>/dev/null
    fi

    # Advance the uploaded-cursor only when this push's range reaches back far
    # enough to close any existing gap with no hole left in the middle -
    # otherwise a routine short push (last 12-40 lines) would wrongly mark an
    # earlier, still-unsent stretch as delivered, and upload_backlog_if_any
    # would never catch it on the next restart.
    if [ "$all_ok" -eq 1 ]; then
        log_total_now=$(total_log_lines)
        already_uploaded=$(cat "$LOG_UPLOADED_FILE" 2>/dev/null)
        case "$already_uploaded" in ''|*[!0-9]*) already_uploaded=0 ;; esac
        covered_from=$(( log_total_now - total_lines ))
        [ "$covered_from" -le "$already_uploaded" ] && echo "$log_total_now" > "$LOG_UPLOADED_FILE" 2>/dev/null
    fi
    return 0
}

# ---------------------------------------------------------------- http client

if command -v curl >/dev/null 2>&1; then
    HTTP="curl"
elif command -v wget >/dev/null 2>&1; then
    HTTP="wget"
else
    HTTP=""
fi

http_file() {   # $1 = url, $2 = destination
    case "$HTTP" in
        curl) curl -s -m 60 -o "$2" "$1" ;;
        wget) wget -q -T 60 -O "$2" "$1" ;;
        *)    return 1 ;;
    esac
}

# ---------------------------------------------------------------- telemetry

# Signal strength in dBm, straight from the wireless driver. Only sent when it looks
# like a negative integer, because a malformed value would be rejected by the server.
rssi_value() {
    # Do NOT match on an interface name; this device does not use wlan0. Take the
    # first data line, whatever the interface is called: lines 1-2 are headers, and
    # column 4 is the signal level in dBm.
    r=$(awk 'NR > 2 && /:/ { v = $4; sub(/\.$/, "", v); print v; exit }' /proc/net/wireless 2>/dev/null)
    case "$r" in
        -[0-9]*) echo "$r"; return ;;
    esac

    if command -v iwconfig >/dev/null 2>&1; then
        r=$(iwconfig 2>/dev/null | sed -n 's/.*Signal level[=:]\{1\}\(-\{0,1\}[0-9]\{1,\}\).*/\1/p' | head -1)
        case "$r" in
            -[0-9]*) echo "$r"; return ;;
        esac
    fi

    echo ""
}

_valid_percent() {   # echoes $1 back when it is a plain 0-100 integer
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 0 ] 2>/dev/null && [ "$1" -le 100 ] 2>/dev/null || return 1
    echo "$1"
}

# Battery charge as a whole-number percentage, or empty if nothing can read it.
# Four sources because none is guaranteed on this firmware.
battery_percent() {
    if [ -n "$TRMNL_BATT_OVERRIDE" ]; then
        _valid_percent "$TRMNL_BATT_OVERRIDE" && return
    fi

    if command -v gasgauge-info >/dev/null 2>&1; then
        b=$(gasgauge-info -c 2>/dev/null | tr -cd '0-9')
        _valid_percent "$b" && return
    fi

    if command -v lipc-get-prop >/dev/null 2>&1; then
        b=$(lipc-get-prop com.lab126.powerd battLevel 2>/dev/null | tr -cd '0-9')
        _valid_percent "$b" && return
    fi

    for cap in /sys/class/power_supply/*/capacity; do
        [ -r "$cap" ] || continue
        b=$(cat "$cap" 2>/dev/null | tr -cd '0-9')
        _valid_percent "$b" && return
    done

    if command -v lipc-get-prop >/dev/null 2>&1; then
        b=$(lipc-get-prop com.lab126.powerd status 2>/dev/null \
            | grep -i "battery" | head -1 | tr -cd '0-9')
        _valid_percent "$b" && return
    fi

    echo ""
}

# ---------------------------------------------------------------- drawing

draw() {    # $1 = image path, $2 = "full" to flash the panel
    if [ -x "$FBINK" ]; then
        if [ "$2" = "full" ]; then
            "$FBINK" -c -f -g file="$1" >/dev/null 2>&1 && return 0
        else
            "$FBINK" -g file="$1" >/dev/null 2>&1 && return 0
        fi
    fi
    if command -v eips >/dev/null 2>&1; then
        [ "$2" = "full" ] && eips -c
        eips -g "$1" >/dev/null 2>&1 && return 0
    fi
    log "ERROR no working display tool (fbink or eips)"
    return 1
}

# Text card drawn over whatever is on screen. Best effort: the framework can paint
# over it later, so the log line is always the authoritative record.
text_card() {   # $1 = headline, $2.. = detail lines
    [ -x "$FBINK" ] || return 0
    "$FBINK" -c >/dev/null 2>&1
    "$FBINK" -y 3 "$1" >/dev/null 2>&1
    y=5
    shift
    for line in "$@"; do
        "$FBINK" -y "$y" "$line" >/dev/null 2>&1
        y=$((y + 1))
    done
    "$FBINK" -y $((y + 2)) "Details: calendar/calendar.log" >/dev/null 2>&1
}

# ---------------------------------------------------------------- wifi

# THE reason suspend was refused, found 2026-08-04 21:54 from the device's own
# wakelock dump: of ~25 wakeup sources, exactly one was active - "WLAN timeout",
# active_since non-zero - and it is the Wi-Fi driver's own lock. We suspend
# immediately after fetching, while the radio is still associated and holding it,
# so the kernel answers EBUSY. That is also why the standalone suspendtest always
# PASSED: it never fetches, so no Wi-Fi lock is ever taken. Dropping the radio
# before suspending releases the lock and saves the radio's idle draw as well.
wifi_down() {
    if command -v lipc-set-prop >/dev/null 2>&1; then
        lipc-set-prop com.lab126.cmd wirelessEnable 0 >/dev/null 2>&1 && {
            log "wifi disabled before suspend (releases the WLAN timeout wakelock)"
            return 0
        }
    fi
    if command -v wifid >/dev/null 2>&1; then
        wifid disable >/dev/null 2>&1 && { log "wifi disabled via wifid"; return 0; }
    fi
    iface=$(awk 'NR > 2 && /:/ { sub(/:$/, "", $1); print $1; exit }' /proc/net/wireless 2>/dev/null)
    if [ -n "$iface" ] && command -v ifconfig >/dev/null 2>&1; then
        ifconfig "$iface" down >/dev/null 2>&1 && { log "wifi $iface brought down via ifconfig"; return 0; }
    fi
    log "WARN could not disable wifi; suspend may still be refused"
    return 1
}

wifi_up() {
    if command -v lipc-set-prop >/dev/null 2>&1; then
        lipc-set-prop com.lab126.cmd wirelessEnable 1 >/dev/null 2>&1 && return 0
    fi
    if command -v wifid >/dev/null 2>&1; then
        wifid enable >/dev/null 2>&1 && return 0
    fi
    iface=$(awk 'NR > 2 && /:/ { sub(/:$/, "", $1); print $1; exit }' /proc/net/wireless 2>/dev/null)
    [ -n "$iface" ] && command -v ifconfig >/dev/null 2>&1 && ifconfig "$iface" up >/dev/null 2>&1
    return 0
}

# ---- wifi outage diagnostics (2026-08-22, instrumentation only) ----
#
# 2026-08-22: a ~4h40m outage (05:21-10:02) was fully reconstructed from the
# local log and showed wifi_reset()'s 3x-hard-reset-then-give-up sequence
# taking 27-51 minutes per pass against a nominal ~3-4 min bound - but could
# NOT tell whether that gap was (a) an uncontrolled suspend freezing the wait
# mid-call (the 2026-08-13 mechanism), (b) the wifi driver genuinely wedged,
# or (c) an AP-side problem. These two functions are pure logging - nothing
# here changes retry counts, timing, or control flow - so the NEXT drop
# records the deciding evidence instead of leaving the same open question.
#
# wall-clock (date +%s) advances through an uncontrolled suspend; monotonic
# uptime (/proc/uptime, first field) does not on this kernel family. The gap
# between the two IS the suspended duration - a large positive gap here
# proves (a) directly, for that specific wait_for_wifi call.
wifi_log_suspend_gap() {   # $1 = wall_start(date+%s) $2 = uptime_start(or empty) $3 = outcome tag
    w1=$(date +%s)
    wall_elapsed=$(( w1 - $1 ))
    if [ -n "$2" ] && [ -r /proc/uptime ]; then
        u1=$(awk '{print $1}' /proc/uptime 2>/dev/null)
        u0i=$(awk -v v="$2" 'BEGIN{print int(v)}' 2>/dev/null)
        u1i=$(awk -v v="$u1" 'BEGIN{print int(v)}' 2>/dev/null)
        case "$u0i$u1i" in *[!0-9]*|"") log "WIFIDIAG wait_for_wifi[$3] wall=${wall_elapsed}s uptime=unreadable"; return ;; esac
        uptime_elapsed=$(( u1i - u0i ))
        gap=$(( wall_elapsed - uptime_elapsed ))
        log "WIFIDIAG wait_for_wifi[$3] wall=${wall_elapsed}s uptime=${uptime_elapsed}s suspend_gap=${gap}s"
    else
        log "WIFIDIAG wait_for_wifi[$3] wall=${wall_elapsed}s uptime=unavailable"
    fi
}

# Driver/link/AP state snapshot, logged whenever a hard-reset pass fails to
# bring wifi back. Every probe is defensive (command -v / -r checked first)
# and best-effort - an absent tool just means one less line, never a stall or
# a failed cycle. Distinguishes driver-wedge (b) from AP-side (c): a genuinely
# wedged driver tends to show stale/zeroed /proc/net/wireless and iwconfig
# fields; an AP-side problem tends to show a live, scanning radio that simply
# never completes an association.
wifi_diag_snapshot() {   # $1 = short context tag
    tag="${1:-wifi}"
    if command -v dmesg >/dev/null 2>&1; then
        dmesg_tail=$(dmesg 2>/dev/null | tail -n 15 | tr '\n' ';' | tr -d '"\\')
        [ -n "$dmesg_tail" ] && log "WIFIDIAG $tag dmesg: $dmesg_tail"
    fi
    if [ -r /proc/net/wireless ]; then
        wireless_line=$(awk 'NR > 2 && /:/ {print; exit}' /proc/net/wireless 2>/dev/null | tr -d '"\\')
        [ -n "$wireless_line" ] && log "WIFIDIAG $tag /proc/net/wireless: $wireless_line"
    fi
    if command -v iwconfig >/dev/null 2>&1; then
        iwc=$(iwconfig 2>/dev/null | tr '\n' ';' | tr -d '"\\')
        [ -n "$iwc" ] && log "WIFIDIAG $tag iwconfig: $iwc"
    fi
    if command -v lipc-get-prop >/dev/null 2>&1; then
        for prop in cmState signalStrength associated essid apMac; do
            val=$(lipc-get-prop com.lab126.wifid "$prop" 2>/dev/null | tr -d '"\\')
            [ -n "$val" ] && log "WIFIDIAG $tag wifid.$prop=$val"
        done
    fi
}

# A HARD radio cycle for when the driver comes back from suspend wedged and a plain
# wifi_up is not enough. 2026-08-09: three cycles in a row logged wifi=FAIL after
# wake, the radio never reassociated, and the loop gave up. wifi_up only asks the
# radio to turn on; if it is already nominally "on" but stuck, that is a no-op.
# Toggling it fully off, letting it settle, then on - plus a wifid kick - forces a
# fresh association. Costs a few seconds and is safe when the radio is healthy.
wifi_reset() {
    wifi_down
    sleep 3
    if command -v wifid >/dev/null 2>&1; then
        wifid disable >/dev/null 2>&1
        wifid enable  >/dev/null 2>&1
    fi
    wifi_up
    sleep 2
    return 0
}

wait_for_wifi() {   # $1 = optional max seconds (default WIFI_MAX_WAIT); echoes seconds
                    # waited; rc 0 when the server host answers a ping
    _wmax="${1:-$WIFI_MAX_WAIT}"
    if [ -z "$WIFI_TEST_IP" ]; then
        echo 0
        return 0
    fi
    w0=$(date +%s)
    u0=""
    [ -r /proc/uptime ] && u0=$(awk '{print $1}' /proc/uptime 2>/dev/null)
    while :; do
        if ping -c 1 "$WIFI_TEST_IP" >/dev/null 2>&1; then
            wifi_log_suspend_gap "$w0" "$u0" ok
            echo $(( $(date +%s) - w0 ))
            return 0
        fi
        [ $(( $(date +%s) - w0 )) -ge "$_wmax" ] && break
        sleep 1
    done
    wifi_log_suspend_gap "$w0" "$u0" timeout
    echo $(( $(date +%s) - w0 ))
    return 1
}

# ---------------------------------------------------------------- wifi self-heal ladder (2026-08-26)
#
# 190 healthy cycles against 2 failures in the recent buffer, both self-clearing
# on the next cycle, show that a one-off blip is already handled fine by the
# in-cycle wifi_reset retries above. What is NOT handled is the interface
# staying stuck across MULTIPLE consecutive cycles, which is what precedes the
# long dark stretches - so this escalates only on consecutive wifi-failed
# CYCLES (main_loop's wifi_fails counter), never on the first one, and each
# rung is strictly stronger than the last.
#
# HARD CONSTRAINT: every rung runs BEFORE main_loop's normal suspend logic and
# never touches it - the same interval, the same wifi_down-then-arm_alarm path,
# always follows unchanged. No rung leaves the device awake or shortens the
# sleep; months-class battery through suspend is non-negotiable. Rung 3 is the
# one exception to "returns normally": it respawns the process, exactly like
# the server's own `restart` command, and the NEW process runs its own first
# cycle through that same unchanged suspend path.

# Rung 1: force a full interface down/up even when the soft lipc/wifid toggle
# already reports success. wifi_reset()'s in-cycle retries above stop at
# whichever method answers first, which may still be reusing a stale
# association - this always also bounces the interface itself.
wifi_ladder_rung1() {
    log "WIFI-LADDER rung1 (${wifi_fails} consecutive wifi-failed cycles): forcing full interface down/up"
    wifi_down
    sleep 3
    iface=$(awk 'NR > 2 && /:/ { sub(/:$/, "", $1); print $1; exit }' /proc/net/wireless 2>/dev/null)
    if [ -n "$iface" ] && command -v ifconfig >/dev/null 2>&1; then
        ifconfig "$iface" down >/dev/null 2>&1
        sleep 1
        ifconfig "$iface" up >/dev/null 2>&1
        log "WIFI-LADDER rung1: ifconfig $iface down/up"
    fi
    if command -v wifid >/dev/null 2>&1; then
        wifid disable >/dev/null 2>&1
        wifid enable >/dev/null 2>&1
    fi
    wifi_up
    sleep 2
}

# Rung 2: the daemon itself, not just the interface - in case wifid is what is
# actually wedged, where toggling association alone would never help.
wifi_ladder_rung2() {
    log "WIFI-LADDER rung2 (${wifi_fails} consecutive wifi-failed cycles): restarting the wifi daemon"
    method=""
    if command -v initctl >/dev/null 2>&1; then
        initctl stop wifid >/dev/null 2>&1 && method="initctl wifid"
    fi
    if [ -z "$method" ] && [ -x /etc/init.d/wifid ]; then
        /etc/init.d/wifid stop >/dev/null 2>&1 && method="init.d wifid"
    fi
    sleep 2
    case "$method" in
        "initctl wifid")  initctl start wifid >/dev/null 2>&1 ;;
        "init.d wifid")   /etc/init.d/wifid start >/dev/null 2>&1 ;;
        *) command -v initctl >/dev/null 2>&1 && initctl start wifid >/dev/null 2>&1 ;;
    esac
    if [ -n "$method" ]; then
        log "WIFI-LADDER rung2: wifid restarted via $method"
    else
        log "WIFI-LADDER rung2: WARN no wifid stop method worked; falling back to rung1's interface bounce"
        wifi_ladder_rung1
        return
    fi
    wifi_up
    sleep 2
}

# Rung 3: the biggest hammer available without a power cycle or a server-sent
# restart command - reinitializes everything (rtc detection, wifi state, PID)
# by relaunching the loop fresh, exactly like the server's own `restart`
# command (see apply_pending_command). Does not return: respawn_loop kills
# this process once the fresh __loop is launched.
wifi_ladder_rung3() {
    log "WIFI-LADDER rung3 (${wifi_fails} consecutive wifi-failed cycles): respawning the loop process"
    echo "wifi-ladder-rung3 wifi_fails=$wifi_fails at=$(date +%s)" > "$RESTART_REASON_FILE" 2>/dev/null
    push_log "wifi-ladder-rung3-respawn" 30
    respawn_loop
}

# ---------------------------------------------------------------- fetch

fetch_and_draw() {   # $1 = "full" to force a flashing refresh
    if [ -z "$HTTP" ]; then
        log "ERROR no curl or wget on this device, cannot fetch"
        return 1
    fi

    # Cleared on every call, not just set on a match, so a network failure this
    # cycle cannot leave a stale command from a PREVIOUS successful fetch sitting
    # around to be re-applied by main_loop's apply_pending_command.
    CMD_ID=""
    CMD_NAME=""
    CMD_EXPIRES_EPOCH=""
    CMD_URL=""
    CMD_SHA256=""

    rssi=$(rssi_value)
    batt=$(battery_percent)

    # FW-Version advertises grayscale support, which is what makes the server return
    # the full-grayscale PNG rather than a 1-bit BMP. Calling /api/display is also what
    # keeps the device card thumbnail current on the server's Devices tab.
    if [ "$HTTP" = "curl" ]; then
        set -- -s -m 30 -H "ID: $DEVICE" -H "Access-Token: kindle" -H "FW-Version: 1.6.6"
        [ -n "$rssi" ] && set -- "$@" -H "RSSI: $rssi"
        [ -n "$batt" ] && set -- "$@" -H "Battery-Percent: $batt"
        json=$(curl "$@" "$SERVER/api/display")
    else
        set -- -q -T 30 -O - --header="ID: $DEVICE" --header="Access-Token: kindle" \
            --header="FW-Version: 1.6.6"
        [ -n "$rssi" ] && set -- "$@" --header="RSSI: $rssi"
        [ -n "$batt" ] && set -- "$@" --header="Battery-Percent: $batt"
        json=$(wget "$@" "$SERVER/api/display")
    fi

    img=$(echo "$json" | sed -n 's/.*"image_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    if [ -z "$img" ]; then
        log "ERROR no image_url in response"
        return 1
    fi

    # The server also tells us how often to come back. Honor it only when it is a
    # plain integer inside sane bounds; anything else (missing field, garbage, a
    # server bug serving an absurd number) falls back to INTERVAL. Cadence changes
    # are therefore server-side only - no USB pass needed.
    SERVED_INTERVAL=""
    served=$(echo "$json" | sed -n 's/.*"refresh_rate"[[:space:]]*:[[:space:]]*\([0-9]\{1,\}\).*/\1/p')
    case "$served" in
        ''|*[!0-9]*) ;;
        *)
            if [ "$served" -ge "$MIN_INTERVAL" ] 2>/dev/null && \
               [ "$served" -le "$MAX_INTERVAL" ] 2>/dev/null; then
                SERVED_INTERVAL="$served"
            fi
            ;;
    esac

    # Wifi update channel: flat cmd_* fields, same style as image_url/refresh_rate
    # above. Empty cmd_id means "no command pending". cmd_url can itself contain
    # slashes, so it gets a '#' sed delimiter instead of '/'.
    CMD_ID=$(echo "$json" | sed -n 's/.*"cmd_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    CMD_NAME=$(echo "$json" | sed -n 's/.*"cmd_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    CMD_EXPIRES_EPOCH=$(echo "$json" | sed -n 's/.*"cmd_expires_epoch"[[:space:]]*:[[:space:]]*\([0-9]\{1,\}\).*/\1/p')
    CMD_URL=$(echo "$json" | sed -n 's#.*"cmd_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*#\1#p')
    CMD_SHA256=$(echo "$json" | sed -n 's/.*"cmd_sha256"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

    if ! http_file "$img" "$TMP"; then
        log "ERROR download failed, keeping previous screen"
        return 1
    fi
    if [ ! -s "$TMP" ]; then
        log "ERROR empty download, keeping previous screen"
        return 1
    fi

    # Only replace the live image once the download succeeded, so a failed fetch
    # leaves the last good agenda on screen instead of blanking it.
    mv "$TMP" "$OUT"

    draw "$OUT" "$1"
    log "drew $OUT mode=${1:-partial} rssi=${rssi:-none} batt=${batt:-none}"
    return 0
}

# ---------------------------------------------------------------- rtc suspend

# The 2026-08-02 on-device probe confirmed /sys/class/rtc/rtc0/wakealarm is present
# and writable from this script's context, so the mxc and rtcwake fallbacks the
# first draft carried are gone: dead code on this device, and a fallback that only
# fires when the primary breaks is exactly the code path that never gets tested.
#
# BACKUP ALARM (2026-08-21): about 1 wake in 50, the rtc0 alarm did not fire and
# the screen simply stopped updating - no error, nothing in the log, because
# nothing ran to write one. A single wake source has no redundancy: if rtc0's
# alarm is silently dropped by the kernel or the hardware once in a while, there
# is nothing else to wake the device. rtc1, where present and writable, gets the
# SAME armed value mirrored onto it every time rtc0 is armed, so a missed rtc0
# fire still has a second alarm pending. This is best-effort only: it never
# blocks, and a failure to write rtc1 never fails the primary arm or the cycle.
RTC1_WRITABLE=no

detect_backup_rtc() {
    if [ -e "$RTC_ALARM_BACKUP" ] && [ -w "$RTC_ALARM_BACKUP" ]; then
        RTC1_WRITABLE=yes
    else
        RTC1_WRITABLE=no
    fi
    rtc0_state=unwritable
    [ -w "$RTC_ALARM" ] && rtc0_state=writable
    rtc1_state=absent
    if [ -e "$RTC_ALARM_BACKUP" ]; then
        rtc1_state=unwritable
        [ -w "$RTC_ALARM_BACKUP" ] && rtc1_state=writable
    fi
    log "startup rtc: rtc0=$RTC_ALARM($rtc0_state) rtc1=$RTC_ALARM_BACKUP($rtc1_state) backup_alarm=$RTC1_WRITABLE"
}

# Best-effort power/suspend diagnostics, logged once at startup so a missed wake
# is explainable from calendar.log alone without another USB pass. Both paths are
# kernel-version-dependent, so each is checked before being read - an absent path
# is silently skipped rather than logged as an error.
log_power_diagnostics() {
    if [ -r /sys/power/wakeup_count ]; then
        wc=$(cat /sys/power/wakeup_count 2>/dev/null)
        log "startup wakeup_count=${wc:-unreadable}"
    fi
    if [ -d /sys/power/suspend_stats ]; then
        for f in /sys/power/suspend_stats/*; do
            [ -f "$f" ] || continue
            v=$(cat "$f" 2>/dev/null)
            log "startup suspend_stats/$(basename "$f")=${v:-unreadable}"
        done
    fi
}

arm_alarm() {   # $1 = seconds from now; rc 0 only when the PRIMARY armed value reads back
    echo 0 > "$RTC_ALARM" 2>/dev/null
    if ! echo "+$1" > "$RTC_ALARM" 2>/dev/null; then
        # Some kernels reject the relative form; fall back to an absolute epoch.
        echo $(( $(date +%s) + $1 )) > "$RTC_ALARM" 2>/dev/null || return 1
    fi
    ARMED_AT=$(cat "$RTC_ALARM" 2>/dev/null)
    # A non-empty readback is NOT proof the alarm is set. A cleared wakealarm
    # reads back as "0", and [ -n "0" ] is TRUE, so the old check passed with no
    # alarm armed and the device then suspended with nothing to wake it - it
    # sleeps until someone presses the power button. That is the most likely
    # cause of the 2026-08-05 09:00 stop after 44 clean cycles: silent, no error,
    # calendar frozen on the last draw. Demand a number strictly in the future.
    case "$ARMED_AT" in
        ''|*[!0-9]*) log "ERROR alarm readback not numeric: '$ARMED_AT'"; return 1 ;;
    esac
    now_s=$(date +%s)
    if [ "$ARMED_AT" -le "$now_s" ] 2>/dev/null; then
        log "ERROR alarm readback $ARMED_AT is not in the future (now $now_s); refusing to suspend"
        return 1
    fi

    if [ "$RTC1_WRITABLE" = yes ]; then
        echo 0 > "$RTC_ALARM_BACKUP" 2>/dev/null
        if echo "$ARMED_AT" > "$RTC_ALARM_BACKUP" 2>/dev/null; then
            backup_readback=$(cat "$RTC_ALARM_BACKUP" 2>/dev/null)
            log "backup alarm (rtc1) mirrored readback=${backup_readback:-FAIL}"
        else
            log "WARN backup alarm (rtc1) write failed; continuing on rtc0 alone"
        fi
    fi

    # Clock sanity check, logged right after every successful arm so a wake that
    # never fires can be told apart from a wake that fired against a clock that
    # had drifted or reset. rtc0's own since_epoch is compared against the system
    # clock the alarm math above was computed from.
    rtc_since_epoch=""
    [ -r /sys/class/rtc/rtc0/since_epoch ] && rtc_since_epoch=$(cat /sys/class/rtc/rtc0/since_epoch 2>/dev/null)
    clock_drift=""
    case "$rtc_since_epoch" in
        ''|*[!0-9]*) ;;
        *) clock_drift=$((now_s - rtc_since_epoch)) ;;
    esac
    log "alarm armed readback=$ARMED_AT (+$((ARMED_AT - now_s))s) rtc0_since_epoch=${rtc_since_epoch:-unavailable} sys_epoch=$now_s drift=${clock_drift:-n/a}s"
    return 0
}

disarm_alarm() {
    echo 0 > "$RTC_ALARM" 2>/dev/null
    [ "$RTC1_WRITABLE" = yes ] && echo 0 > "$RTC_ALARM_BACKUP" 2>/dev/null
}

do_suspend() {   # $1 = expected seconds; sets SLEPT; rc 0 when the write succeeded
    s0=$(date +%s)
    sync    # the log must survive even if the device never wakes
    # The kernel's refusal text (e.g. "write error: Device or resource busy") goes
    # into the log: a refused suspend must say WHY without another debugging pass.
    # The stderr redirect comes FIRST: redirections apply left to right, and if the
    # stdout open is what fails, a trailing 2>> would never capture the message.
    if ! echo mem 2>>"$LOG" > "$POWER_STATE"; then
        SLEPT=0
        return 1
    fi
    SLEPT=$(( $(date +%s) - s0 ))
    return 0
}

suspend_held() {   # $1 = expected seconds; rc 0 when the sleep ran at least 7/8 of it
    [ "$SLEPT" -ge $(( $1 * 7 / 8 )) ]
}

# ---------------------------------------------------------------- diagnostics

probe_report() {
    iface=$(awk 'NR > 2 && /:/ { sub(/:$/, "", $1); print $1; exit }' /proc/net/wireless 2>/dev/null)
    rssi=$(rssi_value)
    batt=$(battery_percent)
    gg=$(command -v gasgauge-info >/dev/null 2>&1 && echo yes || echo no)
    lp=$(command -v lipc-get-prop >/dev/null 2>&1 && echo yes || echo no)
    caps=$(ls /sys/class/power_supply/ 2>/dev/null | tr '\n' ' ')
    rtc=NONE
    [ -w "$RTC_ALARM" ] && rtc=wakealarm
    detect_backup_rtc
    log_power_diagnostics

    log "PROBE iface=${iface:-none} rssi=${rssi:-FAIL} batt=${batt:-FAIL}"
    log "PROBE gasgauge=$gg lipc=$lp power_supply='${caps:-none}' http=${HTTP:-NONE} rtc=$rtc rtc_backup=$RTC1_WRITABLE"

    if [ -x "$FBINK" ]; then
        "$FBINK" -c >/dev/null 2>&1
        "$FBINK" -y 2  "TRMNL calendar probe report" >/dev/null 2>&1
        "$FBINK" -y 4  "wifi iface : ${iface:-none}" >/dev/null 2>&1
        "$FBINK" -y 5  "rssi       : ${rssi:-FAILED}" >/dev/null 2>&1
        "$FBINK" -y 6  "battery %  : ${batt:-FAILED}" >/dev/null 2>&1
        "$FBINK" -y 8  "gasgauge   : $gg" >/dev/null 2>&1
        "$FBINK" -y 9  "lipc       : $lp" >/dev/null 2>&1
        "$FBINK" -y 10 "power_supply: ${caps:-none}" >/dev/null 2>&1
        "$FBINK" -y 12 "http client: ${HTTP:-NONE}" >/dev/null 2>&1
        "$FBINK" -y 13 "rtc wakeup : $rtc" >/dev/null 2>&1
        "$FBINK" -y 15 "Also written to calendar.log" >/dev/null 2>&1
    fi
}

show_ruler() {
    card="$BASE/type_ruler.png"
    if [ ! -s "$card" ]; then
        log "ERROR ruler card missing at $card"
        [ -x "$FBINK" ] && "$FBINK" -c -y 4 "Type ruler image not found." >/dev/null 2>&1
        return 1
    fi
    draw "$card" full
    log "drew type ruler $card"
}

# One suspend/resume cycle, nothing else. Does not stop the framework, does not
# loop, and always ends with the device awake. This must PASS - and its log must be
# read - before anyone enables suspend in the refresh loop.
# Same test, but with the screen takeover applied first. suspend_test passes on
# this device while the loop's suspend is always refused, and takeover_begin is the
# only material difference between them: it stops the framework. This isolates that
# single variable in one 2-minute run instead of another overnight guess.
# MUST run detached, for exactly the reason the loop must: takeover_begin stops the
# framework, KUAL is part of the framework and is our parent, so a foreground run
# kills itself the moment the takeover lands. The 2026-08-04 21:41 attempt did
# precisely that - "taking over screen" and then nothing, no verdict at all. So the
# entry point only detaches; the real work happens in __suspendtest_takeover.
suspend_test_takeover() {
    dur="${1:-120}"
    SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null)
    if [ -z "$SCRIPT_PATH" ] || [ ! -f "$SCRIPT_PATH" ]; then
        case "$0" in
            /*) SCRIPT_PATH="$0" ;;
            *)  SCRIPT_PATH="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")" ;;
        esac
    fi
    log "SUSPENDTEST-TAKEOVER: detaching, then stopping framework, then same test"
    if command -v setsid >/dev/null 2>&1; then
        setsid /bin/sh "$SCRIPT_PATH" __suspendtest_takeover "$dur" </dev/null >/dev/null 2>&1 &
    else
        /bin/sh "$SCRIPT_PATH" __suspendtest_takeover "$dur" </dev/null >/dev/null 2>&1 &
    fi
    return 0
}

suspend_test() {   # $1 = seconds to sleep, default 120
    dur="${1:-120}"
    sleep "$FIRST_DRAW_DELAY"
    b0=$(battery_percent)
    log "SUSPENDTEST begin dur=${dur}s batt=${b0:-none}"

    if ! arm_alarm "$dur"; then
        log "SUSPENDTEST verdict=FAIL reason=alarm-not-armed (write failed or readback empty)"
        text_card "TRMNL SUSPEND TEST: FAIL" \
            "RTC alarm did not arm." \
            "Device was NOT suspended and is awake."
        return 1
    fi
    log "SUSPENDTEST armed readback=$ARMED_AT now=$(date +%s); suspending"

    if ! do_suspend "$dur"; then
        disarm_alarm
        log "SUSPENDTEST verdict=FAIL reason=suspend-write-refused"
        wakelock_report
        push_log "suspendtest-fail" 30
        text_card "TRMNL SUSPEND TEST: FAIL" \
            "Kernel refused the suspend write." \
            "Device never slept and is awake."
        return 1
    fi

    # From here the device did come back, or none of this would run.
    wifi_up
    wifi_s=$(wait_for_wifi)
    wifi_ok=$?
    b1=$(battery_percent)

    if suspend_held "$dur"; then
        held=yes
    else
        held=no
        disarm_alarm    # a stale alarm from a failed sleep must not fire later
    fi

    verdict=FAIL
    reason=""
    if [ "$held" = "yes" ] && [ "$wifi_ok" -eq 0 ]; then
        verdict=PASS
    elif [ "$held" = "no" ]; then
        reason=" reason=short-sleep (suspend returned early or never entered)"
    else
        reason=" reason=wifi-not-back (slept fine, no ping within ${WIFI_MAX_WAIT}s)"
    fi

    log "SUSPENDTEST verdict=$verdict slept=${SLEPT}s expected=${dur}s wifi_back=${wifi_s}s wifi_ok=$wifi_ok batt_before=${b0:-none} batt_after=${b1:-none}$reason"
    if [ "$verdict" = "PASS" ]; then
        log "SUSPENDTEST note: suspend stays LOCKED for the loop until suspend.enabled is created by hand"
    fi

    text_card "TRMNL SUSPEND TEST: $verdict" \
        "slept      : ${SLEPT}s of ${dur}s" \
        "wifi back  : ${wifi_s}s (ok=$wifi_ok)" \
        "battery    : ${b0:-?}% -> ${b1:-?}%" \
        "Device is awake and back to normal."
    # The framework may repaint on resume; draw the card a second time so it wins.
    sleep 2
    text_card "TRMNL SUSPEND TEST: $verdict" \
        "slept      : ${SLEPT}s of ${dur}s" \
        "wifi back  : ${wifi_s}s (ok=$wifi_ok)" \
        "battery    : ${b0:-?}% -> ${b1:-?}%" \
        "Device is awake and back to normal."
    [ "$verdict" = "PASS" ]
}

# ---------------------------------------------------------------- takeover

takeover_begin() {
    # Order follows kindle-dash: stop the reader UI first so nothing repaints over
    # the agenda, then drop the CPU to powersave.
    #
    # preventScreenSaver is deliberately NOT set here. On the 2026-08-02 overnight
    # run every suspend write came back refused, while the suspendtest - which never
    # runs this takeover - suspended cleanly. preventScreenSaver's entire job is to
    # hold the device awake, so setting it and then asking for suspend-to-RAM is
    # asking powerd to fight the kernel. It is now set only when the loop gives up
    # on suspend and needs to stay awake for long stretches (screensaver_hold).
    log "taking over screen"
    # Firmware 5.19.2 evidence (2026-08-03 log): the old /etc/init.d/framework and
    # bare initctl guards both failed SILENTLY, the framework stayed up, and the
    # home UI repainted over the calendar - which read as "Start does nothing".
    # So: try each known GUI stop in order, record which one actually worked, and
    # say NONE out loud when nothing did. takeover_end restores the same method.
    gui_method=""
    if command -v initctl >/dev/null 2>&1; then
        initctl stop framework >/dev/null 2>&1 && gui_method="initctl framework"
        if [ -z "$gui_method" ]; then
            initctl stop lab126_gui >/dev/null 2>&1 && gui_method="initctl lab126_gui"
        fi
    fi
    if [ -z "$gui_method" ] && [ -x /etc/init.d/framework ]; then
        /etc/init.d/framework stop >/dev/null 2>&1 && gui_method="init.d framework"
    fi
    if [ -n "$gui_method" ]; then
        echo "$gui_method" > "$BASE/gui.method"
        log "takeover: gui stopped via $gui_method"
    else
        mv "$BASE/gui.method" "$BASE/gui.method.none" 2>/dev/null
        log "takeover: NO gui stop method worked; relying on the redraw guard"
    fi
    if command -v initctl >/dev/null 2>&1; then
        initctl stop webreader >/dev/null 2>&1
    fi
    if [ -w /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
        echo powersave > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null
    fi
    : > "$STATEFILE"
}

# Hold off the screensaver, once, for awake-fallback modes where the device will
# sit unsuspended for whole intervals - otherwise the screensaver paints over the
# agenda within minutes. Never call this on the suspend path. takeover_end clears it.
SCREENSAVER_HELD=0
screensaver_hold() {
    [ "$SCREENSAVER_HELD" -eq 1 ] && return 0
    if command -v lipc-set-prop >/dev/null 2>&1; then
        lipc-set-prop com.lab126.powerd preventScreenSaver 1 >/dev/null 2>&1
    fi
    SCREENSAVER_HELD=1
    log "screensaver held off for awake fallback"
}

# The hold is sticky, and preventScreenSaver's whole job is to keep the device
# awake, so leaving it set while asking the kernel to suspend is asking powerd to
# fight the kernel. Once awake_sleep started holding it unconditionally, every
# LATER suspend attempt in the same run would have inherited that hold and could
# have been refused because of it - the fix causing the failure it was fixing.
# Release before any suspend attempt; awake_sleep re-holds when it needs to.
screensaver_release() {
    [ "$SCREENSAVER_HELD" -eq 0 ] && return 0
    if command -v lipc-set-prop >/dev/null 2>&1; then
        lipc-set-prop com.lab126.powerd preventScreenSaver 0 >/dev/null 2>&1
    fi
    SCREENSAVER_HELD=0
    log "screensaver hold released before suspend attempt"
}

# A refused suspend is EBUSY from a held wakelock. Without naming the holder the
# log only says "refused", which is what turned this into a multi-day guess.
wakelock_report() {
    for f in /sys/power/wake_lock /proc/wakelocks /sys/kernel/debug/wakeup_sources; do
        [ -r "$f" ] || continue
        val=$(head -c 2000 "$f" 2>/dev/null | tr '\n' ' ')
        [ -n "$val" ] && log "WAKELOCK $f: $val"
    done
    if command -v lipc-get-prop >/dev/null 2>&1; then
        pss=$(lipc-get-prop com.lab126.powerd preventScreenSaver 2>/dev/null)
        log "WAKELOCK preventScreenSaver=${pss:-unknown}"
    fi
}

# ---- suspend-does-not-hold diagnostics (2026-08-23, instrumentation only) ----
#
# 2026-08-23: a genuine "ERROR suspend did not hold" (slept 223s of 900s) was
# the actual trigger of an outage that then cascaded through the awake-fallback
# path. wakelock_report() above already answers "what's holding a wakelock",
# but not "what woke it back up". This answers that second question: call it
# BEFORE disarm_alarm() clears the RTC register, so the register's value is
# still whatever it was at the moment of the early wake. $1 = wakeup_count
# captured right before the suspend attempt, for a before/after delta.
suspend_hold_diag_snapshot() {   # $1 = wakeup_count sampled before the suspend attempt (or empty)
    tag="suspend-hold"
    if [ -r "$RTC_ALARM" ]; then
        rtc_val=$(cat "$RTC_ALARM" 2>/dev/null)
        # A cleared/near-zero register is consistent with the alarm having
        # actually fired; a register still holding a FUTURE value implicates
        # something else as the wake source, since the alarm we armed never
        # got there.
        log "SUSPENDDIAG $tag rtc0_wakealarm_register=${rtc_val:-unreadable}"
    fi
    if [ -r /sys/power/wakeup_count ]; then
        wc_after=$(cat /sys/power/wakeup_count 2>/dev/null)
        if [ -n "$1" ] && [ -n "$wc_after" ]; then
            case "$1$wc_after" in
                *[!0-9]*) log "SUSPENDDIAG $tag wakeup_count=${wc_after} (before value unreadable, no delta)" ;;
                *) log "SUSPENDDIAG $tag wakeup_count=${wc_after} delta=$(( wc_after - $1 ))" ;;
            esac
        else
            log "SUSPENDDIAG $tag wakeup_count=${wc_after:-unreadable}"
        fi
    fi
    if [ -d /sys/power/suspend_stats ]; then
        for f in /sys/power/suspend_stats/*; do
            [ -f "$f" ] || continue
            v=$(cat "$f" 2>/dev/null)
            log "SUSPENDDIAG $tag suspend_stats/$(basename "$f")=${v:-unreadable}"
        done
    fi
    # USB/charger state - relevant per Jonathan: the device was unplugged when
    # 2026-08-23's trigger fired and is plugged in now, so this is worth having
    # on record for every future occurrence regardless of which way it points.
    for psy in /sys/class/power_supply/*/online /sys/class/power_supply/*/status; do
        [ -r "$psy" ] || continue
        v=$(cat "$psy" 2>/dev/null)
        log "SUSPENDDIAG $tag $psy=${v:-unreadable}"
    done
    wakelock_report
}

takeover_end() {
    # Restore in the reverse order. Nothing here is persistent, so a power-button
    # restart also returns the Kindle to normal even if this never runs.
    log "restoring normal Kindle"
    if command -v lipc-set-prop >/dev/null 2>&1; then
        lipc-set-prop com.lab126.powerd preventScreenSaver 0 >/dev/null 2>&1
    fi
    if [ -w /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
        echo ondemand > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null
    fi
    if command -v initctl >/dev/null 2>&1; then
        initctl start webreader >/dev/null 2>&1
    fi
    # Restart the GUI with whichever method takeover_begin recorded; if none was
    # recorded, try them all - restarting an already-running framework is harmless.
    gui_method=$(cat "$BASE/gui.method" 2>/dev/null)
    case "$gui_method" in
        "initctl framework")   initctl start framework >/dev/null 2>&1 ;;
        "initctl lab126_gui")  initctl start lab126_gui >/dev/null 2>&1 ;;
        "init.d framework")    /etc/init.d/framework start >/dev/null 2>&1 ;;
        *)
            command -v initctl >/dev/null 2>&1 && initctl start framework >/dev/null 2>&1
            command -v initctl >/dev/null 2>&1 && initctl start lab126_gui >/dev/null 2>&1
            [ -x /etc/init.d/framework ] && /etc/init.d/framework start >/dev/null 2>&1
            ;;
    esac
    mv "$BASE/gui.method" "$BASE/gui.method.last" 2>/dev/null
    [ -f "$STATEFILE" ] && mv "$STATEFILE" "$STATEFILE.last" 2>/dev/null
}

# ---------------------------------------------------------------- commands

# Detach a fresh loop from SCRIPT_PATH (which, after apply_script_update, may now
# point at a swapped-in file), then kill this process's own group. Mirrors the
# watchdog's own resurrection pattern exactly. The watchdog is a SEPARATE process
# and is untouched by this - it keeps polling the heartbeat file and supervises
# the new loop exactly as it did the old one; PIDFILE gets overwritten by the new
# loop's own startup line.
respawn_loop() {
    oldpid=$(cat "$PIDFILE" 2>/dev/null)
    if command -v setsid >/dev/null 2>&1; then
        setsid /bin/sh "$SCRIPT_PATH" __loop </dev/null >/dev/null 2>&1 &
    else
        /bin/sh "$SCRIPT_PATH" __loop </dev/null >/dev/null 2>&1 &
    fi
    sleep 2
    if [ -n "$oldpid" ]; then
        kill -- "-$oldpid" 2>/dev/null || kill "$oldpid" 2>/dev/null
    fi
    exit 0
}

# Download, verify, and atomically swap in a new calendar.sh. CMD_URL/CMD_SHA256
# come from the server on every /api/display poll (see fetch_and_draw), resolved
# fresh from whatever is on the server's disk right now - never trusted blindly:
# a checksum mismatch keeps the CURRENT script running and just logs the mismatch,
# exactly as required. Only sha256, not md5, is trusted for this verification -
# md5 is only ever used for the lighter-weight version confirmation in push_log.
apply_script_update() {
    if [ -z "$CMD_URL" ] || [ -z "$CMD_SHA256" ]; then
        log "ERROR COMMAND fetch-and-replace-script missing url or sha256; ignoring"
        push_log "command-update-missing-params" 10
        return 1
    fi
    if ! command -v sha256sum >/dev/null 2>&1; then
        log "ERROR COMMAND fetch-and-replace-script: no sha256sum on this device; cannot verify, keeping current script"
        push_log "command-update-no-sha256sum" 10
        return 1
    fi

    new_path="$BASE/calendar.sh.new"
    if ! http_file "$CMD_URL" "$new_path"; then
        log "ERROR COMMAND fetch-and-replace-script: download failed from $CMD_URL"
        push_log "command-update-download-failed" 10
        return 1
    fi
    if [ ! -s "$new_path" ]; then
        log "ERROR COMMAND fetch-and-replace-script: downloaded file is empty"
        push_log "command-update-empty" 10
        return 1
    fi

    got_sha=$(sha256sum "$new_path" 2>/dev/null | awk '{print $1}')
    if [ "$got_sha" != "$CMD_SHA256" ]; then
        log "COMMAND fetch-and-replace-script: checksum MISMATCH expected=$CMD_SHA256 got=${got_sha:-none}; keeping current script"
        mv "$new_path" "$new_path.mismatch" 2>/dev/null
        push_log "command-update-checksum-mismatch" 15
        return 1
    fi

    # The checksum only proves the download matches what the server sent - it says
    # nothing about whether what the server sent actually RUNS. This is the one USB
    # deploy; every fix after it rides this same channel, so a syntax error Jonathan
    # authors has to be caught here, not discovered as a dark screen days later.
    if ! sh -n "$new_path" 2>>"$LOG"; then
        log "COMMAND fetch-and-replace-script: SYNTAX CHECK FAILED on downloaded script; keeping current script"
        mv "$new_path" "$new_path.syntax-bad" 2>/dev/null
        push_log "command-update-syntax-bad" 20
        return 1
    fi

    # Last-known-good, saved BEFORE the swap so check_update_probation always has
    # something to fall back to. Best-effort: if this copy fails, skip probation
    # entirely and swap without a safety net rather than silently pretend one exists.
    if cp "$SCRIPT_PATH" "$PREV_SCRIPT_FILE" 2>/dev/null; then
        # A stale update_ok from an EARLIER update must not let this new one skip
        # probation before it has proven anything itself.
        [ -f "$UPDATE_OK_FILE" ] && mv "$UPDATE_OK_FILE" "$UPDATE_OK_FILE.prev" 2>/dev/null
        probation_window=$(( ${iv:-$INTERVAL} * 3 ))
        echo $(( $(date +%s) + probation_window )) > "$UPDATE_PROBATION_FILE" 2>/dev/null
        log "COMMAND fetch-and-replace-script: saved $PREV_SCRIPT_FILE, probation window ${probation_window}s"
    else
        log "WARN COMMAND fetch-and-replace-script: could not save $PREV_SCRIPT_FILE; proceeding WITHOUT auto-revert probation"
    fi

    chmod +x "$new_path" 2>/dev/null
    # Same-filesystem mv is the atomic swap: there is never a window where
    # SCRIPT_PATH is missing or half-written, so a crash mid-swap cannot leave
    # the device without a runnable script.
    if ! mv "$new_path" "$SCRIPT_PATH" 2>/dev/null; then
        log "ERROR COMMAND fetch-and-replace-script: swap into $SCRIPT_PATH failed"
        push_log "command-update-swap-failed" 10
        return 1
    fi

    log "COMMAND fetch-and-replace-script: applied sha256=$got_sha, relaunching"
    echo "script-update sha256=$got_sha at=$(date +%s)" > "$RESTART_REASON_FILE" 2>/dev/null
    push_log "command-update-applied" 15
    respawn_loop
}

# Called from TWO places, both required - neither alone closes the hole:
#   1. Very early at process start, right after SCRIPT_PATH is resolved and before
#      any entrypoint-specific work, on EVERY start/respawn/relaunch - including a
#      run of a script that might itself be the broken one. Catches a script that
#      crashes, hangs before its first heartbeat, or otherwise never gets far
#      enough to run main_loop at all.
#   2. Once per main_loop iteration, right after heartbeat(). heartbeat() is
#      written unconditionally every iteration, so a script that RUNS and
#      heartbeats but never completes a single healthy fetch+draw cycle would
#      otherwise satisfy the watchdog forever - the process never dies, so the
#      start-time-only call would never get a chance to re-fire, and probation
#      would never actually be enforced. This closes that gap.
#
# $@ = the args to relaunch the reverted script with. The two callers differ:
# the start-time call forwards "$@" (the script's own original invocation args,
# e.g. "suspendtest 120"), continuing whatever was originally asked for. The
# in-loop call has no such args of its own to forward - it always passes the
# literal "__loop", because that's what it needs to become again either way.
#
# Kept intentionally tiny and dependency-free (no curl/wget, no plugin logic) so
# a broken update can't take this guard down with it. If probation expired with
# no health marker, the update is presumed bad and gets reverted with no human
# intervention, from whichever caller notices first.
check_update_probation() {
    [ -f "$UPDATE_PROBATION_FILE" ] || return 0
    deadline=$(cat "$UPDATE_PROBATION_FILE" 2>/dev/null)
    case "$deadline" in
        ''|*[!0-9]*) return 0 ;;
    esac
    [ -f "$UPDATE_OK_FILE" ] && return 0
    now_s=$(date +%s)
    [ "$now_s" -ge "$deadline" ] 2>/dev/null || return 0

    log "UPDATE PROBATION EXPIRED (deadline=$deadline now=$now_s) with no update_ok; reverting to $PREV_SCRIPT_FILE"
    if [ -s "$PREV_SCRIPT_FILE" ] && cp "$PREV_SCRIPT_FILE" "$SCRIPT_PATH" 2>/dev/null; then
        chmod +x "$SCRIPT_PATH" 2>/dev/null
        mv "$UPDATE_PROBATION_FILE" "$UPDATE_PROBATION_FILE.reverted" 2>/dev/null
        log "UPDATE REVERTED: $PREV_SCRIPT_FILE restored over $SCRIPT_PATH; relaunching reverted script ($*)"
        push_log "update-auto-reverted" 30
        exec /bin/sh "$SCRIPT_PATH" "$@"
    fi
    log "ERROR UPDATE PROBATION EXPIRED but $PREV_SCRIPT_FILE is missing/empty; cannot auto-revert, continuing on current script"
    mv "$UPDATE_PROBATION_FILE" "$UPDATE_PROBATION_FILE.revert-failed" 2>/dev/null
    push_log "update-auto-revert-failed" 30
}

# Called once per cycle after a successful /api/display fetch. CMD_ID empty means
# no command is pending. LAST_COMMAND_FILE is written BEFORE acting - not after -
# because fetch-and-replace-script and restart both respawn and kill this process,
# and the new process reads the same file: without recording first, a respawn
# mid-action would make the new process see the same command still pending and
# act on it again, forever.
apply_pending_command() {
    [ -n "$CMD_ID" ] || return 0
    last=$(cat "$LAST_COMMAND_FILE" 2>/dev/null)
    [ "$CMD_ID" = "$last" ] && return 0

    log "COMMAND received id=$CMD_ID name=$CMD_NAME"
    echo "$CMD_ID" > "$LAST_COMMAND_FILE" 2>/dev/null
    echo "$CMD_ID" > "$PENDING_ACK_FILE" 2>/dev/null
    ACK_ID="$CMD_ID"

    case "$CMD_NAME" in
        stay-awake)
            if [ -n "$CMD_EXPIRES_EPOCH" ] && [ "$CMD_EXPIRES_EPOCH" -gt 0 ] 2>/dev/null; then
                echo "$CMD_EXPIRES_EPOCH" > "$STAY_AWAKE_FILE" 2>/dev/null
                log "COMMAND stay-awake armed until epoch=$CMD_EXPIRES_EPOCH"
            else
                log "ERROR COMMAND stay-awake missing a valid expiry; ignoring"
            fi
            push_log "command-stay-awake" 15
            ;;
        fetch-and-replace-script)
            apply_script_update
            ;;
        restart)
            log "COMMAND restart: relaunching loop"
            echo "server-restart-command id=$CMD_ID at=$(date +%s)" > "$RESTART_REASON_FILE" 2>/dev/null
            push_log "command-restart" 15
            respawn_loop
            ;;
        upload-full-log)
            log "COMMAND upload-full-log"
            push_log "command-full-log" 1000
            # main_loop's own end-of-cycle push_log would otherwise fire immediately
            # after this one with zero delay. Observed on-device (2026-08-22, 2/2):
            # when that happens, THIS push - the one actually carrying the requested
            # large tail - is the one that silently vanishes; only the smaller
            # trailing push arrives. Root mechanism unconfirmed (possibly the size of
            # this specific pull, possibly the back-to-back timing - a same-size
            # command, stay-awake, has NOT shown this failure). Suppressing the
            # second call removes the race either way, and this push already
            # contains everything the normal one would have shown.
            SKIP_NORMAL_PUSH=1
            ;;
        *)
            log "WARN unknown command name '$CMD_NAME'; nothing to do"
            push_log "command-unknown" 10
            ;;
    esac
}

# ---------------------------------------------------------------- loop

main_loop() {
    n=0
    fails=0           # consecutive failed cycles (wifi or fetch)
    wifi_fails=0      # consecutive cycles where wifi ITSELF stayed down after all in-cycle
                      # retries - drives the self-heal ladder below, separately from `fails`,
                      # so a healthy-wifi/server-down cycle never triggers a wifi remedy
    suspend_fails=0   # consecutive failed suspends; at MAX_FAILS suspend is abandoned
    backlog_checked=0 # upload_backlog_if_any runs once, on this process's first successful
                      # network cycle, never again in this process's lifetime
    draws=0
    iv="$INTERVAL"    # effective interval; updated from the served value each cycle
    iv_src=default

    # KUAL repaints as it exits, so wait a moment before the first draw or the
    # agenda can be painted over immediately and look like nothing happened.
    sleep "$FIRST_DRAW_DELAY"

    while :; do
        if [ -f "$STOPFLAG" ]; then
            mv "$STOPFLAG" "$STOPFLAG.done" 2>/dev/null
            log "stop.flag found; loop exiting, restoring Kindle"
            takeover_end
            return 0
        fi

        n=$((n + 1))
        heartbeat
        rotate_log_if_needed
        # Reset every iteration - apply_pending_command (below, via
        # upload-full-log) is the only thing that ever sets this, and it must
        # never leak forward into a later cycle that had no command at all.
        SKIP_NORMAL_PUSH=0

        # Probation is also enforced from INSIDE the loop, not just at process
        # start. heartbeat() above is written unconditionally every iteration, so
        # an updated script that runs and heartbeats but never completes a single
        # healthy fetch+draw cycle would otherwise keep the watchdog satisfied
        # forever - it never restarts the process, so the start-time-only guard
        # would never re-fire and probation would never actually get enforced.
        # Checking here closes that hole: a no-op until the deadline and a no-op
        # once update_ok exists, same as the start-time guard, and it reverts and
        # relaunches straight into __loop (not "$@" - main_loop has no original
        # invocation args of its own to forward) when the deadline has passed.
        check_update_probation __loop

        # SAFETY ALARM, armed before any work in this cycle can wedge.
        #
        # The normal path re-arms this precisely just before suspending, so in
        # healthy operation this value is always overwritten and costs nothing.
        # It only matters when the cycle never reaches the suspend step: on
        # 2026-08-06 the loop died mid-fetch, powerd suspended the device, and
        # because arming happened only at the END of a cycle there was no alarm
        # pending and the device slept until a power-button hold. Arming here
        # means the worst case is one missed refresh, not a dark screen.
        if arm_alarm $(( iv + SAFETY_GRACE )); then
            log "safety alarm armed for $(( iv + SAFETY_GRACE ))s before cycle n=$n"
        else
            log "WARN safety alarm could NOT be armed before cycle n=$n"
        fi

        batt=$(battery_percent)
        # The radio is deliberately taken down before every suspend attempt, so it
        # must be brought back at the top of every cycle before anything needs the
        # network. wifi_up is cheap and idempotent when the radio is already on.
        wifi_up
        # Quick UNHELD probe first. On a healthy cycle the radio associates in a few
        # seconds, so this returns fast and we never hold the screensaver - normal
        # suspends stay exactly as before, months-class battery untouched.
        wifi_s=$(wait_for_wifi "$WIFI_PROBE_WAIT")
        wifi_ok=$?
        # If the radio did not reassociate, hard-cycle it and wait again, a few times
        # (the 2026-08-09 fix for a wedged adapter). Do this with the device HELD
        # AWAKE: taking the radio down inside wifi_reset releases the WLAN wakelock,
        # and without a hold powerd idle-suspends MID-recovery. On 2026-08-13 one such
        # uncontrolled mid-recovery suspend missed its wake for ~14h while the network
        # was up the whole time. The hold is BOUNDED - at most WIFI_RESET_TRIES x
        # WIFI_MAX_WAIT (~4 min) - and released the instant wifi is up or the bound is
        # hit, then the normal CONTROLLED suspend (arm_alarm + readback) runs. This is
        # never an open-ended awake loop; the awake-fallback pattern stays banned.
        if [ "$wifi_ok" -ne 0 ]; then
            wifi_diag_snapshot "probe-failed"
            screensaver_hold
            wifi_try=1
            while [ "$wifi_ok" -ne 0 ] && [ "$wifi_try" -le "$WIFI_RESET_TRIES" ]; do
                log "wifi not back after ${wifi_s}s; hard radio reset ($wifi_try/$WIFI_RESET_TRIES)"
                # Re-arm the same safety window used at the top of the cycle, every
                # retry. 2026-08-19: a single wait_for_wifi() call blocked ~18.5h
                # instead of its ~60s bound (an uncontrolled powerd suspend caught it
                # mid-call), and the only alarm covering the cycle was the one armed
                # once at cycle top, whose window had already elapsed - so the device
                # slept with nothing to wake it until a USB plug-in ended a ~19h dark
                # screen. Re-arming here means any uncontrolled suspend during a
                # retry is still bounded, not just the first ~25 minutes of the cycle.
                if arm_alarm $(( iv + SAFETY_GRACE )); then
                    log "safety alarm re-armed for $(( iv + SAFETY_GRACE ))s before wifi retry $wifi_try"
                else
                    log "WARN safety alarm could NOT be re-armed before wifi retry $wifi_try"
                fi
                wifi_reset
                extra=$(wait_for_wifi)
                wifi_ok=$?
                wifi_s=$((wifi_s + extra))
                [ "$wifi_ok" -ne 0 ] && wifi_diag_snapshot "retry${wifi_try}-failed"
                wifi_try=$((wifi_try + 1))
            done
            screensaver_release
            log "wifi recovery done: radio $([ "$wifi_ok" -eq 0 ] && echo up || echo 'still down') after ${wifi_s}s held (bounded)"
            [ "$wifi_ok" -ne 0 ] && wifi_diag_snapshot "gave-up"
        fi

        # Self-heal ladder bookkeeping: tracks CONSECUTIVE cycles where wifi
        # itself stayed down after every in-cycle retry above, separately from
        # `fails` below - a server-side outage with healthy wifi must never
        # trigger a wifi remedy. Escalation happens later, once this cycle's
        # outcome (and its push_log evidence) is logged.
        if [ "$wifi_ok" -ne 0 ]; then
            wifi_fails=$((wifi_fails + 1))
        else
            wifi_fails=0
        fi

        cycle_ok=1
        if [ "$wifi_ok" -ne 0 ]; then
            log "CYCLE n=$n batt=${batt:-none} wifi=FAIL(${wifi_s}s) fetch=skipped"
        else
            if [ "$draws" -eq 0 ]; then
                fetch_and_draw full
                rc=$?
            else
                fetch_and_draw
                rc=$?
            fi
            if [ "$rc" -eq 0 ]; then
                cycle_ok=0
                draws=$((draws + 1))
                [ "$draws" -ge "$FULL_REFRESH_EVERY" ] && draws=0
                if [ -n "$SERVED_INTERVAL" ]; then
                    iv="$SERVED_INTERVAL"; iv_src=served
                else
                    iv="$INTERVAL"; iv_src=default
                fi
                log "CYCLE n=$n batt=${batt:-none} wifi=${wifi_s}s fetch=ok interval=${iv}(${iv_src})"
                # First fully successful cycle (fetch ok + draw ok) since an update
                # was applied clears probation. Guarded on UPDATE_PROBATION_FILE so
                # this is a no-op on every ordinary cycle when nothing is pending.
                if [ -f "$UPDATE_PROBATION_FILE" ] && [ ! -f "$UPDATE_OK_FILE" ]; then
                    : > "$UPDATE_OK_FILE" 2>/dev/null
                    mv "$UPDATE_PROBATION_FILE" "$UPDATE_PROBATION_FILE.cleared" 2>/dev/null
                    log "update probation cleared: first successful cycle after update confirmed healthy"
                    push_log "update-confirmed-healthy" 15
                fi
                # First fully successful cycle of THIS process's lifetime: ship
                # anything the previous process wrote but never confirmed
                # delivered (see upload_backlog_if_any). Once only, ever, per
                # process - a restart-heavy stretch must not re-upload the same
                # backlog on every subsequent healthy cycle.
                if [ "$backlog_checked" -eq 0 ]; then
                    backlog_checked=1
                    upload_backlog_if_any
                fi
            else
                log "CYCLE n=$n batt=${batt:-none} wifi=${wifi_s}s fetch=FAIL"
            fi
            # The /api/display call ran (whether or not the image draw itself
            # succeeded), so CMD_ID reflects whatever the server had pending.
            apply_pending_command
        fi

        if [ "$cycle_ok" -ne 0 ]; then
            # A failed cycle means Wi-Fi or the fetch was down. Do NOT restore the
            # framework and do NOT stop. Handing the device back to powerd sleeps it
            # with no wake alarm and freezes the watchdog - that is exactly the
            # 2026-08-09 outage, where the loop quit after 3 Wi-Fi failures and the
            # screen stayed dark for 7 hours until a USB plug. Instead keep the last
            # good image, keep the takeover, and fall through to the normal suspend
            # path so the device sleeps the interval on battery and retries Wi-Fi on
            # the next wake. An extended Wi-Fi outage now costs cheap suspends, not a
            # dead display, and months-class battery is preserved.
            fails=$((fails + 1))
            log "cycle failed ($fails); wifi/fetch down, keeping last image, retry after suspend"
            [ $(( fails % 4 )) -eq 0 ] && wakelock_report
            # Suppressed when upload-full-log already sent this cycle's push (see
            # apply_pending_command) - that push already carries everything this
            # one would show, and firing both back-to-back is what made the
            # command's own (larger) push vanish on 2026-08-22.
            [ "$SKIP_NORMAL_PUSH" -eq 1 ] || push_log "cycle-failed" 20

            # Self-heal ladder: escalates ONLY on consecutive wifi-failed
            # cycles, never on the first one, and each check picks the single
            # strongest rung currently justified (elif, highest threshold
            # first) rather than cascading through all of them at once. Runs
            # here, BEFORE the suspend logic below, and every rung either
            # returns quickly or (rung3) hands off to a fresh process that
            # reaches the same suspend logic on its own - the interval and the
            # suspend path itself are never touched by any rung.
            if [ "$wifi_fails" -ge "$WIFI_LADDER_RUNG3_FAILS" ]; then
                wifi_ladder_rung3
            elif [ "$wifi_fails" -ge "$WIFI_LADDER_RUNG2_FAILS" ]; then
                wifi_ladder_rung2
            elif [ "$wifi_fails" -ge "$WIFI_LADDER_RUNG1_FAILS" ]; then
                wifi_ladder_rung1
            fi
        else
            fails=0
            [ "$SKIP_NORMAL_PUSH" -eq 1 ] || push_log "cycle-ok" 12
        fi

        # Small awake window so the loop can be stopped before it suspends.
        sleep "$KILL_WINDOW"

        # stay-awake command: self-expiring, checked fresh every cycle against a
        # plain epoch comparison. Nothing ever has to clear STAY_AWAKE_FILE - once
        # its value is in the past this block is simply skipped and normal
        # suspend.enabled behavior resumes on its own, which is what keeps this
        # from being able to strand the device awake and burn the battery.
        stay_awake_until=$(cat "$STAY_AWAKE_FILE" 2>/dev/null)
        case "$stay_awake_until" in
            ''|*[!0-9]*) stay_awake_until=0 ;;
        esac
        now_s=$(date +%s)
        if [ "$stay_awake_until" -gt "$now_s" ] 2>/dev/null; then
            screensaver_hold
            # Faster polling while a debug session is live: a command queued mid
            # stay-awake window (restart, another fetch-and-replace-script, upload
            # a log) lands within about a minute instead of waiting out the full
            # interval. Outside stay-awake this branch never runs, so ordinary
            # cycles are untouched.
            stay_awake_poll="$iv"
            [ "$stay_awake_poll" -gt 60 ] 2>/dev/null && stay_awake_poll=60
            log "stay-awake active, $((stay_awake_until - now_s))s remaining; plain sleep ${stay_awake_poll}s (fast-poll), device awake"
            awake_sleep "$stay_awake_poll"
            continue
        fi

        if [ ! -f "$SUSPEND_ENABLED" ]; then
            screensaver_hold
            log "suspend locked (no suspend.enabled); plain sleep ${iv}s, device awake"
            push_log "fallback-suspend-locked" 10
            awake_sleep "$iv"
            continue
        fi
        if [ "$suspend_fails" -ge "$MAX_FAILS" ]; then
            log "suspend abandoned this run ($suspend_fails/$MAX_FAILS failures); plain sleep ${iv}s, device awake"
            push_log "fallback-suspend-abandoned" 10
            awake_sleep "$iv"
            continue
        fi

        # Any hold from a previous awake fallback must go before we ask to suspend.
        screensaver_release
        # And the radio must go down, or its wakelock refuses the suspend outright.
        wifi_down
        sleep 3

        if ! arm_alarm "$iv"; then
            wifi_up
            suspend_fails=$((suspend_fails + 1))
            log "ERROR RTC alarm did not arm or read back ($suspend_fails/$MAX_FAILS); staying awake ${iv}s"
            push_log "alarm-failed" 20
            suspend_fallback_check
            awake_sleep "$iv"
            continue
        fi

        # A refusal is usually TRANSIENT, so do not give up on the first one.
        # 2026-08-05 08:56: 43 consecutive suspends had succeeded, then one was
        # refused with hwtcon_wakelock and cmdq_wakelock active - the e-ink
        # display controller and its command queue, held by our OWN redraw
        # moments earlier. Those clear within seconds. The old code treated that
        # single refusal as failure, dropped into the awake fallback, and the
        # device then froze there anyway (heartbeat counter advanced 30s while
        # the wall clock advanced an hour) and never recovered. Retrying costs
        # seconds and avoids the fallback path entirely.
        # Stamp liveness immediately before going under. The watchdog is frozen
        # with us and wakes to find this marker exactly one sleep old, which is
        # why WD_STALE has to exceed a whole interval rather than a cycle time.
        heartbeat
        # Sampled here, before the attempt, so a short-sleep event below can log
        # a before/after delta - a jump proves a real wakeup-IRQ source fired.
        wakeup_count_before=""
        [ -r /sys/power/wakeup_count ] && wakeup_count_before=$(cat /sys/power/wakeup_count 2>/dev/null)
        susp_try=1
        while [ "$susp_try" -le "$SUSPEND_RETRIES" ]; do
            # 2026-08-24: a device slept 36890s instead of a requested 900s
            # after this exact sequence - alarm armed cleanly, first suspend
            # write refused (EBUSY), a LATER retry then succeeded, and the
            # alarm never fired on schedule. Suspected mechanism: the refused
            # attempt itself consumes or clears the RTC's committed alarm
            # state even though the sysfs register still reads back the old
            # (now hardware-stale) value from before - so the retry that
            # actually succeeds can suspend with no real alarm behind it.
            # Verifying - and re-arming if needed - immediately before EVERY
            # attempt, not just once before the loop, means whichever attempt
            # actually succeeds always has a freshly-confirmed future alarm,
            # regardless of what a prior refusal may have done to it.
            current_alarm=$(cat "$RTC_ALARM" 2>/dev/null)
            now_check=$(date +%s)
            case "$current_alarm" in
                ''|*[!0-9]*) current_alarm=0 ;;
            esac
            if [ "$current_alarm" -le "$now_check" ] 2>/dev/null; then
                log "WARN RTC alarm register not future-dated before suspend attempt $susp_try/$SUSPEND_RETRIES (read back '$current_alarm'); re-arming before proceeding"
                if ! arm_alarm "$iv"; then
                    log "ERROR could not re-arm RTC alarm mid-retry ($susp_try/$SUSPEND_RETRIES); treating as a refused suspend rather than risking a suspend with no alarm behind it"
                    susp_try=$((SUSPEND_RETRIES + 1))
                    break
                fi
            fi
            do_suspend "$iv" && break
            if [ "$susp_try" -lt "$SUSPEND_RETRIES" ]; then
                log "suspend refused (attempt $susp_try/$SUSPEND_RETRIES); waiting ${SUSPEND_RETRY_WAIT}s for transient locks to clear"
                sleep "$SUSPEND_RETRY_WAIT"
            fi
            susp_try=$((susp_try + 1))
        done
        if [ "$susp_try" -gt "$SUSPEND_RETRIES" ]; then
            disarm_alarm
            wifi_up
            suspend_fails=$((suspend_fails + 1))
            log "ERROR suspend write refused ($suspend_fails/$MAX_FAILS); staying awake ${iv}s"
            wakelock_report
            push_log "suspend-refused" 25
            suspend_fallback_check
            awake_sleep "$iv"
            continue
        fi

        if suspend_held "$iv"; then
            # suspend_held() only ever checked a LOWER bound (slept >= 7/8 of
            # target) - it has no upper bound, so a device that overslept its
            # alarm by 40x (2026-08-24: 36890s instead of 900s) still reads as
            # a clean pass here, with nothing in the log to say otherwise.
            # Flag it loudly and capture the SAME diagnostics the too-short
            # path already gets - this path had zero evidence before now.
            if [ "$SLEPT" -gt $(( iv * SUSPEND_OVERSLEEP_MULT )) ] 2>/dev/null; then
                log "WARN suspend OVERSLEPT: slept ${SLEPT}s of ${iv}s requested ($(( SLEPT / iv ))x) - alarm likely did not fire on schedule; flagging as an anomaly, not a clean success"
                suspend_hold_diag_snapshot "$wakeup_count_before"
                push_log "suspend-overslept" 25
            fi
            suspend_fails=0
            log "WAKE n=$n slept=${SLEPT}s of ${iv}s"
        else
            # Diagnostics BEFORE disarm_alarm clears the RTC register, so its
            # value still reflects whatever state it was actually in at the
            # moment of the early wake (a fired alarm typically reads back
            # near-zero; a register still holding a FUTURE value means the
            # alarm we armed is not what woke this).
            suspend_hold_diag_snapshot "$wakeup_count_before"
            disarm_alarm
            suspend_fails=$((suspend_fails + 1))
            remain=$(( iv - SLEPT ))
            [ "$remain" -lt 1 ] && remain=1
            log "ERROR suspend did not hold: slept ${SLEPT}s of ${iv}s ($suspend_fails/$MAX_FAILS); staying awake ${remain}s"
            push_log "suspend-not-held" 25
            suspend_fallback_check
            awake_sleep "$remain"
        fi
    done
}

# Awake sleep with a redraw guard. When suspend is not running, the framework may
# still be alive (5.19.2 has no verified GUI stop yet) and repaints over the agenda
# whenever the device is touched. Sleeping in slices and re-blitting the last good
# image caps any cover-up at REDRAW_EVERY seconds. It also notices stop.flag in a
# slice instead of an interval. The suspend path never comes through here: a
# suspended device holds its image with no power and needs no guard.
awake_sleep() {   # $1 = total seconds
    # Any awake wait MUST hold off the screensaver, no exceptions. This used to be
    # called only after MAX_FAILS suspend failures, so the very first refused
    # suspend dropped us into a 3600s awake wait with nothing stopping powerd from
    # sleeping the device on its own. 2026-08-03 22:47:17 logged "staying awake
    # 3600s" and the loop never reached cycle 2: no crash, no stop line, just
    # silence, which is what a frozen process looks like. The hold is idempotent.
    screensaver_hold
    # ALARM NET (2026-08-11): the screensaver hold is advisory, not a guarantee.
    # On 2026-08-10 05:55 a suspend-did-not-hold drop into this fallback held the
    # screensaver, yet powerd suspended the device seconds later - with the cycle
    # alarm already disarmed, so NOTHING could wake it. 35-hour coma, ended only
    # by a USB plug. Every awake wait therefore arms its own RTC net covering the
    # full wait plus grace. If the device stays awake, the alarm fires while
    # awake and is a harmless no-op; the next cycle top re-arms over it either way.
    if ! arm_alarm "$(( $1 + 120 ))"; then
        log "WARN awake_sleep alarm net did not arm; a rogue suspend here cannot self-recover"
    fi
    left=$1
    total=$1
    since_beat=0
    # 2026-08-23: `left` only ever decrements by a fixed $chunk each iteration,
    # regardless of how much REAL wall-clock time that particular `sleep $chunk`
    # actually consumed. An uncontrolled suspend mid-chunk freezes the process;
    # once resumed (by this call's OWN alarm net above, exactly as designed),
    # `sleep` simply finishes its remaining monotonic seconds and `left` ticks
    # down normally - so the chunk counter can look completely healthy while
    # real time balloons far past $total. One such call absorbed ~1h44m of real
    # time this way (fetch/check-in cadence at a dead stop the whole time)
    # before this fix, against a requested wait of under 15 minutes. Bounding on
    # REAL elapsed wall-clock, not just the chunk counter, is what forces control
    # back to a full fetch+push+resuspend-retry cycle instead of silently
    # absorbing hours - the alarm net still catches each individual uncontrolled
    # suspend exactly as before; this only stops FURTHER chunks from starting
    # once the real-world budget for this whole call is already spent.
    wall_start=$(date +%s)
    wall_budget=$(( $1 * AWAKE_WALL_BUDGET_MULT + AWAKE_WALL_BUDGET_GRACE ))
    while [ "$left" -gt 0 ]; do
        chunk="$REDRAW_EVERY"
        [ "$left" -lt "$chunk" ] && chunk="$left"
        sleep "$chunk"
        left=$((left - chunk))
        # An awake wait is legitimate liveness, so keep the marker fresh or the
        # watchdog would restart a loop that is doing exactly what it should.
        heartbeat
        [ -f "$STOPFLAG" ] && return 0
        # Heartbeat: without it an awake wait is completely silent, so a loop that
        # dies mid-wait is indistinguishable from one that is waiting normally.
        # The log must be able to say how far it got.
        since_beat=$((since_beat + chunk))
        if [ "$since_beat" -ge "$HEARTBEAT_EVERY" ]; then
            since_beat=0
            log "awake heartbeat: $((total - left))s of ${total}s elapsed"
        fi
        if [ "$left" -gt 0 ] && [ -s "$OUT" ]; then
            draw "$OUT" >/dev/null 2>&1
        fi
        wall_elapsed=$(( $(date +%s) - wall_start ))
        if [ "$wall_elapsed" -ge "$wall_budget" ]; then
            log "WARN awake_sleep real wall-clock elapsed ${wall_elapsed}s vs requested ${total}s (budget ${wall_budget}s) - one or more uncontrolled suspends likely interrupted this wait; returning early to force a fetch+check-in+resuspend-retry cycle instead of continuing to absorb real time silently"
            push_log "fallback-wall-budget-exceeded" 15
            return 0
        fi
    done
    return 0
}

suspend_fallback_check() {
    [ "$suspend_fails" -ge "$MAX_FAILS" ] || return 0
    log "WARN $MAX_FAILS suspend failures in a row; suspend abandoned for this run, battery will be days not months"
    screensaver_hold
}

# ---------------------------------------------------------------- entrypoints

# Resolved once, for every branch. $0 is relative ("./bin/calendar.sh") when KUAL
# invokes us, and a detached child cannot rely on inheriting a working directory
# that survives its parent - a relative path here is a way to launch nothing at
# all. The watchdog relaunches the loop by this path, so it has to be correct in
# the watchdog's context too, not only inside `start`.
SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null)
if [ -z "$SCRIPT_PATH" ] || [ ! -f "$SCRIPT_PATH" ]; then
    case "$0" in
        /*) SCRIPT_PATH="$0" ;;
        *)  SCRIPT_PATH="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")" ;;
    esac
fi

# Self-healing update check. Runs before ANYTHING entrypoint-specific, on every
# single invocation (start, __loop, __watchdog relaunch, once, probe, ...), so a
# script that is itself broken still hits this first. If it decides to revert, it
# execs the reverted file and never returns here.
check_update_probation "$@"

# Reported on every push_log call so the server can confirm a fetch-and-replace-script
# update actually applied: bump SCRIPT_VERSION by hand on future edits, and the md5
# is read fresh off disk here so it always reflects whatever is CURRENTLY running,
# including a script that was just swapped in by apply_script_update.
SCRIPT_VERSION="${TRMNL_SCRIPT_VERSION:-2026-08-24.1}"
SCRIPT_MD5=""
if [ -n "$SCRIPT_PATH" ] && [ -r "$SCRIPT_PATH" ] && command -v md5sum >/dev/null 2>&1; then
    SCRIPT_MD5=$(md5sum "$SCRIPT_PATH" 2>/dev/null | awk '{print $1}')
fi

case "$1" in
    once)
        # Deliberately does not take the screen over, so this is safe to test with.
        sleep "$FIRST_DRAW_DELAY"
        fetch_and_draw full
        ;;
    suspendtest-takeover)
        suspend_test_takeover "$2"
        ;;
    __suspendtest_takeover)
        trap '' HUP
        takeover_begin
        sleep 2
        suspend_test "${2:-120}"
        rc=$?
        log "SUSPENDTEST-TAKEOVER rc=$rc (compare against a plain suspendtest run)"
        wakelock_report
        push_log "suspendtest-takeover-verdict" 40
        ;;
    suspendtest)
        suspend_test "$2"
        ;;
    probe)
        sleep "$FIRST_DRAW_DELAY"
        probe_report
        ;;
    ruler)
        sleep "$FIRST_DRAW_DELAY"
        show_ruler
        ;;
    __watchdog)
        # Internal: the watchdog process. Separate from the loop on purpose - the
        # thing that restarts a dead loop cannot live inside it.
        #
        # Kept deliberately stupid. It sleeps, reads one integer, compares it, and
        # in the bad case kills and relaunches. No network, no drawing, no
        # subshells that can block. Anything clever in here is another thing that
        # can wedge, and then nothing is watching at all.
        trap '' HUP
        echo $$ > "$WDPIDFILE"
        wdlog "watchdog started pid $$ poll=${WD_POLL}s stale=${WD_STALE}s"
        wd_restarts=0
        while :; do
            sleep "$WD_POLL"
            if [ -f "$STOPFLAG" ] || [ -f "$STOPFLAG.done" ]; then
                wdlog "stop flag present; watchdog exiting"
                exit 0
            fi
            hb=$(cat "$HBFILE" 2>/dev/null)
            case "$hb" in
                ''|*[!0-9]*)
                    wdlog "heartbeat unreadable ('$hb'); waiting for the loop to write one"
                    continue ;;
            esac
            now_s=$(date +%s)
            age=$((now_s - hb))
            [ "$age" -lt 0 ] && age=0     # clock stepped backwards; not a stall
            if [ "$age" -le "$WD_STALE" ]; then
                continue
            fi

            wd_restarts=$((wd_restarts + 1))
            wdlog "heartbeat ${age}s old (limit ${WD_STALE}s) - loop is not running; restart #$wd_restarts"
            # Report BEFORE touching anything. push_log needs the radio, and a
            # restart may take the radio down; the existing suspend-refused path
            # already loses its message that way. Say it while we still can.
            wifi_up >/dev/null 2>&1
            push_log "watchdog-restart" 30
            echo "watchdog-stale-heartbeat age=${age}s restarts=$wd_restarts at=$(date +%s)" > "$RESTART_REASON_FILE" 2>/dev/null

            oldpid=$(cat "$PIDFILE" 2>/dev/null)
            if [ -n "$oldpid" ]; then
                kill -- "-$oldpid" 2>/dev/null || kill "$oldpid" 2>/dev/null
            fi
            pkill -f "calendar.sh __loop" >/dev/null 2>&1
            sleep 2
            heartbeat      # give the new loop a full window before judging it
            setsid /bin/sh "$SCRIPT_PATH" __loop </dev/null >/dev/null 2>&1 &
            wdlog "relaunched loop"
        done
        ;;
    __loop)
        # Internal: the detached loop process itself. Immune to SIGHUP so KUAL's
        # session teardown can never take it down, and it records its OWN pid -
        # the pid in the file is always the process stop must kill, never a wrapper.
        trap '' HUP
        echo $$ > "$PIDFILE"
        detect_backup_rtc
        log_power_diagnostics
        log "startup version=${SCRIPT_VERSION:-unknown} script_md5=${SCRIPT_MD5:-unknown}"
        # Why did the PREVIOUS process end? Known triggers (script update,
        # server restart command, watchdog-detected stale heartbeat, the wifi
        # self-heal ladder's rung3) each write RESTART_REASON_FILE just before
        # ending themselves, since a dead/replaced process cannot explain
        # itself after the fact - this is what turns the next outage into a
        # same-day diagnosis instead of a multi-day wait for it to recur.
        restart_reason=$(cat "$RESTART_REASON_FILE" 2>/dev/null)
        if [ -n "$restart_reason" ]; then
            log "startup previous-process-ended reason: $restart_reason"
            mv "$RESTART_REASON_FILE" "$RESTART_REASON_FILE.last" 2>/dev/null
        else
            log "startup previous-process-ended reason: unknown (no marker found - unclean stop, power loss, or first-ever start)"
        fi
        # A respawn (from apply_script_update or the restart command) can leave an
        # ack still owed to the server - the OLD process may have died before its
        # push_log call went out. Pick it back up here so the ack is not lost.
        pending_ack=$(cat "$PENDING_ACK_FILE" 2>/dev/null)
        if [ -n "$pending_ack" ]; then
            ACK_ID="$pending_ack"
            log "resuming owed ack for command id=$ACK_ID after restart"
        fi
        # The takeover MUST happen here, inside the detached child, never in the
        # parent. takeover_begin stops the framework, and the framework is what
        # runs KUAL, which is the parent of the launching script. On 2026-08-03 the
        # parent called it first and killed itself mid-launch: the device log shows
        # "taking over screen" and then nothing at all, not even the dead-launch
        # error below, and the framework stayed down so KUAL reported "Application
        # Error: the selected application could not be started". By the time we get
        # here we are already in our own session, so stopping the framework cannot
        # reach us.
        takeover_begin
        main_loop
        ;;
    start)
        # A pid file alone is not proof the loop is running: stop cannot delete it
        # (no rm on this system, ever), and after a device restart the pid can be
        # reused by an unrelated process. kill -0 alone made Start a silent no-op
        # in exactly that state. So the pid only counts when /proc says it is
        # actually this script's loop.
        if [ -f "$PIDFILE" ]; then
            oldpid=$(cat "$PIDFILE" 2>/dev/null)
            if [ -n "$oldpid" ] && [ -d "/proc/$oldpid" ] && \
               grep -q "calendar.sh" "/proc/$oldpid/cmdline" 2>/dev/null; then
                log "loop already running (pid $oldpid)"
                exit 0
            fi
            mv "$PIDFILE" "$PIDFILE.stale" 2>/dev/null
            log "cleared stale loop.pid (pid ${oldpid:-empty} is not our loop)"
            # Not a full explanation - just what's knowable from here: the
            # previous loop vanished without any of the normal shutdown paths
            # (stop, script-update, restart command, watchdog) getting a chance
            # to record why. Better than a silent "unknown" at the next
            # startup, which would read as no information at all.
            echo "manual-start-after-stale-pid oldpid=${oldpid:-unknown} at=$(date +%s)" > "$RESTART_REASON_FILE" 2>/dev/null
        fi
        # Detach the loop from KUAL's session entirely FIRST, and let the detached
        # child do the takeover. Order matters: see the note in __loop above.
        # SCRIPT_PATH must be absolute. $0 is relative ("./bin/calendar.sh") when
        # KUAL invokes us, and the detached child cannot rely on inheriting a
        # working directory that survives its parent, so a relative path here is a
        # second way to launch nothing at all.
        SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null)
        if [ -z "$SCRIPT_PATH" ] || [ ! -f "$SCRIPT_PATH" ]; then
            case "$0" in
                /*) SCRIPT_PATH="$0" ;;
                *)  SCRIPT_PATH="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")" ;;
            esac
        fi
        if [ ! -f "$SCRIPT_PATH" ]; then
            log "ERROR cannot resolve own path (\$0=$0); refusing to launch"
            exit 1
        fi
        mv "$PIDFILE" "$PIDFILE.prev" 2>/dev/null
        if command -v setsid >/dev/null 2>&1; then
            setsid /bin/sh "$SCRIPT_PATH" __loop </dev/null >/dev/null 2>&1 &
        else
            /bin/sh "$SCRIPT_PATH" __loop </dev/null >/dev/null 2>&1 &
        fi
        # Wait for the child to announce itself so the started log line is truthful.
        tries=0
        while [ ! -f "$PIDFILE" ] && [ "$tries" -lt 50 ]; do
            sleep 0.1 2>/dev/null || sleep 1
            tries=$((tries + 1))
        done
        if [ -f "$PIDFILE" ]; then
            log "loop started pid $(cat "$PIDFILE") fallback_interval ${INTERVAL}s suspend=$([ -f "$SUSPEND_ENABLED" ] && echo enabled || echo locked)"

        # Start the watchdog only once the loop is really up, and seed the
        # heartbeat first so it cannot judge a loop that has not had a chance to
        # write one yet. Any previous watchdog is killed: two of them would fight
        # over restarts.
        heartbeat
        pkill -f "calendar.sh __watchdog" >/dev/null 2>&1
        # Mirrors the PIDFILE handling above. Without this, a WDPIDFILE left over
        # from BEFORE a reboot already exists on disk, so the readiness-wait loop
        # below (which only checks "does the file exist") passes immediately and
        # reads that STALE pid instead of waiting for the new watchdog to write
        # its own - confirmed on-device 2026-08-22 (announced pid 10359, the
        # watchdog's own self-announcement said 7505).
        mv "$WDPIDFILE" "$WDPIDFILE.prev" 2>/dev/null
        if command -v setsid >/dev/null 2>&1; then
            setsid /bin/sh "$SCRIPT_PATH" __watchdog </dev/null >/dev/null 2>&1 &
        else
            /bin/sh "$SCRIPT_PATH" __watchdog </dev/null >/dev/null 2>&1 &
        fi
        wtries=0
        while [ ! -f "$WDPIDFILE" ] && [ "$wtries" -lt 50 ]; do
            sleep 0.1 2>/dev/null || sleep 1
            wtries=$((wtries + 1))
        done
        if [ -f "$WDPIDFILE" ]; then
            log "watchdog started pid $(cat "$WDPIDFILE") poll=${WD_POLL}s stale=${WD_STALE}s"
        else
            # Worth saying loudly: the loop still runs, but unattended recovery
            # is exactly what we just built, and silently not having it is how
            # the display ends up dark for four hours again.
            log "ERROR watchdog did not start; loop is UNSUPERVISED"
        fi
        push_log "loop-started" 20
        else
            log "ERROR loop did not announce a pid within 5s; check for a dead launch"
        fi
        ;;
    stop)
        # THE WATCHDOG DIES FIRST, before the loop is touched. Kill the loop while
        # the watchdog is still alive and it does precisely what it was built to
        # do - spots a dead loop and starts a fresh one - so Stop would look like
        # it did nothing at all.
        if [ -f "$WDPIDFILE" ]; then
            wdpid=$(cat "$WDPIDFILE" 2>/dev/null)
            if [ -n "$wdpid" ]; then
                kill -- "-$wdpid" 2>/dev/null || kill "$wdpid" 2>/dev/null
            fi
            mv "$WDPIDFILE" "$WDPIDFILE.last" 2>/dev/null
        fi
        pkill -f "calendar.sh __watchdog" >/dev/null 2>&1

        if [ -f "$PIDFILE" ]; then
            stoppid=$(cat "$PIDFILE" 2>/dev/null)
            if [ -n "$stoppid" ]; then
                # The loop is a session leader (setsid), so kill the whole group:
                # that takes out an in-flight external sleep as well. Fall back to
                # the single pid when group kill is unsupported.
                kill -- "-$stoppid" 2>/dev/null || kill "$stoppid" 2>/dev/null
            fi
            mv "$PIDFILE" "$PIDFILE.last" 2>/dev/null
            echo "admin-stop-command pid=${stoppid:-unknown} at=$(date +%s)" > "$RESTART_REASON_FILE" 2>/dev/null
        fi
        # Belt and braces: current loops match __loop; pre-2026-08-03 ones match start.
        pkill -f "calendar.sh __loop" >/dev/null 2>&1
        pkill -f "calendar.sh start" >/dev/null 2>&1
        disarm_alarm    # the safety alarm must not wake a device we just stopped
        takeover_end
        log "stopped"
        ;;
    *)
        echo "usage: calendar.sh once|suspendtest [seconds]|start|stop|probe|ruler"
        exit 1
        ;;
esac
