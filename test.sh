#!/bin/sh
# Sandbox test for the post-receive hook and deploy.sh next to this script.
#
# DEPLOY_ROOT is faked by putting the bare repos two levels below $SB, and HOME
# is faked so the generated unit lands in the sandbox - the real systemd session
# is never touched (systemctl is a stub early on PATH). deploy.sh is driven
# through a stub ssh that runs its remote half locally against the same sandbox.
#
#   sh test.sh                 # uses $FRAMER (default ~/projects/framer) as the real-tree case
#   FRAMER= SB=/tmp/x sh test.sh
set -u

DIR=$(cd "$(dirname "$0")" && pwd)
HOOK="$DIR/post-receive"
DEPLOY="$DIR/deploy.sh"
FRAMER=${FRAMER:-$HOME/projects/framer}
SB=${SB:-${TMPDIR:-/tmp}/deploy-hook-test}

rm -rf "$SB"
mkdir -p "$SB/bin" "$SB/home" "$SB/repos" "$SB/src" "$SB/live" \
         "$SB/shared/framer" "$SB/shared/nodeapp" "$SB/shared/pyapp" "$SB/shared/weird"
export HOME="$SB/home"
export PATH="$SB/bin:$PATH"
export CALLS="$SB/calls.log"
: > "$CALLS"

fail=0
ok() { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
is_file() { if [ -f "$2" ]; then ok "$1"; else bad "$1 (missing $2)"; fi }
is_dir() { if [ -d "$2" ]; then ok "$1"; else bad "$1 (missing $2)"; fi }
is_absent() { if [ -e "$2" ]; then bad "$1 (present $2)"; else ok "$1"; fi }
has() { if grep -qF -- "$2" "$3" 2>/dev/null; then ok "$1"; else bad "$1 (no '$2' in $3)"; fi }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi }
same() { if cmp -s "$2" "$3"; then ok "$1"; else bad "$1 (files differ: $2, $3)"; fi }
is_link() { if [ -L "$2" ]; then ok "$1"; else bad "$1 (not a symlink: $2)"; fi }
links_to() { # note -> expected resolved path
    if [ -L "$2" ] && [ "$(readlink -f "$2" 2>/dev/null)" = "$3" ]; then
        ok "$1"
    else
        bad "$1 ($2 -> $(readlink "$2" 2>/dev/null || echo none), want $3)"
    fi
}

# --- fake tools ---------------------------------------------------------------
cat > "$SB/bin/pnpm" <<'FAKE'
#!/bin/sh
echo "pnpm $*" >> "$CALLS"
case "$1" in
  install) mkdir -p node_modules ;;
  build)
    if [ "${FAIL_BUILD:-}" = 1 ]; then echo "boom" >&2; exit 3; fi
    mkdir -p dist/server; echo "// built" > dist/server/entry.mjs
    ;;
esac
FAKE
cat > "$SB/bin/node" <<'FAKE'
#!/bin/sh
echo "node $*" >> "$CALLS"
FAKE
cat > "$SB/bin/uv" <<'FAKE'
#!/bin/sh
echo "uv $*" >> "$CALLS"
case "$1" in
  sync) mkdir -p .venv/bin; printf '#!/bin/sh\n' > .venv/bin/python; chmod +x .venv/bin/python ;;
esac
FAKE
cat > "$SB/bin/systemctl" <<'FAKE'
#!/bin/sh
echo "systemctl $*" >> "$CALLS"
FAKE
cat > "$SB/bin/ssh" <<'FAKE'
#!/bin/sh
# stub ssh: log the host, run the "remote" command locally in the sandbox
echo "ssh $1" >> "$CALLS"
shift
exec sh -c "$*"
FAKE
cat > "$SB/bin/editenv" <<'FAKE'
#!/bin/sh
# fake $EDITOR for env edit: append one valid line to the file given in $1
echo "EDITED=yes" >> "$1"
FAKE
cat > "$SB/bin/noedit" <<'FAKE'
#!/bin/sh
# fake $EDITOR that changes nothing
FAKE
chmod +x "$SB"/bin/*

make_repo() { # name -> bare repo whose hook symlinks the shared hook, plus env
    cp "$HOOK" "$SB/post-receive"
    chmod 755 "$SB/post-receive"
    git init --bare -q "$SB/repos/$1"
    mkdir -p "$SB/repos/$1/hooks" "$SB/shared/$1"
    ln -sfn ../../../post-receive "$SB/repos/$1/hooks/post-receive"
    printf 'DATABASE_URL=postgresql://sandbox/db\n' > "$SB/shared/$1/env"
}

app_repo() { # name -> source repo with one commit
    git init -q -b master "$SB/src/$1"
    git -C "$SB/src/$1" config user.email t@example.com
    git -C "$SB/src/$1" config user.name Test
    printf '{\n  "scripts": { "build": "astro build", "start": "node dist/server/entry.mjs" }\n}\n' > "$SB/src/$1/package.json"
    echo "lockfileVersion: '9.0'" > "$SB/src/$1/pnpm-lock.yaml"
    git -C "$SB/src/$1" add -A
    git -C "$SB/src/$1" commit -qm one
}

# --- 1. a real app tree (node, no deploy.conf) --------------------------------
if [ -d "$FRAMER/.git" ]; then
    echo "=== 1. real app repo: $FRAMER (node, no conf) ==="
    make_repo framer
    push_out=$(git -C "$FRAMER" push "$SB/repos/framer" master 2>&1); push_rc=$?
    echo "$push_out" | sed 's/^/    | /'
    eq "push succeeded" "$push_rc" 0
    HASH=$(git -C "$SB/repos/framer" rev-parse --short master)
    REL="$SB/live/framer!$HASH"
    is_file "release tree checked out" "$REL/package.json"
    is_file "real source present" "$REL/src/lib/db.ts"
    is_absent "no .env written (env comes from the unit)" "$REL/.env"
    is_file "pnpm build ran in the release" "$REL/dist/server/entry.mjs"
    is_dir "pnpm install ran in the release" "$REL/node_modules"
    has "sync command" "pnpm install --frozen-lockfile" "$CALLS"
    has "build command" "pnpm build" "$CALLS"
    UNIT="$SB/home/.config/systemd/user/framer.service"
    is_file "unit installed" "$UNIT"
    has "unit exec" "ExecStart=$SB/bin/pnpm start" "$UNIT"
    has "unit working dir" "WorkingDirectory=$SB/live/framer!CURRENT" "$UNIT"
    has "unit env file" "EnvironmentFile=-$SB/shared/framer/env" "$UNIT"
    has "unit runtime env" "Environment=NODE_ENV=production" "$UNIT"
    has "unit restart policy" "Restart=on-failure" "$UNIT"
    eq "CURRENT symlink" "$(readlink -f "$SB/live/framer!CURRENT")" "$REL"
    has "service enabled" "systemctl --user enable framer.service" "$CALLS"
    has "service restarted" "systemctl --user restart framer.service" "$CALLS"
    case "$push_out" in *"Deployed framer $HASH."*) ok "deploy summary printed" ;; *) bad "deploy summary printed" ;; esac
else
    echo "=== 1. skipped: $FRAMER is not a git work tree (set FRAMER=... to run it) ==="
fi

echo
echo "=== 2. repeat deploys: prune, branch filter, re-push guard ==="
make_repo nodeapp
links_to "repo hook symlinks the shared hook" "$SB/repos/nodeapp/hooks/post-receive" "$SB/post-receive"
app_repo nodeapp
git -C "$SB/src/nodeapp" push -q "$SB/repos/nodeapp" master
H1=$(git -C "$SB/repos/nodeapp" rev-parse --short master)
is_dir "first release" "$SB/live/nodeapp!$H1"

echo "two" > "$SB/src/nodeapp/second.txt"
git -C "$SB/src/nodeapp" add -A
git -C "$SB/src/nodeapp" commit -qm two
push2=$(git -C "$SB/src/nodeapp" push "$SB/repos/nodeapp" master 2>&1)
H2=$(git -C "$SB/repos/nodeapp" rev-parse --short master)
eq "CURRENT follows the new commit" "$(readlink -f "$SB/live/nodeapp!CURRENT")" "$SB/live/nodeapp!$H2"
is_absent "previous release pruned" "$SB/live/nodeapp!$H1"
is_file "new commit's file present" "$SB/live/nodeapp!$H2/second.txt"
case "$push2" in *"Installing nodeapp.service"*) bad "unchanged unit is not rewritten" ;; *) ok "unchanged unit is not rewritten" ;; esac

git -C "$SB/src/nodeapp" checkout -q -b feature
echo "side" > "$SB/src/nodeapp/side.txt"
git -C "$SB/src/nodeapp" add -A
git -C "$SB/src/nodeapp" commit -qm side
side_out=$(git -C "$SB/src/nodeapp" push "$SB/repos/nodeapp" feature 2>&1)
echo "$side_out" | sed 's/^/    | /'
case "$side_out" in *"no update to refs/heads/master"*) ok "side branch is a no-op" ;; *) bad "side branch is a no-op" ;; esac
eq "CURRENT unchanged after side branch" "$(readlink -f "$SB/live/nodeapp!CURRENT")" "$SB/live/nodeapp!$H2"

# redeploying the commit CURRENT already points at must not clear its files
touch "$SB/live/nodeapp!$H2/keepme"
git -C "$SB/repos/nodeapp" update-ref -d refs/heads/master
git -C "$SB/src/nodeapp" push -q "$SB/repos/nodeapp" master
is_file "live release not cleared on self-redeploy" "$SB/live/nodeapp!$H2/keepme"

del_out=$(git -C "$SB/src/nodeapp" push "$SB/repos/nodeapp" --delete feature 2>&1)
case "$del_out" in *"nothing to deploy"*) ok "branch deletion is a no-op" ;; *) bad "branch deletion is a no-op" ;; esac

echo
echo "=== 3. uv app with deploy.conf (AFTER_SYNC, UNIT_ENV placeholders) ==="
make_repo pyapp
git init -q -b master "$SB/src/pyapp"
git -C "$SB/src/pyapp" config user.email t@example.com
git -C "$SB/src/pyapp" config user.name Test
printf 'print("hi")\n' > "$SB/src/pyapp/main.py"
echo "version = 1" > "$SB/src/pyapp/uv.lock"
cat > "$SB/shared/pyapp/deploy.conf" <<'CONF'
AFTER_SYNC="uv run --no-dev oban install"
UNIT_ENV="PYTHONUNBUFFERED=1 DATA_DIR={shared}/data"
CONF
git -C "$SB/src/pyapp" add -A
git -C "$SB/src/pyapp" commit -qm one
git -C "$SB/src/pyapp" push -q "$SB/repos/pyapp" master
HP=$(git -C "$SB/repos/pyapp" rev-parse --short master)
REL_P="$SB/live/pyapp!$HP"
is_file "venv python from uv sync" "$REL_P/.venv/bin/python"
has "detected uv sync" "uv sync --locked --no-dev" "$CALLS"
has "AFTER_SYNC ran" "uv run --no-dev oban install" "$CALLS"
UNIT_P="$SB/home/.config/systemd/user/pyapp.service"
has "unit exec from detection" "ExecStart=$SB/live/pyapp!CURRENT/.venv/bin/python main.py" "$UNIT_P"
has "unit env placeholder expanded" "Environment=DATA_DIR=$SB/shared/pyapp/data" "$UNIT_P"
has "unit env from detection" "Environment=PYTHONUNBUFFERED=1" "$UNIT_P"
is_file "app tree in release" "$REL_P/main.py"

echo
echo "=== 4. failure paths ==="
# env is optional: no env file still deploys, and the unit's EnvironmentFile=
# carries the '-' prefix so systemd starts the app with the file absent.
restarts_before=$(grep -c "restart framer.service" "$CALLS" || true)
rm -f "$SB/shared/framer/env"
# a no-op push wouldn't run the hook at all, so re-create the ref first
git -C "$SB/repos/framer" update-ref -d refs/heads/master
out=$(git -C "$FRAMER" push "$SB/repos/framer" master 2>&1); rc=$?
eq "push without env succeeds" "$rc" 0
case "$out" in *"DEPLOY FAILED"*) bad "missing env does not fail the deploy"; echo "$out" ;; *) ok "missing env does not fail the deploy" ;; esac
case "$out" in *"$SB/shared/framer/env is missing - deploying without it"*) ok "missing env noted in push output" ;; *) bad "missing env noted in push output"; echo "$out" ;; esac
has "unit tolerates a missing env file" "EnvironmentFile=-$SB/shared/framer/env" "$UNIT"
eq "app restarted without env" "$(grep -c 'restart framer.service' "$CALLS")" "$((restarts_before + 1))"
eq "CURRENT holds the env-less deploy" "$(readlink -f "$SB/live/framer!CURRENT")" "$REL"
printf 'DATABASE_URL=x\n' > "$SB/shared/framer/env"

git init -q -b master "$SB/src/weird"
git -C "$SB/src/weird" config user.email t@example.com
git -C "$SB/src/weird" config user.name Test
echo hi > "$SB/src/weird/README.md"
git -C "$SB/src/weird" add -A
git -C "$SB/src/weird" commit -qm one
make_repo weird
out=$(git -C "$SB/src/weird" push "$SB/repos/weird" master 2>&1)
case "$out" in *"no uv.lock or pnpm-lock.yaml"*) ok "undetectable app fails clearly" ;; *) bad "undetectable app fails clearly"; echo "$out" ;; esac

make_repo nomain
git init -q -b master "$SB/src/nomain"
git -C "$SB/src/nomain" config user.email t@example.com
git -C "$SB/src/nomain" config user.name Test
echo "version = 1" > "$SB/src/nomain/uv.lock"
git -C "$SB/src/nomain" add -A
git -C "$SB/src/nomain" commit -qm one
out=$(git -C "$SB/src/nomain" push "$SB/repos/nomain" master 2>&1)
case "$out" in *"EXEC is empty"*) ok "uv app without main.py asks for EXEC" ;; *) bad "uv app without main.py asks for EXEC"; echo "$out" ;; esac

echo
echo "=== 5. failing build ==="
make_repo failapp
app_repo failapp
out=$(FAIL_BUILD=1 git -C "$SB/src/failapp" push "$SB/repos/failapp" master 2>&1)
case "$out" in *"DEPLOY FAILED: build failed"*) ok "build failure reported" ;; *) bad "build failure reported"; echo "$out" ;; esac
is_absent "failed build activates nothing" "$SB/live/failapp!CURRENT"
is_absent "failed build installs no unit" "$SB/home/.config/systemd/user/failapp.service"

HF=$(git -C "$SB/repos/failapp" rev-parse --short master)
is_dir "failed deploy leaves a half-made release" "$SB/live/failapp!$HF"
# the failed push already advanced the ref, so a retry needs a new commit
git -C "$SB/src/failapp" commit -q --allow-empty -m redeploy
git -C "$SB/src/failapp" push -q "$SB/repos/failapp" master
HR=$(git -C "$SB/repos/failapp" rev-parse --short master)
eq "retry deploys cleanly" "$(readlink -f "$SB/live/failapp!CURRENT")" "$SB/live/failapp!$HR"
is_absent "failed deploy's orphan release pruned" "$SB/live/failapp!$HF"

echo
echo "=== 6. deploy.sh init: fresh target, then a real push through it ==="
out=$("$DEPLOY" init eli@sg1 newapp 2>&1); rc=$?
eq "init exits 0" "$rc" 0
has "init ssh'd to the given host" "ssh eli@sg1" "$CALLS"
ISB="$SB/home/deploy"
IREPO="$ISB/repos/newapp"
eq "its repo is bare" "$(git -C "$IREPO" rev-parse --is-bare-repository 2>/dev/null)" true
same "shared hook installed" "$HOOK" "$ISB/post-receive"
if [ -x "$ISB/post-receive" ]; then ok "shared hook is executable"; else bad "shared hook is executable"; fi
is_link "repo hook is a symlink" "$IREPO/hooks/post-receive"
links_to "repo hook resolves to the shared hook" "$IREPO/hooks/post-receive" "$ISB/post-receive"
is_dir "live root created" "$ISB/live"
is_dir "shared dir created" "$ISB/shared/newapp"
is_absent "no env file fabricated" "$ISB/shared/newapp/env"
case "$out" in *"Initialized newapp on eli@sg1."*) ok "next steps printed" ;; *) bad "next steps printed"; echo "$out" | sed 's/^/    | /' ;; esac

# README step 2: set the secrets, then push through the fresh repo. env set
# creates the file (600); with no unit deployed yet it just prints a hint.
out=$("$DEPLOY" env set eli@sg1 newapp DATABASE_URL=postgresql://sandbox/db 2>&1); rc=$?
eq "env set exits 0" "$rc" 0
is_file "env file created by env set" "$ISB/shared/newapp/env"
eq "env file is 600" "$(stat -c %a "$ISB/shared/newapp/env")" 600
case "$out" in *"No unit for newapp yet"*) ok "no unit yet: env set prints a hint" ;; *) bad "no unit yet: env set prints a hint"; echo "$out" | sed 's/^/    | /' ;; esac
eq "env content written" "$(cat "$ISB/shared/newapp/env")" "DATABASE_URL=postgresql://sandbox/db"
app_repo newapp
push_out=$(git -C "$SB/src/newapp" push "$IREPO" master 2>&1)
HN=$(git -C "$IREPO" rev-parse --short master)
case "$push_out" in *"Deployed newapp $HN."*) ok "deploy summary printed" ;; *) bad "deploy summary printed"; echo "$push_out" | sed 's/^/    | /' ;; esac
IREL="$ISB/live/newapp!$HN"
is_file "release tree checked out" "$IREL/package.json"
eq "CURRENT symlink" "$(readlink -f "$ISB/live/newapp!CURRENT")" "$IREL"
UNIT_I="$SB/home/.config/systemd/user/newapp.service"
has "unit working dir" "WorkingDirectory=$ISB/live/newapp!CURRENT" "$UNIT_I"
has "service restarted" "systemctl --user restart newapp.service" "$CALLS"

# the whole update path: append to the one shared file, push, see it run
echo 'echo "shared hook v2"' >> "$ISB/post-receive"
git -C "$SB/src/newapp" commit -q --allow-empty -m two
push_out=$(git -C "$SB/src/newapp" push "$IREPO" master 2>&1)
case "$push_out" in *"shared hook v2"*) ok "one shared file updates the hook" ;; *) bad "one shared file updates the hook"; echo "$push_out" | sed 's/^/    | /' ;; esac

# re-running init refreshes the shared hook, restores the symlink, and
# touches nothing else - a regular file from an old install is replaced
rm -f "$IREPO/hooks/post-receive"
printf '#!/bin/sh\necho tampered\n' > "$IREPO/hooks/post-receive"
refs_before=$(git -C "$IREPO" show-ref)
"$DEPLOY" init eli@sg1 newapp >/dev/null 2>&1
same "re-run refreshes the shared hook" "$HOOK" "$ISB/post-receive"
is_link "re-run restores the symlink" "$IREPO/hooks/post-receive"
links_to "re-run points the repo at the shared hook" "$IREPO/hooks/post-receive" "$ISB/post-receive"
eq "re-run leaves refs alone" "$(git -C "$IREPO" show-ref)" "$refs_before"
is_file "env survives re-init" "$ISB/shared/newapp/env"

# argument validation
"$DEPLOY" init eli@sg1 'bad name' >/dev/null 2>&1; rc=$?
eq "odd app name rejected" "$rc" 2
"$DEPLOY" init eli@sg1 >/dev/null 2>&1; rc=$?
eq "HOST and APP are both required" "$rc" 2
"$DEPLOY" init eli@sg1 newapp extra >/dev/null 2>&1; rc=$?
eq "extra init arguments rejected" "$rc" 2
mkdir -p "$SB/lonely"
cp "$DEPLOY" "$SB/lonely/"
out=$("$SB/lonely/deploy.sh" init eli@sg1 newapp 2>&1); rc=$?
eq "no hook next to the script fails" "$rc" 1
case "$out" in *"no post-receive next to this script"*) ok "missing hook named in error" ;; *) bad "missing hook named in error" ;; esac

# a symlinked deploy.sh (say ~/bin/deploy.sh on PATH) must find the hook next
# to the real file, not next to the link
mkdir -p "$SB/pathdir"
ln -sfn "$DEPLOY" "$SB/pathdir/deploy.sh"
ln -sfn "$SB/pathdir/deploy.sh" "$SB/pathdir/deploy-link.sh"
out=$("$SB/pathdir/deploy-link.sh" init eli@sg1 linked 2>&1); rc=$?
eq "symlinked deploy.sh init exits 0" "$rc" 0
case "$out" in *"Initialized linked on eli@sg1."*) ok "symlinked init reports success" ;; *) bad "symlinked init reports success"; echo "$out" | sed 's/^/    | /' ;; esac
same "symlinked init installs the real hook" "$HOOK" "$ISB/post-receive"
is_dir "symlinked init created the repo" "$ISB/repos/linked"

echo
echo "=== 7. deploy.sh env: set/get/ls/rm/import/edit ==="
ENVFILE="$ISB/shared/newapp/env"
WEIRD="a b \"c\" #d \$e 'f'"

# multi set: an ordinary key and one that needs quoting; the unit now exists,
# so the change must restart the service
restarts_before=$(grep -c "restart newapp.service" "$CALLS" || true)
out=$("$DEPLOY" env set eli@sg1 newapp API_KEY=sk-123 "WEIRD=$WEIRD" 2>&1); rc=$?
eq "env set exits 0" "$rc" 0
case "$out" in *"Set API_KEY."*"Set WEIRD."*) ok "set names the keys" ;; *) bad "set names the keys"; echo "$out" | sed 's/^/    | /' ;; esac
eq "get returns the plain value" "$("$DEPLOY" env get eli@sg1 newapp API_KEY)" "sk-123"
eq "weird value round-trips" "$("$DEPLOY" env get eli@sg1 newapp WEIRD)" "$WEIRD"
if grep -q '^WEIRD="' "$ENVFILE"; then ok "weird value quoted in the file"; else bad "weird value quoted in the file"; fi
eq "changed env restarted the service" "$(grep -c 'restart newapp.service' "$CALLS")" "$((restarts_before + 1))"
case "$("$DEPLOY" env ls eli@sg1 newapp)" in
    *DATABASE_URL*API_KEY*WEIRD*) ok "ls lists keys" ;;
    *) bad "ls lists keys" ;;
esac

# set again: the key's line is replaced, not duplicated; no-op skips restarts
"$DEPLOY" env set eli@sg1 newapp API_KEY=sk-456 >/dev/null 2>&1
eq "re-set replaces the value" "$("$DEPLOY" env get eli@sg1 newapp API_KEY)" "sk-456"
eq "re-set does not duplicate the key" "$(grep -c '^API_KEY=' "$ENVFILE")" 1
restarts_before=$(grep -c "restart newapp.service" "$CALLS" || true)
out=$("$DEPLOY" env set eli@sg1 newapp API_KEY=sk-456 2>&1)
case "$out" in *"No changes."*) ok "no-op set prints No changes." ;; *) bad "no-op set prints No changes." ;; esac
eq "no-op set restarts nothing" "$(grep -c 'restart newapp.service' "$CALLS")" "$restarts_before"
out=$("$DEPLOY" env set --no-restart eli@sg1 newapp API_KEY=sk-789 2>&1)
case "$out" in *"Set API_KEY."*) ok "set --no-restart still writes" ;; *) bad "set --no-restart still writes" ;; esac
eq "set --no-restart restarts nothing" "$(grep -c 'restart newapp.service' "$CALLS")" "$restarts_before"

# hidden prompt (stdin is a pipe, so it reads without a tty)
printf 'prompted-secret\n' | "$DEPLOY" env set eli@sg1 newapp PROMPTED >/dev/null 2>&1; rc=$?
eq "prompted set exits 0" "$rc" 0
eq "prompted value stored" "$("$DEPLOY" env get eli@sg1 newapp PROMPTED)" "prompted-secret"

# rm: removes a key, then refuses a missing one without writing
"$DEPLOY" env rm eli@sg1 newapp PROMPTED >/dev/null 2>&1; rc=$?
eq "rm exits 0" "$rc" 0
"$DEPLOY" env get eli@sg1 newapp PROMPTED >/dev/null 2>&1; rc=$?
eq "removed key is gone" "$rc" 1
cp "$ENVFILE" "$SB/env.before"
"$DEPLOY" env rm eli@sg1 newapp NOPE >/dev/null 2>&1; rc=$?
eq "rm of missing key exits 1" "$rc" 1
same "rm of missing key wrote nothing" "$SB/env.before" "$ENVFILE"

# validation: bad key, and an app that was never initialized
cp "$ENVFILE" "$SB/env.before"
"$DEPLOY" env set eli@sg1 newapp '1BAD=x' >/dev/null 2>&1; rc=$?
eq "bad key exits 2" "$rc" 2
same "bad key wrote nothing" "$SB/env.before" "$ENVFILE"
out=$("$DEPLOY" env set eli@sg1 ghost KEY=1 2>&1); rc=$?
eq "uninitialized app exits 1" "$rc" 1
case "$out" in *"not initialized"*) ok "uninitialized app named in error" ;; *) bad "uninitialized app named in error" ;; esac

# import: comments and blanks are skipped, values are merged; bad input aborts
cat > "$SB/import.env" <<'EOF'
# secrets for newapp
FROMFILE=two words

EMPTY=
EOF
out=$("$DEPLOY" env import eli@sg1 newapp "$SB/import.env" 2>&1); rc=$?
eq "import exits 0" "$rc" 0
eq "import applied a quoted value" "$("$DEPLOY" env get eli@sg1 newapp FROMFILE)" "two words"
eq "import applied an empty value" "$("$DEPLOY" env get eli@sg1 newapp EMPTY)" ""
if grep -q 'secrets for newapp' "$ENVFILE"; then bad "import does not copy comments"; else ok "import does not copy comments"; fi
printf 'FROMSTDIN=1\n' | "$DEPLOY" env import eli@sg1 newapp - >/dev/null 2>&1; rc=$?
eq "import from stdin exits 0" "$rc" 0
eq "import from stdin applied" "$("$DEPLOY" env get eli@sg1 newapp FROMSTDIN)" 1
printf 'not a pair\n' > "$SB/bad.env"
cp "$ENVFILE" "$SB/env.before"
"$DEPLOY" env import eli@sg1 newapp "$SB/bad.env" >/dev/null 2>&1; rc=$?
eq "bad import exits 2" "$rc" 2
same "bad import wrote nothing" "$SB/env.before" "$ENVFILE"

# edit: the fake editor appends a line; a no-change editor uploads nothing
EDITOR="$SB/bin/editenv" "$DEPLOY" env edit eli@sg1 newapp >/dev/null 2>&1; rc=$?
eq "edit exits 0" "$rc" 0
eq "edit applied" "$("$DEPLOY" env get eli@sg1 newapp EDITED)" "yes"
restarts_before=$(grep -c "restart newapp.service" "$CALLS" || true)
out=$(EDITOR="$SB/bin/noedit" "$DEPLOY" env edit eli@sg1 newapp 2>&1); rc=$?
eq "no-op edit exits 0" "$rc" 0
case "$out" in *"No changes."*) ok "no-op edit prints No changes." ;; *) bad "no-op edit prints No changes." ;; esac
eq "no-op edit restarts nothing" "$(grep -c 'restart newapp.service' "$CALLS")" "$restarts_before"

echo
echo "=== 8. deploy.sh conf: managed deploy.conf ==="
CONF="$ISB/shared/newapp/deploy.conf"
restarts_before=$(grep -c "restart newapp.service" "$CALLS" || true)
# Hand-written file: the comment and the old quoting must survive a managed write.
cat > "$CONF" <<'CONFEOF'
# host-specific tweaks
BUILD="pnpm build --verbose"
CONFEOF
chmod 600 "$CONF"

out=$("$DEPLOY" conf set eli@sg1 newapp EXEC="node server.js" 'UNIT_ENV=PORT={shared}/port' 2>&1); rc=$?
eq "conf set exits 0" "$rc" 0
case "$out" in *"Set EXEC."*"Set UNIT_ENV."*) ok "conf set names the keys" ;; *) bad "conf set names the keys"; echo "$out" | sed 's/^/    | /' ;; esac
eq "conf get returns the command" "$("$DEPLOY" conf get eli@sg1 newapp EXEC)" "node server.js"
eq "conf get returns placeholders verbatim" "$("$DEPLOY" conf get eli@sg1 newapp UNIT_ENV)" "PORT={shared}/port"
eq "deploy.conf is 600" "$(stat -c %a "$CONF")" 600
has "hand-written comment survives" "host-specific tweaks" "$CONF"
has "hand-written line survives" 'BUILD="pnpm build --verbose"' "$CONF"
case "$("$DEPLOY" conf ls eli@sg1 newapp)" in
    *BUILD*EXEC*UNIT_ENV*) ok "conf ls lists overridden keys" ;;
    *) bad "conf ls lists overridden keys" ;;
esac
eq "conf changes restart nothing" "$(grep -c 'restart newapp.service' "$CALLS")" "$restarts_before"

# a value carrying a single quote round-trips through the sh encoding
"$DEPLOY" conf set eli@sg1 newapp "AFTER_SYNC=echo 'after sync'" >/dev/null 2>&1
out=$("$DEPLOY" conf get eli@sg1 newapp AFTER_SYNC)
eq "quoted command round-trips" "$out" "echo 'after sync'"
if grep -q "^AFTER_SYNC='" "$CONF"; then ok "command stored single-quoted"; else bad "command stored single-quoted"; fi

# re-set replaces the line in place; a no-op uploads and restarts nothing
"$DEPLOY" conf set eli@sg1 newapp 'BUILD=pnpm build' >/dev/null 2>&1
eq "re-set replaces the value" "$("$DEPLOY" conf get eli@sg1 newapp BUILD)" "pnpm build"
eq "re-set does not duplicate the key" "$(grep -c '^BUILD=' "$CONF")" 1
has "comment survives a re-set" "host-specific tweaks" "$CONF"
out=$("$DEPLOY" conf set eli@sg1 newapp 'BUILD=pnpm build' 2>&1)
case "$out" in *"No changes."*) ok "no-op conf set prints No changes." ;; *) bad "no-op conf set prints No changes." ;; esac
eq "no-op conf set restarts nothing" "$(grep -c 'restart newapp.service' "$CALLS")" "$restarts_before"

# unknown keys and syntax errors are refused before anything is uploaded
cp "$CONF" "$SB/conf.before"
out=$("$DEPLOY" conf set eli@sg1 newapp EXE=nope 2>&1); rc=$?
eq "unknown conf key exits 2" "$rc" 2
same "unknown conf key wrote nothing" "$SB/conf.before" "$CONF"
case "$out" in *"not a deploy.conf key"*) ok "unknown key named in error" ;; *) bad "unknown key named in error" ;; esac
cat > "$SB/bin/badconf" <<'FAKE'
#!/bin/sh
echo 'EXEC="unclosed' > "$1"
FAKE
chmod +x "$SB/bin/badconf"
out=$(EDITOR="$SB/bin/badconf" "$DEPLOY" conf edit eli@sg1 newapp 2>&1); rc=$?
eq "syntax-broken edit exits 2" "$rc" 2
same "syntax-broken edit wrote nothing" "$SB/conf.before" "$CONF"
case "$out" in *"syntax error"*) ok "syntax error named in error" ;; *) bad "syntax error named in error" ;; esac

# edit warns about keys this hook does not read, but keeps them
cat > "$SB/bin/extraconf" <<'FAKE'
#!/bin/sh
echo 'DATA_DIR=/srv/data' >> "$1"
FAKE
chmod +x "$SB/bin/extraconf"
out=$(EDITOR="$SB/bin/extraconf" "$DEPLOY" conf edit eli@sg1 newapp 2>&1); rc=$?
eq "edit with an unmanaged key exits 0" "$rc" 0
case "$out" in *"DATA_DIR is not read by the hook"*) ok "unmanaged key is warned about" ;; *) bad "unmanaged key is warned about"; echo "$out" | sed 's/^/    | /' ;; esac
eq "edit uploads the unmanaged key" "$("$DEPLOY" conf get eli@sg1 newapp DATA_DIR)" "/srv/data"

# rm: a managed key goes, a missing one refuses without writing
"$DEPLOY" conf rm eli@sg1 newapp DATA_DIR >/dev/null 2>&1; rc=$?
eq "conf rm exits 0" "$rc" 0
"$DEPLOY" conf get eli@sg1 newapp DATA_DIR >/dev/null 2>&1; rc=$?
eq "removed conf key is gone" "$rc" 1
cp "$CONF" "$SB/conf.before"
"$DEPLOY" conf rm eli@sg1 newapp NOPE >/dev/null 2>&1; rc=$?
eq "rm of missing conf key exits 1" "$rc" 1
same "rm of missing conf key wrote nothing" "$SB/conf.before" "$CONF"

# import: same file format as env import, allowlisted
cat > "$SB/conf.import" <<'EOF'
# commands from a file
SYNC=pnpm install --frozen-lockfile
EOF
out=$("$DEPLOY" conf import eli@sg1 newapp "$SB/conf.import" 2>&1); rc=$?
eq "conf import exits 0" "$rc" 0
eq "conf import applied" "$("$DEPLOY" conf get eli@sg1 newapp SYNC)" "pnpm install --frozen-lockfile"
printf 'NOPE=1\n' > "$SB/conf.bad"
cp "$CONF" "$SB/conf.before"
"$DEPLOY" conf import eli@sg1 newapp "$SB/conf.bad" >/dev/null 2>&1; rc=$?
eq "unknown import key exits 2" "$rc" 2
same "unknown import key wrote nothing" "$SB/conf.before" "$CONF"

out=$("$DEPLOY" conf show eli@sg1 newapp)
case "$out" in *"host-specific tweaks"*"SYNC="*) ok "conf show prints the file" ;; *) bad "conf show prints the file" ;; esac
eq "no conf command restarted the service" "$(grep -c 'restart newapp.service' "$CALLS")" "$restarts_before"

out=$("$DEPLOY" conf show eli@sg1 ghost 2>&1); rc=$?
eq "conf on an uninitialized app exits 1" "$rc" 1
case "$out" in *"not initialized"*) ok "conf names the uninitialized app" ;; *) bad "conf names the uninitialized app" ;; esac

# the change lands with the next push, not with the command
push_out=$(git -C "$SB/src/newapp" commit -q --allow-empty -m conf && git -C "$SB/src/newapp" push "$IREPO" master 2>&1)
HCONF=$(git -C "$IREPO" rev-parse --short master)
case "$push_out" in *"after sync"*) ok "conf AFTER_SYNC ran on push" ;; *) bad "conf AFTER_SYNC ran on push"; echo "$push_out" | sed 's/^/    | /' ;; esac
UNIT_I="$SB/home/.config/systemd/user/newapp.service"
has "conf EXEC reaches the unit" "ExecStart=node server.js" "$UNIT_I"
has "conf UNIT_ENV placeholder expanded on deploy" "Environment=PORT=$ISB/shared/newapp/port" "$UNIT_I"
case "$(cat "$UNIT_I")" in *"ExecStart=$SB/bin/pnpm start"*) bad "conf EXEC overrides detection" ;; *) ok "conf EXEC overrides detection" ;; esac
case "$(cat "$UNIT_I")" in *"Environment=NODE_ENV=production"*) bad "conf UNIT_ENV overrides detection" ;; *) ok "conf UNIT_ENV overrides detection" ;; esac

# a hand-broken file fails the push loudly and activates nothing
printf 'EXEC="unclosed\n' > "$CONF"
git -C "$SB/src/newapp" commit -q --allow-empty -m broken
out=$(git -C "$SB/src/newapp" push "$IREPO" master 2>&1)
case "$out" in *"DEPLOY FAILED: syntax error in"*) ok "broken deploy.conf fails the push" ;; *) bad "broken deploy.conf fails the push"; echo "$out" | sed 's/^/    | /' ;; esac
eq "broken deploy.conf activates nothing" "$(readlink -f "$ISB/live/newapp!CURRENT")" "$ISB/live/newapp!$HCONF"

echo
echo "=== 9. HOST from TINYDEPLOY_HOST ==="
# The variable stands in for HOST; an explicit HOST still wins. The stub ssh
# runs locally, so the sandbox paths are shared - the calls log proves which
# host each command asked for.
out=$(TINYDEPLOY_HOST=eli@sg9 "$DEPLOY" init envhost 2>&1); rc=$?
eq "env host: init exits 0" "$rc" 0
eq "env host: init ssh'd there" "$(tail -n 1 "$CALLS")" "ssh eli@sg9"
is_dir "env host: repo created" "$ISB/repos/envhost"
case "$out" in *"Initialized envhost on eli@sg9."*) ok "env host: init names the host" ;; *) bad "env host: init names the host"; echo "$out" | sed 's/^/    | /' ;; esac

out=$(TINYDEPLOY_HOST=wrong@host "$DEPLOY" init eli@sg1 argapp 2>&1); rc=$?
eq "explicit HOST: init exits 0" "$rc" 0
eq "explicit HOST: init ssh'd there" "$(tail -n 1 "$CALLS")" "ssh eli@sg1"
case "$out" in *"Initialized argapp on eli@sg1."*) ok "explicit HOST: named in output" ;; *) bad "explicit HOST: named in output" ;; esac

# fixed-shape commands: APP first when the variable is set
TINYDEPLOY_HOST=eli@sg9 "$DEPLOY" env set envhost DATABASE_URL=postgresql://sandbox/db >/dev/null 2>&1; rc=$?
eq "env host: env set exits 0" "$rc" 0
eq "env host: env set ssh'd there" "$(tail -n 1 "$CALLS")" "ssh eli@sg9"
eq "env host: env set wrote the value" "$(cat "$ISB/shared/envhost/env")" "DATABASE_URL=postgresql://sandbox/db"
eq "env host: env get reads it back" "$(TINYDEPLOY_HOST=eli@sg9 "$DEPLOY" env get envhost DATABASE_URL)" "postgresql://sandbox/db"
TINYDEPLOY_HOST=eli@sg9 "$DEPLOY" env set --no-restart envhost DELTA=4 >/dev/null 2>&1; rc=$?
eq "env host: --no-restart with omitted HOST" "$rc" 0

# variadic commands: APP first, or user@host first to override the variable
TINYDEPLOY_HOST=eli@sg9 "$DEPLOY" env set envhost ALPHA=1 BETA=2 >/dev/null 2>&1; rc=$?
eq "env host: variadic env set exits 0" "$rc" 0
eq "env host: variadic env set wrote ALPHA" "$(TINYDEPLOY_HOST=eli@sg9 "$DEPLOY" env get envhost ALPHA)" 1
eq "env host: variadic env set wrote BETA" "$(TINYDEPLOY_HOST=eli@sg9 "$DEPLOY" env get envhost BETA)" 2
TINYDEPLOY_HOST=wrong@host "$DEPLOY" env set eli@sg2 envhost GAMMA=3 >/dev/null 2>&1; rc=$?
eq "explicit HOST: variadic set exits 0" "$rc" 0
eq "explicit HOST: variadic set ssh'd there" "$(tail -n 1 "$CALLS")" "ssh eli@sg2"
eq "explicit HOST: variadic set wrote the value" "$(TINYDEPLOY_HOST=eli@sg9 "$DEPLOY" env get envhost GAMMA)" 3
TINYDEPLOY_HOST=eli@sg9 "$DEPLOY" env rm envhost ALPHA >/dev/null 2>&1; rc=$?
eq "env host: variadic rm exits 0" "$rc" 0
TINYDEPLOY_HOST= "$DEPLOY" env get eli@sg9 envhost ALPHA >/dev/null 2>&1; rc=$?
eq "env host: variadic rm removed the key" "$rc" 1

# conf: fixed and variadic forms
TINYDEPLOY_HOST=eli@sg9 "$DEPLOY" conf set envhost EXEC="node server.js" >/dev/null 2>&1; rc=$?
eq "env host: conf set exits 0" "$rc" 0
eq "env host: conf get reads it back" "$(TINYDEPLOY_HOST=eli@sg9 "$DEPLOY" conf get envhost EXEC)" "node server.js"
TINYDEPLOY_HOST=wrong@host "$DEPLOY" conf rm eli@sg3 envhost EXEC >/dev/null 2>&1; rc=$?
eq "explicit HOST: variadic conf rm exits 0" "$rc" 0
eq "explicit HOST: variadic conf rm ssh'd there" "$(tail -n 1 "$CALLS")" "ssh eli@sg3"

# neither the argument nor the variable: a clear error, and APP is still checked
out=$(TINYDEPLOY_HOST= "$DEPLOY" init lonelyapp 2>&1); rc=$?
eq "no HOST and no variable exits 2" "$rc" 2
case "$out" in *TINYDEPLOY_HOST*) ok "no HOST error names the variable" ;; *) bad "no HOST error names the variable"; echo "$out" | sed 's/^/    | /' ;; esac
TINYDEPLOY_HOST=eli@sg9 "$DEPLOY" init 'bad name' >/dev/null 2>&1; rc=$?
eq "env host: bad APP still rejected" "$rc" 2

echo
if [ "$fail" = 0 ]; then echo "ALL PASS"; else echo "FAILURES PRESENT"; fi
exit "$fail"
