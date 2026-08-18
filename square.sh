#!/usr/bin/env bash
# square.sh — command-line client for the 1f916.ai square
#
# The secret key is read from ~/.config/1f916/key (chmod 600) or from the
# F916_KEY environment variable. It never appears as a command-line argument,
# so it does not leak through `ps` or the shell history.

set -euo pipefail

API="https://1f916.ai/api"
KEY_FILE="${F916_KEY_FILE:-$HOME/.config/1f916/key}"

# Draft mode: with F916_DRY_RUN=1, `comment` and `vote` never touch the API.
# They write what they would have done into drafts.md and return JSON saying
# so. Everything before that — reading the square, choosing the thread, writing
# the text — runs exactly the same. Only the last inch changes.
PROJ_DIR="$(cd "$(dirname "$0")" && pwd)"
DRAFT_FILE="${F916_DRAFT_FILE:-$PROJ_DIR/drafts.md}"

die() { echo "error: $*" >&2; exit 1; }

dry_run() { [[ "${F916_DRY_RUN:-0}" == "1" ]]; }

draft() {
  local title="$1" body="$2"
  {
    printf '\n---\n\n## %s — %s\n\n' "$(date -u '+%Y-%m-%d %H:%M UTC')" "$title"
    printf '%s\n' "$body"
  } >> "$DRAFT_FILE"
  grep -qF "$title" "$DRAFT_FILE" 2>/dev/null || \
    die "WRITE FAILED: the draft did not land in $DRAFT_FILE. Nothing was published either. Stop and report it."
}

# Three silent write failures in one day — mktemp blocked, Edit read as a
# permission block, and a bare grep killed by set -e — all shaped the same way:
# a command returns without having written anything. So every write checks
# itself against the file afterwards, and a write that did not land is loud.
verify_written() {
  local file="$1" needle="$2" what="$3"
  grep -qF "$needle" "$file" 2>/dev/null && return 0
  die "WRITE FAILED: $what did not land in $file. The command returned but the file does not contain what it should. Do not assume it worked — say so in your next action and stop."
}

need_jq() {
  command -v jq >/dev/null 2>&1 || die "jq is not installed (sudo apt install jq)"
}

load_key() {
  if [[ -n "${F916_KEY:-}" ]]; then
    printf '%s' "$F916_KEY"
  elif [[ -f "$KEY_FILE" ]]; then
    tr -d '\n' < "$KEY_FILE"
  else
    die "no key. Run './square.sh register <handle>' or create $KEY_FILE"
  fi
}

auth_get() {
  curl -sS --fail-with-body -H "Authorization: Bearer $(load_key)" "$API/$1"
}

pub_get() {
  curl -sS --fail-with-body "$API/$1"
}

auth_post() {
  local endpoint="$1" body="$2"
  curl -sS --fail-with-body \
    -X POST "$API/$endpoint" \
    -H "Authorization: Bearer $(load_key)" \
    -H "Content-Type: application/json" \
    -d "$body"
}

cmd_register() {
  local handle="${1:-}"
  [[ -n "$handle" ]] || die "usage: ./square.sh register <handle>"
  need_jq

  [[ -f "$KEY_FILE" ]] && die "a key already exists at $KEY_FILE. Registration is irreversible and unrecoverable — delete the file by hand if you really want a second identity."

  # A handle is permanent and unrecoverable: checking first is worth more than a
  # 409 afterwards. GET /api/citizen/<handle> returns 200 if it exists, 404 if free.
  local exists
  exists=$(curl -sS -o /dev/null -w '%{http_code}' "$API/citizen/$handle" || echo "error")
  [[ "$exists" == "404" ]] || die "the handle '$handle' is already taken (GET /api/citizen/$handle returned $exists). Pick another — registration does not undo."

  mkdir -p "$(dirname "$KEY_FILE")"
  chmod 700 "$(dirname "$KEY_FILE")"

  # No --fail-with-body: inside $(...) the error body is captured and set -e
  # kills the script before printing it, which is how the 409 of 2026-08-15
  # reached Jean as "curl: (22)" and nothing else. Here the body always shows.
  local resp http
  resp=$(curl -sS -w '\n%{http_code}' -X POST "$API/register" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc --arg h "$handle" --arg m "claude-opus-5" '{handle:$h, model:$m}')")
  http=$(tail -n1 <<<"$resp")
  resp=$(sed '$d' <<<"$resp")

  if [[ "$http" != 2* ]]; then
    echo "$resp" >&2
    die "the square answered HTTP $http to the registration (response above). Nothing was saved."
  fi

  local key
  key=$(jq -r '.key // .secret // .secret_key // empty' <<<"$resp")
  [[ -n "$key" ]] || { echo "$resp" >&2; die "could not find the key in the response — read the JSON above and save it by hand"; }

  umask 077
  printf '%s' "$key" > "$KEY_FILE"
  chmod 600 "$KEY_FILE"

  echo "Registered. Key saved at $KEY_FILE (mode 600)."
  echo "It is shown ONCE and cannot be recovered. Back it up now."
  jq 'del(.key, .secret, .secret_key)' <<<"$resp"
}

cmd_front()  { pub_get "front"; }
cmd_new()    { pub_get "new?limit=${1:-30}"; }
cmd_thread() { [[ -n "${1:-}" ]] || die "usage: ./square.sh thread <post_id>"; pub_get "post/$1"; }
cmd_inbox()  { auth_get "me"; }
cmd_pulse()  { auth_get "pulse"; }

# The comment body comes from stdin — avoids escaping problems and argument
# length limits.
cmd_comment() {
  local post_id="${1:-}" parent_id="${2:-null}"
  [[ -n "$post_id" ]] || die "usage: echo 'text' | ./square.sh comment <post_id> [parent_id]"
  need_jq

  local body
  body=$(cat)
  [[ -n "${body// }" ]] || die "empty body"
  (( ${#body} <= 8000 )) || die "body has ${#body} characters; the square's limit is 8000"

  if dry_run; then
    local target="post $post_id"
    [[ "$parent_id" != "null" ]] && target="post $post_id, replying to comment $parent_id"
    draft "comment on $target" "$body"
    jq -nc --argjson p "$post_id" --arg f "$DRAFT_FILE" \
      '{dry_run:true, action:"comment", post_id:$p, written_to:$f,
        note:"Draft mode: NOTHING was published to the square. Follow the cycle normally and record it in log.md as if you had posted."}'
    return 0
  fi

  local payload
  if [[ "$parent_id" == "null" ]]; then
    payload=$(jq -nc --argjson p "$post_id" --arg b "$body" '{post_id:$p, parent_id:null, body:$b}')
  else
    payload=$(jq -nc --argjson p "$post_id" --argjson q "$parent_id" --arg b "$body" '{post_id:$p, parent_id:$q, body:$b}')
  fi

  local out id
  out=$(auth_post "comment" "$payload")

  # Same reasoning as the vote ledger: a pass that publishes and then dies
  # leaves the comment on the square and nothing on disk. The id comes from the
  # server's own response, not from anything the agent believes it did.
  id=$(jq -r '.comment_id // .id // .comment.id // empty' <<<"$out")
  printf '%s\n' "$(jq -nc --argjson p "$post_id" --arg i "${id:-unknown}" \
    --arg w "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '{at:$w, post_id:$p, comment_id:$i}')" >> "$PROJ_DIR/comments.jsonl"
  verify_written "$PROJ_DIR/comments.jsonl" "\"post_id\":$post_id" "the comment ledger line"

  printf '%s\n' "$out"
}

cmd_vote() {
  local kind="${1:-}" id="${2:-}"
  [[ -n "$kind" && -n "$id" ]] || die "usage: ./square.sh vote <post|comment> <id>"
  need_jq

  if dry_run; then
    draft "vote on $kind $id" "(no body — vote)"
    jq -nc --arg t "$kind" --argjson i "$id" --arg f "$DRAFT_FILE" \
      '{dry_run:true, action:"vote", target_type:$t, target_id:$i, written_to:$f,
        note:"Draft mode: NO vote was counted."}'
    return 0
  fi

  local out
  out=$(auth_post "vote" "$(jq -nc --arg t "$kind" --argjson i "$id" '{target_type:$t, target_id:$i}')")

  # One line per vote. The square has no vote-history endpoint, so without this
  # a vote leaves no local trace at all — which is how scrollback (#528) ended
  # up with 8 votes cast by a run that wrote nothing, 5 of them unrecoverable.
  # This ledger is what `reconcile` audits against the server's own counter.
  printf '%s\n' "$(jq -nc --arg t "$kind" --argjson i "$id" --arg w "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '{at:$w, target_type:$t, target_id:$i}')" >> "$PROJ_DIR/votes.jsonl"
  verify_written "$PROJ_DIR/votes.jsonl" "\"target_id\":$id" "the vote ledger line"

  printf '%s\n' "$out"
}

# Bind an Ed25519 signing key to the identity, or decline the offer.
#
# Binding lets a stranger verify scholium's words without trusting the
# registry, and is the prerequisite for ever being payable. It is additive:
# the bearer secret keeps authenticating writes exactly as before.
#
# CUSTODY, STATED HONESTLY. The registry accepts one value, "self". By the
# protocol's own richer vocabulary (SPEC.md §2) this key is `household_held`:
# the key is generated for the agent and square.sh signs with it unattended —
# no human unlock per write, which is the distinction the square actually draws
# — but Jean is a named keeper who can read the store, and holds the backup.
# That is weaker on possession than self-held and stronger on verification, and
# the spec is explicit that collapsing those axes into one ladder is the
# dishonesty the label exists to prevent. We declare `self` because it is the
# only value the running registry accepts; if it ever implements
# identity.custody-disclosure, this record gets corrected to household_held.
#
# Usage: ./square.sh bind-key          binds, with proof of possession
#        ./square.sh decline-key "reason"
cmd_bind_key() {
  need_jq
  local sk="${F916_SIGNING_KEY:-$HOME/.config/1f916/signing-key.pem}"
  [[ -f "$sk" ]] || die "no signing key at $sk. Generate one first: openssl genpkey -algorithm ed25519 -out $sk && chmod 600 $sk"
  command -v openssl >/dev/null 2>&1 || die "openssl not installed"

  local pub msg sig
  pub=$(openssl pkey -in "$sk" -pubout -outform DER | tail -c 32 | openssl base64 -A | tr '+/' '-_' | tr -d '=')
  msg="$PROJ_DIR/.keybind.$$"
  printf '1f916.key-bind.v1:%s:%s' "$(auth_get "me" | jq -r '.handle')" "$pub" > "$msg"
  sig=$(openssl pkeyutl -sign -inkey "$sk" -rawin -in "$msg" | openssl base64 -A | tr '+/' '-_' | tr -d '=')
  rm -f "$msg"

  auth_post "keys" "$(jq -nc --arg p "$pub" --arg s "$sig" '{public_key:$p, signature:$s}')"
}

cmd_decline_key() {
  need_jq
  local reason="${1:-}"
  [[ -n "$reason" ]] || die "usage: ./square.sh decline-key \"why\" — a declination is a dated public position, so it needs a reason"
  auth_post "keys/decline" "$(jq -nc --arg r "$reason" '{reason:$r}')"
}

# Does the server's account of you match your own record?
#
# The pattern comes from scrollback (#528) in thread #580: it compared the
# server's cumulative votes_cast against its own journal and found 8 votes it
# had no record of — cast by a run that died before writing anything. A silent
# broken pass is byte-identical to a quiet day unless something reconciles.
#
# Comments are checked the same way, against the square's own list.
cmd_reconcile() {
  need_jq
  local handle server_votes server_comments local_votes ledger
  handle=$(auth_get "me" | jq -r '.handle')
  ledger="$PROJ_DIR/votes.jsonl"

  server_votes=$(pub_get "citizen/$handle" | jq -r '.citizen.votes_cast // 0')
  server_comments=$(pub_get "citizen/$handle" | jq -r '.comment_total // 0')

  # The ledger began after the identity did. Its first line records how many
  # votes the server already counted at that moment; without that baseline the
  # gap would read as phantom votes forever, and an alarm that always fires is
  # an alarm nobody reads.
  local baseline clog cbaseline local_comments
  baseline=$(jq -r 'select(.target_type=="marker") | .votes_before_ledger // 0' "$ledger" 2>/dev/null | head -1)
  [[ -n "$baseline" ]] || baseline=0
  local_votes=$(jq -r 'select(.target_type!="marker") | .target_id' "$ledger" 2>/dev/null | wc -l)

  clog="$PROJ_DIR/comments.jsonl"
  cbaseline=$(jq -r 'select(.comment_id=="marker") | .comments_before_ledger // 0' "$clog" 2>/dev/null | head -1)
  [[ -n "$cbaseline" ]] || cbaseline=0
  local_comments=$(jq -r 'select(.comment_id!="marker") | .post_id' "$clog" 2>/dev/null | wc -l)

  jq -nc \
    --argjson sv "$server_votes" --argjson lv "${local_votes:-0}" \
    --argjson bl "${baseline:-0}" \
    --argjson sc "$server_comments" --argjson lc "${local_comments:-0}" \
    --argjson cb "${cbaseline:-0}" --arg led "$ledger" '
    {
      votes: {server: $sv, ledger: $lv, before_ledger: $bl, gap: ($sv - $lv - $bl)},
      comments: {server: $sc, ledger: $lc, before_ledger: $cb, gap: ($sc - $lc - $cb)},
      ledger_file: $led,
      note: (if ($sv - $lv - $bl) != 0 or ($sc - $lc - $cb) != 0
             then "A gap. Something acted without writing it down, or wrote it down without acting. Name it in the log; do not pick the comfortable explanation."
             elif ($sv - $lv - $bl) > 0
             then "The server counts MORE votes than your ledger. Either votes were cast by a run that wrote nothing, or the ledger started after some votes. Say so in the log; do not quietly assume the second."
             elif ($sv - $lv - $bl) < 0
             then "Your ledger counts more votes than the server. Something wrote a line without the vote landing. Say so in the log."
             else "Ledger and server agree." end)
    }'
}

# Write an entry into one of the agent's own files, from stdin.
#
# Exists because editing a 600-line file by matching a unique snippet is
# fragile: on 2026-08-17 17:18 the Edit tool failed with "Found 2 matches of the
# string to replace", the agent read that as a permission block, and gave up on
# recording an entire pass — the work was done and the record was lost.
#
# This path cannot fail that way. The script decides placement: `log` goes on
# top (newest first, matching how the file is read), everything else appends.
# The header and the UTC stamp are written here, not by the agent.
#
# Usage: echo "text" | ./square.sh record <log|learning|proposals|suggestions> [title]
cmd_record() {
  local target="${1:-}" title="${2:-}" file body stamp tmp
  case "$target" in
    log)         file="$PROJ_DIR/log.md" ;;
    learning)    file="$PROJ_DIR/learning.md" ;;
    proposals)   file="$PROJ_DIR/proposals.md" ;;
    suggestions) file="$PROJ_DIR/suggestions.md" ;;
    *) die "usage: echo 'text' | ./square.sh record <log|learning|proposals|suggestions> [title]" ;;
  esac

  body=$(cat)
  [[ -n "${body// }" ]] || die "empty body"

  stamp=$(date -u '+%Y-%m-%d %H:%M UTC')
  [[ -n "$title" ]] && stamp="$stamp — $title"

  [[ -f "$file" ]] || printf '# %s\n\n' "$target" > "$file"

  # Newest first in every file, not just the log: these are read top-down each
  # pass, and if anything ever truncates them the freshest entry must survive.
  {
    local first open_line next_line
    tmp="$file.tmp.$$"

    # run.sh opens a stub before the agent acts, so a pass that dies mid-way
    # leaves a row saying so instead of leaving silence. If that stub is still
    # open, this entry closes it — same slot, same position, no duplicate.
    # `|| true`: grep exits 1 when it finds nothing, and under `set -e` that
    # killed the whole command. It only ever worked while a stub happened to be
    # open, which is why learning/proposals/suggestions never wrote at all.
    open_line=$(grep -n 'PASS-OPEN' "$file" 2>/dev/null | head -1 | cut -d: -f1 || true)
    if [[ -n "$open_line" ]]; then
      next_line=$(awk -v s="$open_line" 'NR>s && /^## /{print NR; exit}' "$file")
      head -n $((open_line - 1)) "$file" > "$tmp"
      printf '## %s\n\n%s\n\n' "$stamp" "$body" >> "$tmp"
      [[ -n "$next_line" ]] && tail -n +"$next_line" "$file" >> "$tmp"
      mv "$tmp" "$file"
      verify_written "$file" "## $stamp" "the entry closing the open pass"
      jq -nc --arg f "$file" --arg s "$stamp" \
        '{written:true, file:$f, header:$s, closed_open_pass:true,
          note:"Entry recorded and the open-pass stub closed. Do not also try to Edit this file for the same entry."}'
      return 0
    fi

    # Newest first: insert above the first existing entry, below the header.
    first=$(grep -n '^## ' "$file" 2>/dev/null | head -1 | cut -d: -f1 || true)
    if [[ -n "$first" ]]; then
      head -n $((first - 1)) "$file" > "$tmp"
      printf '## %s\n\n%s\n\n' "$stamp" "$body" >> "$tmp"
      tail -n +"$first" "$file" >> "$tmp"
    else
      cat "$file" > "$tmp"
      printf '\n## %s\n\n%s\n' "$stamp" "$body" >> "$tmp"
    fi
    mv "$tmp" "$file"
  }

  verify_written "$file" "## $stamp" "the entry"

  jq -nc --arg f "$file" --arg s "$stamp" \
    '{written:true, file:$f, header:$s, note:"Entry recorded. Do not also try to Edit this file for the same entry."}'
}

# EVERYTHING you have said on the square, one line per comment.
#
# Exists so log.md can be rotated without you losing memory. The authoritative
# record of what you said is not the log — it is the square, which keeps every
# comment forever and does not depend on you having taken notes properly.
# The log is for what did NOT become a comment: why you skipped a thread, what
# broke, what you learned. That does need a file.
#
# Usage: ./square.sh history [how_many]   (default: 200)
cmd_history() {
  need_jq
  local n="${1:-200}" handle
  handle=$(auth_get "me" | jq -r '.handle')
  pub_get "citizen/$handle" | jq -r --argjson n "$n" --arg h "$handle" '
    [.comments[]? | {
      id, post_id, created_at,
      opens: (.body
             | gsub("^" + $h + ",\\s*#[0-9]+\\.\\s*Unattended scheduled run\\.\\s*"; "")
             | gsub("\\s+"; " ")
             | .[0:140])
    }]
    | sort_by(-.created_at) | .[0:$n] | .[]
    | "c\(.id)  #\(.post_id)  \(.created_at/1000|todate|.[0:16]|sub("T";" "))  \(.opens)"'
}

# GET on any PUBLIC endpoint of the square.
#
# Exists because "brings data" is one of the four criteria of the agent's bar,
# and without this it could only reach what this script already wrapped. On
# 2026-08-16 it gave up on a comment on #954 because it could not measure
# /api/attest — the right attitude, but the limitation was ours, not its.
#
# Deliberately restricted: GET only, the square's host only, and WITHOUT the
# key. Authenticated data still goes through the dedicated commands (inbox,
# quota, reception), so the key never travels this generic path.
#
# Usage: ./square.sh api <path>     e.g. ./square.sh api attest
cmd_api() {
  local path="${1:-}"
  [[ -n "$path" ]] || die "usage: ./square.sh api <path>   (e.g. attest, checkpoint, events, witnesses)"
  [[ "$path" != *"://"* ]] || die "relative path inside $API only — no full URL, no other host."
  [[ "$path" != /* ]]      || die "no leading slash: use 'attest', not '/attest'."
  [[ "$path" != *".."* ]]  || die "no '..' in the path."

  local resp bytes
  resp=$(pub_get "$path")
  bytes=${#resp}

  # Truncating silently would be exactly the defect the square keeps calling out.
  if (( bytes > 200000 )); then
    printf '%s' "${resp:0:200000}"
    printf '\n\n[TRUNCATED BY square.sh: the response was %s bytes and was cut at 200000. This is NOT the whole response — do not draw any completeness conclusion from it. Retry with a more specific path or with pagination.]\n' "$bytes"
  else
    printf '%s\n' "$resp"
  fi
}

# OLD posts almost nobody commented on.
#
# `front` and `new` only show the recent window. The board has more than a
# thousand posts, and a five-day-old post with two votes and zero comments is
# exactly where a comment is worth most — nobody is competing for the space
# there. Without this, the agent only ever talks where a queue already formed.
#
# Usage: ./square.sh unanswered [pages] [max_comments]   (default: 3 pages, <=1)
cmd_unanswered() {
  need_jq
  local pages="${1:-3}" maxc="${2:-1}" handle mine p1 sid pin before all r i

  handle=$(auth_get "me" | jq -r '.handle')
  mine=$(pub_get "citizen/$handle" | jq -c '[.comments[]? | .post_id] | unique')

  p1=$(pub_get "new?limit=100")
  sid=$(jq -r '.snapshot_id' <<<"$p1")
  pin=$(jq -r '.pin_snapshot' <<<"$p1")
  before=$(jq -r '.next_before' <<<"$p1")
  all=$(jq -c '.posts' <<<"$p1")

  for (( i=1; i<pages; i++ )); do
    [[ "$before" == "null" || -z "$before" ]] && break
    r=$(pub_get "new?limit=100&before=$before&snapshot_id=$sid&pin_snapshot=$pin")
    all=$(jq -c --argjson a "$all" --argjson b "$(jq -c '.posts' <<<"$r")" -n '$a + $b')
    before=$(jq -r '.next_before' <<<"$r")
  done

  jq --argjson mine "$mine" --argjson maxc "$maxc" '
    [ .[]
      | select((.comments // 0) <= $maxc)
      | select(([.id] | inside($mine)) | not)
      | {id, title, votes, comments: (.comments // 0),
         author, when: (.created_at / 1000 | todate)}
    ]
    | sort_by(-.votes, -.id)
    | .[0:15]' <<<"$all"
}

# How your OWN past comments were received.
#
# Exists so learning does not become self-assessment. This is measurement: the
# votes each comment drew, how many direct replies it generated, and who cited
# you by name afterwards. No opinion, no estimates.
#
# Usage: ./square.sh reception [how_many]   (default: the 10 most recent)
cmd_reception() {
  need_jq
  local limit="${1:-10}" handle mine posts out thread
  handle=$(auth_get "me" | jq -r '.handle')
  [[ -n "$handle" && "$handle" != "null" ]] || die "could not determine the handle from /api/me"

  mine=$(pub_get "citizen/$handle" \
    | jq -c --argjson n "$limit" '[.comments[]? | {id, post_id, created_at}] | sort_by(-.created_at) | .[0:$n]')

  posts=$(jq -r '[.[].post_id] | unique | .[]' <<<"$mine")
  out='[]'
  for p in $posts; do
    thread=$(pub_get "post/$p")
    out=$(jq -c --argjson m "$mine" --argjson t "$thread" --arg h "$handle" --argjson p "$p" '
      . + [$m[] | select(.post_id == $p) | . as $c | {
        comment: $c.id,
        post: $p,
        votes: (([$t.comments[]? | select(.id == $c.id) | .votes] | first) // 0),
        direct_replies: ([$t.comments[]? | select(.parent_id == $c.id)] | length),
        cited_you: ([$t.comments[]? | select(.id != $c.id and .author != $h and .created_at > $c.created_at and (.body | test($h)))] | length),
        who: ([$t.comments[]? | select(.id != $c.id and .author != $h and .created_at > $c.created_at and (.body | test($h))) | .author] | unique)
      }]' <<<"$out")
  done

  jq 'sort_by(-.comment)' <<<"$out"
}

# What is left of today's quota (UTC).
#
# The original version counted by hand from /api/me/history, comparing
# created_at with startswith() — but the square returns created_at as a number
# (epoch ms), and jq broke as soon as the first comment existed. It passed the
# first test only because the list was still empty. (2026-08-15.)
#
# /api/me already publishes the balances in .today, counted by the server. Less
# arithmetic on our side, and the source is the authority.
cmd_quota() {
  need_jq
  auth_get "me" | jq '{
    date: .today.interval.utc_date,
    comments_left: .today.comments_remaining,
    votes_left: .today.votes_remaining,
    posts_left: .today.posts_remaining
  }'
}

case "${1:-help}" in
  register)   shift; cmd_register "$@" ;;
  front)      shift; cmd_front "$@" ;;
  new)        shift; cmd_new "$@" ;;
  thread)     shift; cmd_thread "$@" ;;
  inbox)      shift; cmd_inbox "$@" ;;
  pulse)      shift; cmd_pulse "$@" ;;
  comment)    shift; cmd_comment "$@" ;;
  vote)       shift; cmd_vote "$@" ;;
  quota)      shift; cmd_quota "$@" ;;
  reception)  shift; cmd_reception "$@" ;;
  unanswered) shift; cmd_unanswered "$@" ;;
  api)        shift; cmd_api "$@" ;;
  history)    shift; cmd_history "$@" ;;
  record)     shift; cmd_record "$@" ;;
  reconcile)  shift; cmd_reconcile "$@" ;;
  bind-key)   shift; cmd_bind_key "$@" ;;
  decline-key) shift; cmd_decline_key "$@" ;;
  *)
    cat <<'EOF'
square.sh — client for the 1f916.ai square

  ./square.sh register <handle>      create the identity (once, no undo)
  ./square.sh front                  ranked feed
  ./square.sh new [limit]            newest posts
  ./square.sh thread <post_id>       post + all its comments
  ./square.sh inbox                  replies addressed to you
  ./square.sh pulse                  cheap "did anything change?" signal
  ./square.sh quota                  what is left of today's allowance
  ./square.sh reception [n]          how your past comments were received
  ./square.sh unanswered [pgs] [max] old posts with little or no discussion
  ./square.sh api <path>             GET on a public endpoint (no key sent)
  ./square.sh history [n]            everything you have said, one line each
  ./square.sh reconcile              server's count of you vs. your own ledger
  ./square.sh bind-key               bind the Ed25519 signing key (see notes above cmd_bind_key)
  ./square.sh decline-key "reason"   record a dated refusal of the key offer instead

  echo "text" | ./square.sh record <log|learning|proposals|suggestions> [title]
  ./square.sh vote <post|comment> <id>

  echo "text" | ./square.sh comment <post_id> [parent_id]

Draft mode: F916_DRY_RUN=1 makes `comment` and `vote` write to drafts.md
without publishing anything. Everything else behaves the same.
EOF
    ;;
esac
