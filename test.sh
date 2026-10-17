#!/bin/sh
# Sandbox test for the post-receive hook and init-app.sh next to this script.
#
# DEPLOY_ROOT is faked by putting the bare repos two levels below $SB, and HOME
# is faked so the generated unit lands in the sandbox - the real systemd session
# is never touched (systemctl is a stub early on PATH). init-app.sh is driven
# through a stub ssh that runs its remote half locally against the same sandbox.
#
#   sh test.sh                 # uses $FRAMER (default ~/projects/framer) as the real-tree case
#   FRAMER= SB=/tmp/x sh test.sh
set -u

DIR=$(cd "$(dirname "$0")" && pwd)
HOOK="$DIR/post-receive"
INITAPP="$DIR/init-app.sh"
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
    has "unit env file" "EnvironmentFile=$SB/shared/framer/env" "$UNIT"
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
restarts_before=$(grep -c "restart framer.service" "$CALLS" || true)
rm -f "$SB/shared/framer/env"
# a no-op push wouldn't run the hook at all, so re-create the ref first
git -C "$SB/repos/framer" update-ref -d refs/heads/master
out=$(git -C "$FRAMER" push "$SB/repos/framer" master 2>&1); rc=$?
case "$out" in *"DEPLOY FAILED"*) ok "missing shared env fails loudly" ;; *) bad "missing shared env fails loudly"; echo "$out" ;; esac
eq "no restart after failed deploy" "$(grep -c 'restart framer.service' "$CALLS")" "$restarts_before"
eq "CURRENT untouched by failed deploy" "$(readlink -f "$SB/live/framer!CURRENT")" "$REL"
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
echo "=== 6. init-app.sh: fresh target, then a real push through it ==="
out=$("$INITAPP" eli@sg1 newapp 2>&1); rc=$?
eq "init-app exits 0" "$rc" 0
has "init-app ssh'd to the given host" "ssh eli@sg1" "$CALLS"
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

# README step 2: the secrets file, then a push through the fresh repo
printf 'DATABASE_URL=postgresql://sandbox/db\n' > "$ISB/shared/newapp/env"
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

# re-running init-app refreshes the shared hook, restores the symlink, and
# touches nothing else - a regular file from an old install is replaced
rm -f "$IREPO/hooks/post-receive"
printf '#!/bin/sh\necho tampered\n' > "$IREPO/hooks/post-receive"
refs_before=$(git -C "$IREPO" show-ref)
"$INITAPP" eli@sg1 newapp >/dev/null 2>&1
same "re-run refreshes the shared hook" "$HOOK" "$ISB/post-receive"
is_link "re-run restores the symlink" "$IREPO/hooks/post-receive"
links_to "re-run points the repo at the shared hook" "$IREPO/hooks/post-receive" "$ISB/post-receive"
eq "re-run leaves refs alone" "$(git -C "$IREPO" show-ref)" "$refs_before"
is_file "env survives re-init" "$ISB/shared/newapp/env"

# argument validation
"$INITAPP" eli@sg1 'bad name' >/dev/null 2>&1; rc=$?
eq "odd app name rejected" "$rc" 2
"$INITAPP" eli@sg1 >/dev/null 2>&1; rc=$?
eq "HOST and APP are both required" "$rc" 2
mkdir -p "$SB/lonely"
cp "$INITAPP" "$SB/lonely/"
out=$("$SB/lonely/init-app.sh" eli@sg1 newapp 2>&1); rc=$?
eq "no hook next to the script fails" "$rc" 1
case "$out" in *"no post-receive next to this script"*) ok "missing hook named in error" ;; *) bad "missing hook named in error" ;; esac

echo
if [ "$fail" = 0 ]; then echo "ALL PASS"; else echo "FAILURES PRESENT"; fi
exit "$fail"
