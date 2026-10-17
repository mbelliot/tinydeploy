#!/bin/sh
#
set -eu

UV=${HOME}/.local/bin/uv

REPO_DIR=$(git rev-parse --absolute-git-dir)
REPO_NAME=$(basename "$REPO_DIR")
HASH=$(git rev-parse --short HEAD)

DEPLOY_ROOT=$(cd "$REPO_DIR/../.." && pwd)
LIVE_ROOT="${DEPLOY_ROOT}/live"

LIVE_DIR="${LIVE_ROOT}/${REPO_NAME}!${HASH}"
LIVE_DIR_CURR="${LIVE_ROOT}/${REPO_NAME}!CURRENT"
SHARED_DIR="${DEPLOY_ROOT}/shared/${REPO_NAME}"
SHARED_ENV="${SHARED_DIR}/env"

mkdir -p "$SHARED_DIR"
mkdir -p "$LIVE_DIR"
echo "Checking out tree..."
git --work-tree="$LIVE_DIR" checkout -f HEAD -- .
export UV_COMPILE_BYTECODE=1
cd "$LIVE_DIR"
echo "Syncing deps..."
${UV} sync --locked --no-dev

# Oban specific
set -a
. "$SHARED_ENV"
set +a
"$UV" run --no-dev oban install

UNIT_FILE="${HOME}/.config/systemd/user/${REPO_NAME}.service"
if [ ! -f "$UNIT_FILE" ]; then
    echo "Installing service..."
    mkdir -p "$(dirname "$UNIT_FILE")"
    cat > "$UNIT_FILE" <<EOF
[Unit]
Description=${REPO_NAME}
After=network.target
[Service]
Type=simple
WorkingDirectory=${LIVE_DIR_CURR}
ExecStart=${LIVE_DIR_CURR}/.venv/bin/python main.py
Restart=on-failure
RestartSec=5
Environment=PYTHONUNBUFFERED=1
Environment=DATA_DIR=${SHARED_DIR}/data
EnvironmentFile=${SHARED_ENV}
[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable "${REPO_NAME}.service"
fi

OLD_TARGET=""
if [ -L "$LIVE_DIR_CURR" ] && [ -e "$LIVE_DIR_CURR" ]; then
    OLD_TARGET=$(readlink -f "$LIVE_DIR_CURR")
fi

echo "Linking current -> ${HASH}..."
cd "$LIVE_ROOT"
ln -sfn "$(basename "$LIVE_DIR")" "$(basename "$LIVE_DIR_CURR")"

echo "Reloading service..."
systemctl --user restart "${REPO_NAME}.service"

if [ -n "$OLD_TARGET" ] && [ "$OLD_TARGET" != "$LIVE_DIR" ]; then
    echo "Removing previous deploy at ${OLD_TARGET}..."
    rm -rf "$OLD_TARGET"
fi
