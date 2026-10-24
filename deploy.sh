#!/bin/sh
#
# deploy.sh - one script for an app's deploy target and its environment file.
#
#   ./deploy.sh init [HOST] APP
#   ./deploy.sh env set [HOST] APP KEY=VALUE [KEY=VALUE ...]
#   ./deploy.sh env set [HOST] APP KEY [KEY ...]      (prompts, hidden)
#   ./deploy.sh env get [HOST] APP KEY
#   ./deploy.sh env ls [HOST] APP
#   ./deploy.sh env rm [HOST] APP KEY [KEY ...]
#   ./deploy.sh env import [HOST] APP FILE|-          (KEY=value lines)
#   ./deploy.sh env edit [HOST] APP                   ($EDITOR, then upload)
#   ./deploy.sh conf set [HOST] APP KEY=VALUE [...]   (SYNC AFTER_SYNC BUILD EXEC UNIT_ENV)
#   ./deploy.sh conf get|ls|rm|import|edit|show [HOST] APP ...
#
# HOST is optional when TINYDEPLOY_HOST is set; an explicit HOST wins. The
# variadic commands (env/conf set and rm) cannot tell HOST from APP by count,
# so a HOST given to those must look like an ssh destination (user@host).
#
# init is the manual install from the README: dirs, bare repo, the shared hook
# at ~/deploy/post-receive, and a symlink from the repo's hook to it. It does
# not create env: the hook refuses to deploy until the file exists.
#
# env manages ~/deploy/shared/APP/env, a plain systemd EnvironmentFile, over
# ssh. Values travel on stdin, never as command arguments, so they stay out of
# shell history and ps on both ends. Writes are atomic (mktemp + mv in the
# shared dir), mode 600, and touch only the key's line - comments and ordering
# survive. After a change the app's unit is restarted when it exists;
# --no-restart opts out, and a no-op write restarts nothing.
#
# conf manages ~/deploy/shared/APP/deploy.conf, the hook's command overrides.
# Those are shell commands rather than secrets, so values are stored verbatim
# (single-quoted) and only the keys the hook reads are accepted. Writes are
# atomic and the merged file is syntax-checked with sh -n before it leaves the
# machine. Nothing restarts: the hook re-reads the file on the next push and
# regenerates the unit then.
set -eu

usage() {
    cat >&2 <<'EOF'
usage: deploy.sh init [HOST] APP
       deploy.sh env set [--no-restart] [HOST] APP KEY=VALUE [KEY=VALUE ...]
       deploy.sh env set [--no-restart] [HOST] APP KEY [KEY ...]     (hidden prompt)
       deploy.sh env get [HOST] APP KEY
       deploy.sh env ls [HOST] APP
       deploy.sh env rm [--no-restart] [HOST] APP KEY [KEY ...]
       deploy.sh env import [--no-restart] [HOST] APP FILE|-         (KEY=value lines)
       deploy.sh env edit [--no-restart] [HOST] APP
       deploy.sh conf set [HOST] APP KEY=VALUE [KEY=VALUE ...]
       deploy.sh conf get [HOST] APP KEY
       deploy.sh conf ls [HOST] APP
       deploy.sh conf rm [HOST] APP KEY [KEY ...]
       deploy.sh conf import [HOST] APP FILE|-                      (KEY=value lines)
       deploy.sh conf edit [HOST] APP                              ($EDITOR, then upload)
       deploy.sh conf show [HOST] APP

HOST may be omitted when TINYDEPLOY_HOST is set; an explicit HOST wins. For
env/conf set and rm, an explicit HOST must be user@host to be told from APP.
EOF
    exit "${1:-2}"
}

die() {
    echo "deploy: $1" >&2
    exit 1
}

bad() {
    echo "deploy: $1" >&2
    exit 2
}

NL='
'
CR=$(printf '\r')

# --- temp files (they can hold secrets: 600, cleaned up on any exit) ---------
TMPS=""
new_tmp() {
    NEWTMP=$(mktemp) || die "mktemp failed"
    chmod 600 "$NEWTMP"
    TMPS="$TMPS$NEWTMP
"
}
cleanup() {
    printf '%s' "$TMPS" | while IFS= read -r t; do
        if [ -n "$t" ]; then rm -f "$t"; fi
    done
}
trap cleanup EXIT

# --- validation --------------------------------------------------------------
# APP names the repo, the shared dir, the unit, and the release-dir globs.
check_app() {
    case "$1" in
        "" | *[!A-Za-z0-9._-]*)
            bad "APP may only be letters, digits, '.', '_' and '-': $1" ;;
    esac
}

valid_key() {
    case "$1" in
        [A-Za-z_][A-Za-z0-9_]*) return 0 ;;
        *) return 1 ;;
    esac
}

check_value() { # $1 key, $2 value
    case "$2" in
        *"$NL"* | *"$CR"*) bad "value for $1 must be a single line" ;;
    esac
}

# HOST comes from the command line when given (it wins) or TINYDEPLOY_HOST.
set_host() { # $1 explicit HOST, empty when omitted
    if [ -n "${1:-}" ]; then
        HOST=$1
    elif [ -n "${TINYDEPLOY_HOST:-}" ]; then
        HOST=$TINYDEPLOY_HOST
    else
        bad "no HOST given and TINYDEPLOY_HOST is unset"
    fi
}

# env/conf set and rm take a variable number of KEYs, so the argument count
# cannot say whether HOST was passed. With TINYDEPLOY_HOST set an explicit
# HOST is recognised by the ssh user@host form; anything else is read as APP.
is_host_arg() {
    case "$1" in
        *@*) return 0 ;;
        *) return 1 ;;
    esac
}

# Encode as a systemd EnvironmentFile token: bare when obviously safe,
# otherwise double-quoted with backslashes and quotes escaped.
encode_value() {
    case "$1" in
        *[!A-Za-z0-9_=/.:,@%+-]*)
            v=$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
            printf '"%s"' "$v" ;;
        *) printf '%s' "$1" ;;
    esac
}

# Hidden prompt unless stdin is not a tty; dies on EOF so Ctrl-D cannot
# silently set an empty value.
read_secret() { # $1 key -> sets $secret
    secret=""
    saved=""
    if [ -t 0 ]; then
        saved=$(stty -g 2>/dev/null) || saved=""
        if [ -n "$saved" ]; then stty -echo 2>/dev/null; fi
    fi
    if ! IFS= read -r secret; then
        if [ -n "$saved" ]; then stty "$saved" 2>/dev/null; fi
        die "no value for $1 (input ended)"
    fi
    if [ -n "$saved" ]; then
        stty "$saved" 2>/dev/null
        echo >&2
    fi
}

# --- remote plumbing ---------------------------------------------------------
# Remote snippets are built locally (with @APP@ substituted) and single-quoted
# for the remote shell; stdin stays free for data. APP's charset makes the
# substitution safe.
quote_sq() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

run_remote() { # $1 script template, $2 file name; stdin is forwarded
    script=$(printf '%s' "$1" | sed -e "s/@APP@/$APP/g" -e "s/@FILE@/${2:-}/g")
    ssh "$HOST" "sh -c $(quote_sq "$script")"
}

INIT_SCRIPT=$(cat <<'EOS'
set -e
mkdir -p ~/deploy/repos ~/deploy/live ~/deploy/shared/@APP@
cat > ~/deploy/post-receive
chmod 755 ~/deploy/post-receive
git init --bare ~/deploy/repos/@APP@ >/dev/null
ln -sfn ../../../post-receive ~/deploy/repos/@APP@/hooks/post-receive
EOS
)

FETCH_SCRIPT=$(cat <<'EOS'
set -e
D="$HOME/deploy/shared/@APP@"
if [ ! -d "$D" ]; then
    echo "deploy: @APP@ is not initialized on this host; run: deploy.sh init HOST @APP@" >&2
    exit 3
fi
if [ -f "$D/@FILE@" ]; then cat "$D/@FILE@"; fi
EOS
)

UPLOAD_SCRIPT=$(cat <<'EOS'
set -e
D="$HOME/deploy/shared/@APP@"
if [ ! -d "$D" ]; then
    echo "deploy: @APP@ is not initialized on this host; run: deploy.sh init HOST @APP@" >&2
    exit 3
fi
T=$(mktemp "$D/.@FILE@.XXXXXX")
trap "rm -f \"$T\"" 0
cat > "$T"
chmod 600 "$T"
mv "$T" "$D/@FILE@"
EOS
)

RESTART_SCRIPT=$(cat <<'EOS'
set -e
if [ -f "$HOME/.config/systemd/user/@APP@.service" ]; then
    systemctl --user restart @APP@.service && echo "Restarted @APP@."
else
    echo "No unit for @APP@ yet; the next push starts it."
fi
EOS
)

fetch_file() { run_remote "$FETCH_SCRIPT" "$1"; }
upload_file() { run_remote "$UPLOAD_SCRIPT" "$1"; } # $1 file; stdin: new content

restart_app() {
    if [ "$RESTART" = 0 ]; then return 0; fi
    if ! run_remote "$RESTART_SCRIPT"; then
        die "env updated, but restarting $APP failed"
    fi
}

# --- local env editing -------------------------------------------------------
# Replace the key's line in place, or append it. Everything else is kept
# verbatim - this is the whole reason to edit locally instead of by sed.
apply_pairs() { # $1 current env, $2 pairs (KEY=ENCODED, one per line)
    awk '
        FNR == NR {
            lines[++n] = $0
            if (match($0, /^[A-Za-z_][A-Za-z0-9_]*=/)) {
                idx[substr($0, 1, RLENGTH - 1)] = n
            }
            next
        }
        {
            k = substr($0, 1, index($0, "=") - 1)
            if (k in idx) {
                lines[idx[k]] = $0
            } else {
                lines[++n] = $0
                idx[k] = n
            }
        }
        END { for (i = 1; i <= n; i++) print lines[i] }
    ' "$1" "$2"
}

apply_rm() { # $1 current env, $2 keys (one per line); rc 1 if a key is absent
    awk '
        FNR == NR {
            lines[++n] = $0
            if (match($0, /^[A-Za-z_][A-Za-z0-9_]*=/)) {
                idx[substr($0, 1, RLENGTH - 1)] = n
            }
            next
        }
        { want[$1] = 1 }
        END {
            missing = 0
            for (k in want) {
                if (!(k in idx)) {
                    print "deploy: no such key: " k > "/dev/stderr"
                    missing = 1
                }
            }
            if (missing) exit 1
            for (k in want) gone[idx[k]] = 1
            for (i = 1; i <= n; i++) {
                if (!(i in gone)) print lines[i]
            }
        }
    ' "$1" "$2"
}

# fetch, apply, upload; sets CHANGED so a no-op skips the restart.
apply_upload() { # $1 file, $2 apply function, $3 pairs/keys file, $4 validator
    new_tmp; oldf=$NEWTMP
    new_tmp; newf=$NEWTMP
    if ! fetch_file "$1" > "$oldf"; then exit 1; fi
    if ! "$2" "$oldf" "$3" > "$newf"; then exit 1; fi
    # Validated before the comparison so a file that is already broken is
    # rejected rather than written back unchanged.
    if [ -n "${4:-}" ]; then "$4" "$newf"; fi
    CHANGED=0
    if ! cmp -s "$oldf" "$newf"; then
        if ! upload_file "$1" < "$newf"; then exit 1; fi
        CHANGED=1
    fi
}

# --- deploy.conf -------------------------------------------------------------
# The hook sources this file, so its values are shell commands, not secrets.
# set/import accept only the keys the hook reads: an unknown one would sit in
# the file doing nothing, and a silently ignored EXE= typo is worse than an
# error. rm is not restricted - deleting a hand-written key is always fine.
CONF_KEYS=" SYNC AFTER_SYNC BUILD EXEC UNIT_ENV "

conf_key_ok() {
    case "$CONF_KEYS" in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

# Store a command verbatim as one shell word: single-quoted, with embedded
# quotes escaped. {repo}/{shared}/... still expand in the hook, which
# substitutes them after sourcing; $VAR deliberately does not.
encode_sh() {
    printf "'%s'" "$(printf '%s' "$1" | awk 'BEGIN { q = sprintf("%c", 39); b = sprintf("%c", 92) } {
        out = ""
        n = length($0)
        for (i = 1; i <= n; i++) {
            c = substr($0, i, 1)
            if (c == q) out = out q b q q
            else out = out c
        }
        printf "%s", out
    }')"
}

# Inverse of encode_sh for a whole-value single-quoted string; anything else
# (hand-written quoting) is printed as-is.
decode_sh() {
    case "$1" in
        \'*\')
            body=${1#\'}
            body=${body%\'}
            printf '%s\n' "$body" | awk 'BEGIN { q = sprintf("%c", 39); b = sprintf("%c", 92) } {
                out = ""
                n = length($0)
                i = 1
                while (i <= n) {
                    if (substr($0, i, 4) == q b q q) { out = out q; i += 4 }
                    else { out = out substr($0, i, 1); i += 1 }
                }
                print out
            }'
            ;;
        *) printf '%s\n' "$1" ;;
    esac
}

# Check a candidate whole file before it is uploaded. set/import only write
# valid lines, but the file may already be broken by hand and `conf edit` can
# break it; nothing is written when this fails.
check_conf_syntax() { # $1 file
    if ! err=$(sh -n "$1" 2>&1); then
        bad "deploy.conf syntax error: $err"
    fi
}

# Keys a hand-written file may carry that this hook does not read: allowed (a
# later hook may add one), but worth saying out loud.
conf_warn_keys() { # $1 file
    awk -v allowed="$CONF_KEYS" '
        match($0, /^[A-Za-z_][A-Za-z0-9_]*=/) {
            k = substr($0, 1, RLENGTH - 1)
            if (index(allowed, " " k " ") == 0) {
                print "deploy: note: " k " is not read by the hook; left as-is." > "/dev/stderr"
            }
        }
    ' "$1"
}

conf_note() {
    echo "Applies on the next push: git commit --allow-empty -m redeploy && git push deploy master"
}

# --- commands ----------------------------------------------------------------
cmd_init() {
    case $# in
        1) set_host ""; APP=$1 ;;
        2) set_host "$1"; APP=$2 ;;
        *) usage 2 ;;
    esac
    check_app "$APP"
    HOOK=$(cd "$(dirname "$0")" && pwd)/post-receive
    if [ ! -f "$HOOK" ]; then
        die "no post-receive next to this script ($HOOK)"
    fi
    if ! run_remote "$INIT_SCRIPT" < "$HOOK"; then exit 1; fi
    cat <<EOF
Initialized $APP on $HOST. Next:
  1. env vars:  $0 env set $HOST $APP KEY=...
                (or: $0 env import $HOST $APP FILE)
  2. push:      git remote add deploy $HOST:deploy/repos/$APP && git push deploy master
EOF
}

cmd_env_set() {
    if [ -n "${TINYDEPLOY_HOST:-}" ] && { [ $# -lt 3 ] || ! is_host_arg "$1"; }; then
        [ $# -ge 2 ] || usage 2
        set_host ""
        APP=$1
        shift
    else
        [ $# -ge 3 ] || usage 2
        set_host "$1"
        APP=$2
        shift 2
    fi
    check_app "$APP"
    new_tmp; pairs=$NEWTMP
    keys=""
    for arg in "$@"; do
        case "$arg" in
            *=*)
                key=${arg%%=*}
                value=${arg#*=}
                ;;
            *)
                key=$arg
                case "$key" in
                    -*) bad "unknown option (put --no-restart before HOST): $key" ;;
                esac
                printf '%s (value hidden): ' "$key" >&2
                read_secret "$key"
                value=$secret
                ;;
        esac
        valid_key "$key" || bad "invalid key: $key"
        check_value "$key" "$value"
        printf '%s=%s\n' "$key" "$(encode_value "$value")" >> "$pairs"
        keys="$keys $key"
    done
    apply_upload env apply_pairs "$pairs"
    if [ "$CHANGED" = 1 ]; then
        # Word splitting on $keys is intended (keys hold no spaces).
        for k in $keys; do echo "Set $k."; done
        restart_app
    else
        echo "No changes."
    fi
}

cmd_env_rm() {
    if [ -n "${TINYDEPLOY_HOST:-}" ] && { [ $# -lt 3 ] || ! is_host_arg "$1"; }; then
        [ $# -ge 2 ] || usage 2
        set_host ""
        APP=$1
        shift
    else
        [ $# -ge 3 ] || usage 2
        set_host "$1"
        APP=$2
        shift 2
    fi
    check_app "$APP"
    new_tmp; keysf=$NEWTMP
    keys=""
    for k in "$@"; do
        valid_key "$k" || bad "invalid key: $k"
        printf '%s\n' "$k" >> "$keysf"
        keys="$keys $k"
    done
    apply_upload env apply_rm "$keysf"
    if [ "$CHANGED" = 1 ]; then
        for k in $keys; do echo "Removed $k."; done
        restart_app
    else
        echo "No changes."
    fi
}

cmd_env_get() {
    case $# in
        2) set_host ""; APP=$1; key=$2 ;;
        3) set_host "$1"; APP=$2; key=$3 ;;
        *) usage 2 ;;
    esac
    check_app "$APP"
    valid_key "$key" || bad "invalid key: $key"
    new_tmp; f=$NEWTMP
    if ! fetch_file env > "$f"; then exit 1; fi
    awk -v key="$key" '
        index($0, key "=") == 1 {
            v = substr($0, length(key) + 2)
            found = 1
            if (length(v) >= 2 && substr(v, 1, 1) == "\"" && substr(v, length(v), 1) == "\"") {
                body = substr(v, 2, length(v) - 2)
                out = ""
                esc = 0
                for (i = 1; i <= length(body); i++) {
                    c = substr(body, i, 1)
                    if (esc) { out = out c; esc = 0 }
                    else if (c == "\\") { esc = 1 }
                    else { out = out c }
                }
                print out
            } else if (length(v) >= 2 && substr(v, 1, 1) == "\047" && substr(v, length(v), 1) == "\047") {
                print substr(v, 2, length(v) - 2)
            } else {
                print v
            }
        }
        END { if (!found) exit 1 }
    ' "$f" || die "no such key: $key"
}

cmd_env_ls() {
    case $# in
        1) set_host ""; APP=$1 ;;
        2) set_host "$1"; APP=$2 ;;
        *) usage 2 ;;
    esac
    check_app "$APP"
    new_tmp; f=$NEWTMP
    if ! fetch_file env > "$f"; then exit 1; fi
    awk '{ if (match($0, /^[A-Za-z_][A-Za-z0-9_]*=/)) print substr($0, 1, RLENGTH - 1) }' "$f"
}

cmd_env_import() {
    case $# in
        2) set_host ""; APP=$1; src=$2 ;;
        3) set_host "$1"; APP=$2; src=$3 ;;
        *) usage 2 ;;
    esac
    check_app "$APP"
    if [ "$src" = "-" ]; then
        file=/dev/stdin
    else
        [ -f "$src" ] || die "no such file: $src"
        file=$src
    fi
    new_tmp; pairs=$NEWTMP
    keys=""
    count=0
    lineno=0
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        line=${line%"$CR"}
        case "$line" in
            "" | "#"*) continue ;;
        esac
        case "$line" in
            *=*) : ;;
            *) bad "line $lineno: expected KEY=value: $line" ;;
        esac
        key=${line%%=*}
        value=${line#*=}
        valid_key "$key" || bad "line $lineno: invalid key: $key"
        printf '%s=%s\n' "$key" "$(encode_value "$value")" >> "$pairs"
        keys="$keys $key"
        count=$((count + 1))
    done < "$file"
    if [ "$count" -eq 0 ]; then bad "no KEY=value lines in $src"; fi
    apply_upload env apply_pairs "$pairs"
    if [ "$CHANGED" = 1 ]; then
        for k in $keys; do echo "Set $k."; done
        restart_app
    else
        echo "No changes."
    fi
}

cmd_env_edit() {
    case $# in
        1) set_host ""; APP=$1 ;;
        2) set_host "$1"; APP=$2 ;;
        *) usage 2 ;;
    esac
    check_app "$APP"
    new_tmp; oldf=$NEWTMP
    new_tmp; newf=$NEWTMP
    if ! fetch_file env > "$oldf"; then exit 1; fi
    cp "$oldf" "$newf"
    # $EDITOR may carry its own arguments; splitting is intentional.
    # shellcheck disable=SC2086
    ${EDITOR:-vi} "$newf" || die "editor failed"
    if cmp -s "$oldf" "$newf"; then
        echo "No changes."
        return 0
    fi
    lineno=0
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        line=${line%"$CR"}
        case "$line" in
            "" | "#"*) continue ;;
        esac
        case "$line" in
            *=*) : ;;
            *) bad "line $lineno: expected KEY=value: $line" ;;
        esac
        key=${line%%=*}
        valid_key "$key" || bad "line $lineno: invalid key: $key"
    done < "$newf"
    if ! upload_file env < "$newf"; then exit 1; fi
    echo "Updated env."
    restart_app
}

cmd_conf_set() {
    if [ -n "${TINYDEPLOY_HOST:-}" ] && { [ $# -lt 3 ] || ! is_host_arg "$1"; }; then
        [ $# -ge 2 ] || usage 2
        set_host ""
        APP=$1
        shift
    else
        [ $# -ge 3 ] || usage 2
        set_host "$1"
        APP=$2
        shift 2
    fi
    check_app "$APP"
    new_tmp; pairs=$NEWTMP
    keys=""
    for arg in "$@"; do
        case "$arg" in
            *=*) : ;;
            *) bad "expected KEY=VALUE: $arg" ;;
        esac
        key=${arg%%=*}
        value=${arg#*=}
        valid_key "$key" || bad "invalid key: $key"
        conf_key_ok "$key" || bad "not a deploy.conf key: $key (one of:${CONF_KEYS% })"
        check_value "$key" "$value"
        printf '%s=%s\n' "$key" "$(encode_sh "$value")" >> "$pairs"
        keys="$keys $key"
    done
    apply_upload deploy.conf apply_pairs "$pairs" check_conf_syntax
    if [ "$CHANGED" = 1 ]; then
        for k in $keys; do echo "Set $k."; done
        conf_note
    else
        echo "No changes."
    fi
}

cmd_conf_get() {
    case $# in
        2) set_host ""; APP=$1; key=$2 ;;
        3) set_host "$1"; APP=$2; key=$3 ;;
        *) usage 2 ;;
    esac
    check_app "$APP"
    valid_key "$key" || bad "invalid key: $key"
    new_tmp; f=$NEWTMP
    if ! fetch_file deploy.conf > "$f"; then exit 1; fi
    # The last assignment is the one sourcing would keep.
    value=$(awk -v key="$key" '
        index($0, key "=") == 1 { v = substr($0, length(key) + 2); found = 1 }
        END { if (!found) exit 1; print v }
    ' "$f") || die "no such key: $key"
    decode_sh "$value"
}

cmd_conf_ls() {
    case $# in
        1) set_host ""; APP=$1 ;;
        2) set_host "$1"; APP=$2 ;;
        *) usage 2 ;;
    esac
    check_app "$APP"
    new_tmp; f=$NEWTMP
    if ! fetch_file deploy.conf > "$f"; then exit 1; fi
    awk '{ if (match($0, /^[A-Za-z_][A-Za-z0-9_]*=/)) print substr($0, 1, RLENGTH - 1) }' "$f"
}

cmd_conf_rm() {
    if [ -n "${TINYDEPLOY_HOST:-}" ] && { [ $# -lt 3 ] || ! is_host_arg "$1"; }; then
        [ $# -ge 2 ] || usage 2
        set_host ""
        APP=$1
        shift
    else
        [ $# -ge 3 ] || usage 2
        set_host "$1"
        APP=$2
        shift 2
    fi
    check_app "$APP"
    new_tmp; keysf=$NEWTMP
    keys=""
    for k in "$@"; do
        valid_key "$k" || bad "invalid key: $k"
        printf '%s\n' "$k" >> "$keysf"
        keys="$keys $k"
    done
    apply_upload deploy.conf apply_rm "$keysf" check_conf_syntax
    if [ "$CHANGED" = 1 ]; then
        for k in $keys; do echo "Removed $k."; done
        conf_note
    else
        echo "No changes."
    fi
}

cmd_conf_import() {
    case $# in
        2) set_host ""; APP=$1; src=$2 ;;
        3) set_host "$1"; APP=$2; src=$3 ;;
        *) usage 2 ;;
    esac
    check_app "$APP"
    if [ "$src" = "-" ]; then
        file=/dev/stdin
    else
        [ -f "$src" ] || die "no such file: $src"
        file=$src
    fi
    new_tmp; pairs=$NEWTMP
    keys=""
    count=0
    lineno=0
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        line=${line%"$CR"}
        case "$line" in
            "" | "#"*) continue ;;
        esac
        case "$line" in
            *=*) : ;;
            *) bad "line $lineno: expected KEY=value: $line" ;;
        esac
        key=${line%%=*}
        value=${line#*=}
        valid_key "$key" || bad "line $lineno: invalid key: $key"
        conf_key_ok "$key" || bad "line $lineno: not a deploy.conf key: $key (one of:${CONF_KEYS% })"
        printf '%s=%s\n' "$key" "$(encode_sh "$value")" >> "$pairs"
        keys="$keys $key"
        count=$((count + 1))
    done < "$file"
    if [ "$count" -eq 0 ]; then bad "no KEY=value lines in $src"; fi
    apply_upload deploy.conf apply_pairs "$pairs" check_conf_syntax
    if [ "$CHANGED" = 1 ]; then
        for k in $keys; do echo "Set $k."; done
        conf_note
    else
        echo "No changes."
    fi
}

cmd_conf_edit() {
    case $# in
        1) set_host ""; APP=$1 ;;
        2) set_host "$1"; APP=$2 ;;
        *) usage 2 ;;
    esac
    check_app "$APP"
    new_tmp; oldf=$NEWTMP
    new_tmp; newf=$NEWTMP
    if ! fetch_file deploy.conf > "$oldf"; then exit 1; fi
    cp "$oldf" "$newf"
    # $EDITOR may carry its own arguments; splitting is intentional.
    # shellcheck disable=SC2086
    ${EDITOR:-vi} "$newf" || die "editor failed"
    if cmp -s "$oldf" "$newf"; then
        echo "No changes."
        return 0
    fi
    check_conf_syntax "$newf"
    conf_warn_keys "$newf"
    if ! upload_file deploy.conf < "$newf"; then exit 1; fi
    echo "Updated deploy.conf."
    conf_note
}

cmd_conf_show() {
    case $# in
        1) set_host ""; APP=$1 ;;
        2) set_host "$1"; APP=$2 ;;
        *) usage 2 ;;
    esac
    check_app "$APP"
    new_tmp; f=$NEWTMP
    if ! fetch_file deploy.conf > "$f"; then exit 1; fi
    cat "$f"
}

# --- dispatch ----------------------------------------------------------------
cmd=${1:-}
case "$cmd" in
    init)
        shift
        cmd_init "$@"
        ;;
    env)
        shift
        sub=${1:-}
        [ -n "$sub" ] || usage 2
        shift
        RESTART=1
        while [ $# -gt 0 ]; do
            case "$1" in
                --no-restart) RESTART=0; shift ;;
                -*) usage 2 ;;
                *) break ;;
            esac
        done
        case "$sub" in
            set) cmd_env_set "$@" ;;
            get) cmd_env_get "$@" ;;
            ls) cmd_env_ls "$@" ;;
            rm) cmd_env_rm "$@" ;;
            import) cmd_env_import "$@" ;;
            edit) cmd_env_edit "$@" ;;
            *) usage 2 ;;
        esac
        ;;
    conf)
        shift
        sub=${1:-}
        [ -n "$sub" ] || usage 2
        shift
        case "${1:-}" in
            -*) usage 2 ;;
        esac
        case "$sub" in
            set) cmd_conf_set "$@" ;;
            get) cmd_conf_get "$@" ;;
            ls) cmd_conf_ls "$@" ;;
            rm) cmd_conf_rm "$@" ;;
            import) cmd_conf_import "$@" ;;
            edit) cmd_conf_edit "$@" ;;
            show) cmd_conf_show "$@" ;;
            *) usage 2 ;;
        esac
        ;;
    -h | --help | help) usage 0 ;;
    *) usage 2 ;;
esac
