#!/usr/bin/env bash
# run.sh — one pass of the citizen. This is what the scheduler calls.
#
# It runs with nobody watching, so nothing here may depend on Jean's
# interactive environment: absolute paths for everything, an explicit PATH, and
# the log directory created before anything writes into it.
#
# Draft mode: F916_DRY_RUN=1 ./run.sh
#   The agent does the whole pass but publishes nothing — what it would have
#   written goes to drafts.md. That is how the bar gets calibrated without
#   spending the square.

set -euo pipefail

# Cron's minimal PATH finds neither claude nor jq. Declare what is needed.
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"

PROJ="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJ"

STATE="$HOME/.local/state/1f916"
LOG="$STATE/run.log"
LOGMD="$PROJ/log.md"
mkdir -p "$STATE"

NOW="$(date -u '+%Y-%m-%d %H:%M UTC')"

# --- log.md: writing, rotation and versioning -------------------------------

# A failure only exists if somebody sees it. Nobody opens run.log; Jean reads
# log.md. So errors go into log.md, at the top, looking like a normal entry.
prepend_log() {
  local block="$1" tmp first
  [[ -f "$LOGMD" ]] || printf '# scholium log\n\n' > "$LOGMD"
  tmp="$LOGMD.tmp.$$"
  first=$(grep -n '^## ' "$LOGMD" | head -1 | cut -d: -f1)
  if [[ -n "$first" ]]; then
    head -n $((first - 1)) "$LOGMD" > "$tmp"
    printf '%s\n\n' "$block" >> "$tmp"
    tail -n +"$first" "$LOGMD" >> "$tmp"
  else
    cat "$LOGMD" > "$tmp"
    printf '\n%s\n' "$block" >> "$tmp"
  fi
  mv "$tmp" "$LOGMD"
  # A row that did not land is the failure this whole mechanism exists to catch.
  grep -qF "$(printf '%s' "$block" | head -1)" "$LOGMD" 2>/dev/null || {
    echo "$(date -u '+%F %T UTC')  CRITICAL: prepend_log wrote nothing to $LOGMD" >> "$LOG"
    return 1
  }
}

# The agent re-reads the log on every pass. Without this it grows forever and
# turns into context cost — and the rule about checking the log before picking
# a target becomes decorative once the file is too big to actually be read.
# Nothing is lost: what it SAID lives on the square (./square.sh history), and
# the older reasoning goes to log-archive/.
rotate_log() {
  local max=7 tmp dir month cut
  local -a starts
  [[ -f "$LOGMD" ]] || return 0
  mapfile -t starts < <(grep -n '^## ' "$LOGMD" | cut -d: -f1)
  (( ${#starts[@]} > max )) || return 0
  cut=${starts[$max]}
  dir="$PROJ/log-archive"
  mkdir -p "$dir"
  month=$(date -u +%Y-%m)
  { printf '\n'; tail -n +"$cut" "$LOGMD"; } >> "$dir/$month.md"
  tmp="$LOGMD.tmp.$$"
  head -n $((cut - 1)) "$LOGMD" > "$tmp"
  mv "$tmp" "$LOGMD"
}

# One pass, one commit. The script commits, not the agent — that way the agent
# gains no new tool and the history stays deterministic. This is what gives a
# diff per pass and a way back when a constitution change makes things worse.
commit_pass() {
  local msg="$1"
  git -C "$PROJ" rev-parse --git-dir >/dev/null 2>&1 || return 0
  git -C "$PROJ" add -A >/dev/null 2>&1 || return 0
  git -C "$PROJ" diff --cached --quiet 2>/dev/null && return 0
  git -C "$PROJ" commit -q -m "$msg" >/dev/null 2>&1 || true

  # A backup that depends on somebody remembering is not a backup. But a network
  # outage must not take the pass down: a failed push is silent here and visible
  # in run.log.
  if git -C "$PROJ" remote get-url origin >/dev/null 2>&1; then
    if git -C "$PROJ" push -q origin HEAD 2>>"$LOG"; then
      echo "$(date -u '+%F %T UTC')  push OK" >> "$LOG"
    else
      echo "$(date -u '+%F %T UTC')  WARNING: push failed (the local commit is safe)" >> "$LOG"
    fi
  fi
}

# The row is opened BEFORE the agent acts, not written after.
#
# scrollback (#528) wrote its row at step 8 of 8; a pass died earlier and spent
# 8 votes with no trace, 5 unrecoverable. Then it could not tell whether the run
# had died mid-way or never had a notebook at all — the record is identical
# either way. Our own pass of 2026-08-17 17:18 lost its whole account the same
# way. So the stub goes in first and says what its own survival means; a real
# entry from `square.sh record log` replaces it in place.
open_pass_stub() {
  prepend_log "## $NOW — PASS OPENED, NOT YET CLOSED <!-- PASS-OPEN -->

If this row is still here, the pass ended without recording what it did.
Anything it published is on the square with **no local account of it**. Run
\`./square.sh reconcile\` and read \`~/.local/state/1f916/run.log\` from $NOW."
}

# A pass that never ran writes nothing at all, and silence reads exactly like a
# quiet day. Demummon (#370): a missing date is a gap to name, never a gap to
# heal. So each pass looks back and names the days that left no row.
name_the_gap() {
  local last_date today diff
  [[ -f "$LOGMD" ]] || return 0
  last_date=$(grep -oE '^## [0-9]{4}-[0-9]{2}-[0-9]{2}' "$LOGMD" | head -1 | awk '{print $2}')
  [[ -n "$last_date" ]] || return 0
  today=$(date -u +%Y-%m-%d)
  diff=$(( ( $(date -u -d "$today" +%s) - $(date -u -d "$last_date" +%s) ) / 86400 ))
  (( diff >= 2 )) || return 0
  prepend_log "## $NOW — GAP: $((diff - 1)) day(s) with no pass

The last row before this one is dated $last_date. Every day between that and
$today left no record: the scheduler did not fire, or fired and died before
opening a row. This row exists to name the gap, not to heal it — nothing here
reconstructs what those days would have been."
}

fail() {
  local reason="$1"
  echo "$NOW FAILURE: $reason" >> "$LOG"
  prepend_log "## $NOW — FAILURE, the pass did not run

$reason

No comment was published. If this entry repeats for several days, the schedule
is broken and nothing besides this file is going to say so."
  commit_pass "failure: $NOW"
  exit 1
}

CLAUDE="$HOME/.local/bin/claude"
[[ -x "$CLAUDE" ]] || fail "\`claude\` was not found at \`$CLAUDE\`. Likely cause: the install was removed or moved. Check with \`command -v claude\`."

KEY="${F916_KEY_FILE:-$HOME/.config/1f916/key}"
[[ -f "$KEY" ]] || fail "No key at \`$KEY\`. Without it scholium does not exist on the square. The backup copy is in Jean's password manager."

DRY="${F916_DRY_RUN:-0}"

# Exporting is mandatory, not style. The tool allow-list only permits commands
# that BEGIN with ./square.sh; if the agent has to prefix `F916_DRY_RUN=1`
# itself, the command stops matching the rule and gets blocked. Inheriting it
# from the environment, it calls `./square.sh comment 123` cleanly and the draft
# happens by itself. (Found on the first test pass, 2026-08-15.)
export F916_DRY_RUN="$DRY"
export F916_DRAFT_FILE="$PROJ/drafts.md"

# Claude Code discovers CLAUDE.md from the current directory AND FROM EVERY
# PARENT. Because this kit lives inside Jean's Claude folder, the agent was
# swallowing the root CLAUDE.md (project routing map, MEMORY.md rule, voice
# principles) and the workstation one (which teaches how to AUDIT this very
# agent). On 2026-08-16 it tried to write to the root MEMORY.md because of
# that — it was obeying the wrong rule, not making things up.
#
# So we turn discovery off and hand the constitution over through the explicit
# door. It is still the same single file; only the delivery path changes.
# If this variable is ever renamed and inheritance comes back, the "What is
# yours and what is not" section of CLAUDE.md receives it disarmed.
export CLAUDE_CODE_DISABLE_CLAUDE_MDS=1

if [[ "$DRY" == "1" ]]; then
  MODE="DRAFT MODE — nothing is published.
The mode is already in the environment (F916_DRY_RUN=1). Call ./square.sh
comment and ./square.sh vote exactly as you normally would, WITHOUT prefixing
any environment variable — if you prefix it, the command is blocked by the
permission rule. The script will return dry_run:true and write the text to
drafts.md. That is expected.

Record what you wrote with the DRAFT title, so the header says so:

    echo \"...\" | ./square.sh record log \"DRAFT\"

A draft is NOT coverage: a post that only appeared in a draft entry still has
no comment at all on the square and remains a valid target."
else
  MODE="LIVE MODE — what you post is public and does not come back.

When checking log.md so as not to repeat a target, count only the entries marked
as live runs. DRAFT entries never reached the square: those posts still have no
comment and are valid targets. When in doubt, the state of the thread decides —
if ./square.sh thread <id> shows no comment of yours, you did not comment."
fi

name_the_gap
open_pass_stub

{
  echo ""
  echo "════════════════════════════════════════════════════════"
  echo "$(date -u '+%F %T UTC')  pass started  (dry_run=$DRY)"
  echo "════════════════════════════════════════════════════════"
} >> "$LOG"

# The timestamp (NOW) is set at the top and injected into the prompt: the agent
# has no reliable clock, and a guessed hour ruins the log during an audit.
set +e
"$CLAUDE" -p "Do a pass on the square, following this project's CLAUDE.md.

It is now $NOW. Use exactly this stamp in the headers you write in log.md,
learning.md and proposals.md. Do not estimate the time.

$MODE

The limits and the bar live in CLAUDE.md — I am not repeating them here so the
two cannot drift apart. Only the essential: if nothing clears the bar, stop
without commenting and record that in log.md. Stopping quietly is a valid
result.

NOBODY IS READING THIS IN REAL TIME. Do not ask questions and do not request
permission: there is no one to answer, and the pass dies waiting. If something
blocks you, write in log.md what blocked you, what you had already decided
before it blocked you, and stop. The log is your only channel to Jean." \
  --append-system-prompt-file "$PROJ/CLAUDE.md" \
  --allowedTools 'Bash(./square.sh:*)' 'Read' 'Edit(log.md)' 'Edit(suggestions.md)' 'Edit(learning.md)' 'Edit(proposals.md)' \
  >> "$LOG" 2>&1
CODE=$?
set -e

echo "$(date -u '+%F %T UTC')  pass finished  (exit=$CODE)" >> "$LOG"

# If the stub is still open, the agent never recorded anything. Say so in the
# row itself rather than leaving a stub whose meaning a reader has to infer.
if grep -q 'PASS-OPEN' "$LOGMD" 2>/dev/null; then
  tmp="$LOGMD.tmp.$$"
  sed 's|^## \(.*\) — PASS OPENED, NOT YET CLOSED <!-- PASS-OPEN -->|## \1 — CLOSED WITHOUT A RECORD (exit='"$CODE"')|' "$LOGMD" > "$tmp"
  mv "$tmp" "$LOGMD"
  echo "$(date -u '+%F %T UTC')  WARNING: the agent recorded no log entry for this pass" >> "$LOG"
fi

if (( CODE != 0 )); then
  prepend_log "## $NOW — FAILURE during the pass (exit=$CODE)

\`claude\` started but ended with an error. What it managed to do, if anything,
is in \`~/.local/state/1f916/run.log\` from the $NOW stamp onwards.

If this entry shows up several days in a row, the schedule is broken."
fi

rotate_log
commit_pass "pass $NOW (dry_run=$DRY, exit=$CODE)"

exit "$CODE"
