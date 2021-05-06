#!/bin/bash

set -e
set -o pipefail

while getopts ":t:s:" opt; do
    case "$opt" in
        t)
            TOOLS_CLONE_DIR="$OPTARG"
        ;;
        s)
            APP_CLONE_DIR="$OPTARG"
        ;;
        *)
            exit 1
        ;;
    esac
done


TOOLS_CLONE_URL="https://github.com/flatpak/flatpak-builder-tools.git"
TOOLS_CLONE_DIR="${TOOLS_CLONE_DIR:-$(mktemp -d --suffix=.flatpak-builder-tools)}"

FLATPAK_ID="com.visualstudio.code-oss"
GENERATED_SOURCES="generated-sources.json"
FLATPAK_DIR="$(pwd)"
APP_MODULE_NAME="vscode"
APP_CLONE_DIR="${APP_CLONE_DIR:-$(mktemp -d --suffix=".$APP_MODULE_NAME")}"

PY_YAML_DUMP_CMD='
import sys, yaml, json; json.dump(yaml.safe_load(sys.stdin), sys.stdout)
'
JQ_QUERY_SRC_CMD="
.modules[] | objects | select(.name==\"$APP_MODULE_NAME\") | .sources[] | objects |
select(.type==\"git\" and .dest==\"main\") | \"\\(.url)\\t\\(.tag)\\t\\(.commit)\"
"
JQ_QUERY_PATCHES_CMD="
.modules[] | objects | select(.name==\"$APP_MODULE_NAME\") | .sources[] | objects |
select(.type==\"patch\" and .dest==\"main\") | .paths[]
"

read -r APP_CLONE_URL APP_SRC_TAG APP_SRC_COMMIT < <(
    python3 -c "$PY_YAML_DUMP_CMD" < "$FLATPAK_ID.yml" | jq -r "$JQ_QUERY_SRC_CMD"
)
mapfile -t APP_PATCHES < <(
    python3 -c "$PY_YAML_DUMP_CMD" < "$FLATPAK_ID.yml" | jq -r "$JQ_QUERY_PATCHES_CMD"
)

if [ ! -d "$TOOLS_CLONE_DIR/.git" ]; then
    git clone -q --depth=1 -b "master" "$TOOLS_CLONE_URL" "$TOOLS_CLONE_DIR"
fi

if [ -d "$APP_CLONE_DIR/.git" ]; then
    pushd "$APP_CLONE_DIR"
    git fetch "$APP_CLONE_URL" "$APP_SRC_TAG"
    git checkout "$APP_SRC_TAG"
    popd
else
    git clone -q --depth=1 -b "$APP_SRC_TAG" "$APP_CLONE_URL" "$APP_CLONE_DIR"
fi

pushd "$APP_CLONE_DIR"
git checkout "$APP_SRC_COMMIT"
for patch_file in "${APP_PATCHES[@]}"; do
    patch -p1 < "$FLATPAK_DIR/$patch_file"
done
popd

python3 -u "$TOOLS_CLONE_DIR/node/flatpak-node-generator.py" \
    --electron-ffmpeg=archive --electron-node-headers --xdg-layout \
    -o "$FLATPAK_DIR/$GENERATED_SOURCES" \
    -r yarn "$APP_CLONE_DIR/yarn.lock"

git add "$GENERATED_SOURCES"
git commit -a -m "Update $GENERATED_SOURCES for ${APP_CLONE_URL##*/} $APP_SRC_TAG"
