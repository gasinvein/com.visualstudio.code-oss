#!/bin/bash

set -e
set -o pipefail

while getopts ":m:n:t:c:" opt; do
    case "$opt" in
        m)
            MANIFEST_PATH="$OPTARG"
        ;;
        n)
            APP_MODULE_NAME="$OPTARG"
        ;;
        t)
            TOOLS_CLONE_DIR="$OPTARG"
        ;;
        c)
            APP_CLONE_DIR="$OPTARG"
        ;;
        *)
            exit 1
        ;;
    esac
done

function query_manifest() {
    mf_path="$1"
    jq_query="$2"
    if [[ "$mf_path" =~ .*\.(yml|yaml) ]]; then
        python3 -c 'import sys, yaml, json; json.dump(yaml.safe_load(sys.stdin), sys.stdout)' \
        < "$mf_path" | jq -e -r "$jq_query"
    elif [[ "$mf_path" =~ .*\.json ]]; then
        jq -e -r "$jq_query" < "$mf_path"
    else
        return 1
    fi
}

TOOLS_CLONE_URL="https://github.com/flatpak/flatpak-builder-tools.git"
TOOLS_CLONE_DIR="${TOOLS_CLONE_DIR:-$(mktemp -d --suffix=.flatpak-builder-tools)}"

if [ ! -f "$MANIFEST_PATH" ]; then
    exit 1
fi

read -r FLATPAK_ID < <(
    query_manifest "$MANIFEST_PATH" 'if has("app-id") then ."app-id" else .id end'
)
FLATPAK_DIR="$(dirname "$(realpath -s "$MANIFEST_PATH")")"
GENERATED_SOURCES="generated-sources.json"

APP_MODULE_NAME="${APP_MODULE_NAME:-${FLATPAK_ID##*.}}"
APP_CLONE_DIR="${APP_CLONE_DIR:-$(mktemp -d --suffix=".$APP_MODULE_NAME")}"

JQ_QUERY_SRC_CMD="
.modules[] | objects | select(.name==\"$APP_MODULE_NAME\") | .sources[] | objects |
select(.type==\"git\" and .dest==\"main\") | \"\\(.url)\\t\\(.tag)\\t\\(.commit)\"
"
JQ_QUERY_PATCHES_CMD="
.modules[] | objects | select(.name==\"$APP_MODULE_NAME\") | .sources[] | objects |
select(.type==\"patch\" and .dest==\"main\") | .paths[]
"

read -r APP_CLONE_URL APP_SRC_TAG APP_SRC_COMMIT < <(
    query_manifest "$MANIFEST_PATH" "$JQ_QUERY_SRC_CMD"
)
mapfile -t APP_PATCHES < <(
    query_manifest "$MANIFEST_PATH" "$JQ_QUERY_PATCHES_CMD"
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
