#!/bin/sh
#
# init-app.sh - set up a new app's deploy target on a host.
#
#   ./init-app.sh HOST APP        # e.g. ./init-app.sh eli@sg1 framer
#
# Runs over ssh the manual install from the README:
#   ~/deploy/post-receive         the one hook file, refreshed from next to
#                                 this script on every run
#   ~/deploy/repos/APP            bare repo (the push target)
#   ~/deploy/repos/APP/hooks/post-receive  symlink -> ../../../post-receive
#   ~/deploy/live                 release root (the hook fills it)
#   ~/deploy/shared/APP           per-app env / deploy.conf
# Re-running is safe: the shared hook (and this app's symlink) is refreshed, so
# every app on the host picks up the update; the repo, dirs and files are left
# alone.
set -eu

if [ $# -ne 2 ]; then
    echo "usage: $0 HOST APP" >&2
    exit 2
fi

HOST=$1
APP=$2
HOOK=$(cd "$(dirname "$0")" && pwd)/post-receive

# APP names the repo, the shared dir, and the systemd unit - keep it to plain
# characters (the hook also globs "APP!*" over the release dirs).
case "$APP" in
    "" | *[!A-Za-z0-9._-]*)
        echo "init-app: APP may only be letters, digits, '.', '_' and '-': $APP" >&2
        exit 2 ;;
esac

if [ ! -f "$HOOK" ]; then
    echo "init-app: no post-receive next to this script ($HOOK)." >&2
    exit 1
fi

# The hook rides in on stdin, exactly like a manual install; the remote shell
# makes the dirs and the repo, refreshes the one shared hook file, and points
# this app's hook at it.
ssh "$HOST" "set -e
    mkdir -p ~/deploy/repos ~/deploy/live ~/deploy/shared/$APP
    cat > ~/deploy/post-receive
    chmod 755 ~/deploy/post-receive
    git init --bare ~/deploy/repos/$APP >/dev/null
    ln -sfn ../../../post-receive ~/deploy/repos/$APP/hooks/post-receive" < "$HOOK"

cat <<EOF
Initialized $APP on $HOST. Next:
  1. app secrets:  ssh $HOST 'printf "VAR=...\n" > ~/deploy/shared/$APP/env'
  2. push:         git remote add deploy $HOST:deploy/repos/$APP && git push deploy master
EOF
