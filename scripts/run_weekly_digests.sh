#!/bin/bash
# Career-Ops Weekly Digest Runner
# Runs every Friday via cron.
# Step 1: Claude agent does web searches and writes HTML to /tmp/
# Step 2: Python sends HTML via SMTP using SentientEdge credentials

LOG="/tmp/career_ops_weekly.log"
CLAUDE="/opt/homebrew/bin/claude"
PYTHON="/opt/homebrew/bin/python3"
DIR="/Users/bobkatz/Career-Ops"
ENV_FILE="/Users/bobkatz/Stock_Recommender_Projects/SentientEdge_v2/backend/.env"

# Keychain access requires these vars — SSH_AUTH_SOCK path is dynamic per boot
export __CF_USER_TEXT_ENCODING="0x1F5:0x0:0x0"
export SSH_AUTH_SOCK=$(launchctl getenv SSH_AUTH_SOCK 2>/dev/null || ls /var/run/com.apple.launchd.*/Listeners 2>/dev/null | head -1)
export HOME="/Users/bobkatz"
export USER="bobkatz"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# Direct Telegram Bot API push — independent of Claude/MCP so it works in cron.
# Reads token + chat_id from the telegram channel config at runtime (no secrets in this file).
TG_ENV="/Users/bobkatz/.claude/channels/telegram/.env"
TG_ACCESS="/Users/bobkatz/.claude/channels/telegram/access.json"
telegram_alert() {
    local text="$1"
    local token chat_id
    [ -f "$TG_ENV" ] || { log "telegram_alert: $TG_ENV missing, skipping push"; return; }
    token=$(grep '^TELEGRAM_BOT_TOKEN=' "$TG_ENV" | cut -d= -f2- | tr -d '"' | tr -d "'")
    chat_id=$("$PYTHON" -c "import json;print(json.load(open('$TG_ACCESS'))['allowFrom'][0])" 2>/dev/null)
    if [ -z "$token" ] || [ -z "$chat_id" ]; then
        log "telegram_alert: token or chat_id unavailable, skipping push"
        return
    fi
    curl -s --max-time 15 "https://api.telegram.org/bot${token}/sendMessage" \
        --data-urlencode "chat_id=${chat_id}" \
        --data-urlencode "text=${text}" \
        -o /dev/null && log "telegram_alert: push sent" || log "telegram_alert: curl failed"
}

# Run a claude -p search, retrying if the expected HTML output isn't produced.
# Long headless sessions occasionally die mid-stream ("Connection closed
# mid-response") and take the whole run with them; a single drop shouldn't
# skip the week. Args: <label> <prompt-file> <expected-html-path>
run_search_with_retry() {
    local label="$1" prompt_file="$2" out_file="$3"
    local max_attempts=3 attempt=1
    while [ "$attempt" -le "$max_attempts" ]; do
        log "$label: search attempt $attempt/$max_attempts..."
        rm -f "$out_file"
        "$CLAUDE" -p "$(cat "$prompt_file")" \
            --allowedTools WebSearch,Write,Bash \
            >> "$LOG" 2>&1
        if [ -f "$out_file" ]; then
            log "$label: HTML generated on attempt $attempt"
            return 0
        fi
        log "$label: attempt $attempt produced no HTML"
        if [ "$attempt" -lt "$max_attempts" ]; then
            log "$label: backing off 60s before retry..."
            sleep 60
        fi
        attempt=$((attempt + 1))
    done
    log "$label: all $max_attempts attempts failed to generate HTML"
    return 1
}

log "=== Career-Ops weekly digest starting ==="

cd "$DIR"

# ── Rachel ──────────────────────────────────────────────────────────────
log "Rachel: running web search..."
run_search_with_retry "Rachel" scripts/rachel_search.md /tmp/rachel_digest_local.html

if [ ! -f /tmp/rachel_digest_local.html ]; then
    log "ERROR: Rachel HTML not generated — search may have failed"
    telegram_alert "⚠️ Career-Ops: Rachel digest FAILED on $(date '+%Y-%m-%d') — HTML not generated (search likely errored). Check /tmp/career_ops_weekly.log"
    "$PYTHON" - << PYEOF
import smtplib
from pathlib import Path
from email.mime.text import MIMEText
env = {}
for line in Path("$ENV_FILE").read_text().splitlines():
    if "=" in line and not line.strip().startswith("#"):
        k, _, v = line.partition("=")
        env[k.strip()] = v.strip()
u = env.get("SMTP_USER","rjkatz@gmail.com"); p = env.get("SMTP_PASS","")
m = MIMEText("ERROR: Rachel digest HTML was not generated. Check $LOG")
m["From"]=u; m["To"]="alerts@factservices.com"; m["Subject"]="[Career-Ops] Rachel digest FAILED"
with smtplib.SMTP("smtp.gmail.com",587) as s: s.starttls(); s.login(u,p); s.sendmail(u,"alerts@factservices.com",m.as_string())
PYEOF
else
    log "Rachel: HTML ready, sending email..."
    "$PYTHON" - << PYEOF
import smtplib, sys
from pathlib import Path
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from datetime import date

env = {}
for line in Path("$ENV_FILE").read_text().splitlines():
    if "=" in line and not line.strip().startswith("#"):
        k, _, v = line.partition("=")
        env[k.strip()] = v.strip()

u = env.get("SMTP_USER","rjkatz@gmail.com"); p = env.get("SMTP_PASS","")
today = date.today().strftime("%B %-d, %Y")
html = Path("/tmp/rachel_digest_local.html").read_text()

msg = MIMEMultipart("alternative")
msg["From"]=u; msg["To"]="rachlkatz13@gmail.com"; msg["Bcc"]=u
msg["Subject"]=f"Your Weekly Job Leads — {today}"
msg.attach(MIMEText("Please enable HTML to view this email.","plain"))
msg.attach(MIMEText(html,"html"))
try:
    with smtplib.SMTP("smtp.gmail.com",587) as s:
        s.starttls(); s.login(u,p)
        s.sendmail(u,["rachlkatz13@gmail.com",u],msg.as_string())
    print(f"SENT: Rachel digest -> rachlkatz13@gmail.com")
except Exception as e:
    print(f"ERROR: Rachel send failed: {e}", file=sys.stderr)
    sys.exit(1)

ping = MIMEText(f"Rachel Katz job digest sent successfully on {today}.")
ping["From"]=u; ping["To"]="alerts@factservices.com"; ping["Subject"]="[Career-Ops] Rachel digest sent"
try:
    with smtplib.SMTP("smtp.gmail.com",587) as s:
        s.starttls(); s.login(u,p); s.sendmail(u,"alerts@factservices.com",ping.as_string())
    print("PING: alerts@factservices.com notified")
except Exception as e:
    print(f"WARN: Rachel success-ping failed (digest was sent): {e}", file=sys.stderr)
PYEOF
    if [ $? -ne 0 ]; then
        log "ERROR: Rachel digest SEND failed"
        telegram_alert "⚠️ Career-Ops: Rachel digest SEND FAILED on $(date '+%Y-%m-%d') — HTML generated but email did not go out. Check /tmp/career_ops_weekly.log"
    fi
    log "Rachel: done"
fi

# Zeynel is running Career-Ops locally on his own machine — removed 2026-05-26

# ── Bob ──────────────────────────────────────────────────────────────────
log "Bob: running web search..."
run_search_with_retry "Bob" scripts/bob_search.md /tmp/bob_digest_local.html

if [ ! -f /tmp/bob_digest_local.html ]; then
    log "ERROR: Bob digest HTML not generated — search may have failed"
    telegram_alert "⚠️ Career-Ops: Bob digest FAILED on $(date '+%Y-%m-%d') — HTML not generated (search likely errored). Check /tmp/career_ops_weekly.log"
    "$PYTHON" - << PYEOF
import smtplib
from pathlib import Path
from email.mime.text import MIMEText
env = {}
for line in Path("$ENV_FILE").read_text().splitlines():
    if "=" in line and not line.strip().startswith("#"):
        k, _, v = line.partition("=")
        env[k.strip()] = v.strip()
u = env.get("SMTP_USER","rjkatz@gmail.com"); p = env.get("SMTP_PASS","")
m = MIMEText("ERROR: Bob digest HTML was not generated. Check $LOG")
m["From"]=u; m["To"]="alerts@factservices.com"; m["Subject"]="[Career-Ops] Bob digest FAILED"
with smtplib.SMTP("smtp.gmail.com",587) as s: s.starttls(); s.login(u,p); s.sendmail(u,"alerts@factservices.com",m.as_string())
PYEOF
else
    log "Bob: HTML ready, sending email..."
    "$PYTHON" - << PYEOF
import smtplib, sys
from pathlib import Path
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from datetime import date

env = {}
for line in Path("$ENV_FILE").read_text().splitlines():
    if "=" in line and not line.strip().startswith("#"):
        k, _, v = line.partition("=")
        env[k.strip()] = v.strip()

u = env.get("SMTP_USER","rjkatz@gmail.com"); p = env.get("SMTP_PASS","")
today = date.today().strftime("%B %-d, %Y")
html = Path("/tmp/bob_digest_local.html").read_text()

msg = MIMEMultipart("alternative")
msg["From"]=u; msg["To"]="alerts@factservices.com"
msg["Subject"]=f"Your Weekly Contract & Consulting Leads — {today}"
msg.attach(MIMEText("Please enable HTML to view this email.","plain"))
msg.attach(MIMEText(html,"html"))
try:
    with smtplib.SMTP("smtp.gmail.com",587) as s:
        s.starttls(); s.login(u,p)
        s.sendmail(u,"alerts@factservices.com",msg.as_string())
    print(f"SENT: Bob digest -> alerts@factservices.com")
except Exception as e:
    print(f"ERROR: Bob send failed: {e}", file=sys.stderr)
    sys.exit(1)

ping = MIMEText(f"Bob Katz consulting digest sent successfully on {today}.")
ping["From"]=u; ping["To"]="alerts@factservices.com"; ping["Subject"]="[Career-Ops] Bob digest sent"
try:
    with smtplib.SMTP("smtp.gmail.com",587) as s:
        s.starttls(); s.login(u,p); s.sendmail(u,"alerts@factservices.com",ping.as_string())
    print("PING: alerts@factservices.com notified")
except Exception as e:
    print(f"WARN: Bob success-ping failed (digest was sent): {e}", file=sys.stderr)
PYEOF
    if [ $? -ne 0 ]; then
        log "ERROR: Bob digest SEND failed"
        telegram_alert "⚠️ Career-Ops: Bob digest SEND FAILED on $(date '+%Y-%m-%d') — HTML generated but email did not go out. Check /tmp/career_ops_weekly.log"
    fi
    log "Bob: done"
fi

log "=== Career-Ops weekly digest complete ==="
