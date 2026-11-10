#!/bin/sh
set -eu

: "${DEV_INSTANCE_DIR:?Set DEV_INSTANCE_DIR to an absolute instance directory}"
case $DEV_INSTANCE_DIR in
    /*) ;;
    *) printf '%s\n' 'DEV_INSTANCE_DIR must be an absolute path.' >&2; exit 1 ;;
esac

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

umask 077
mkdir -p "$DEV_INSTANCE_DIR/mail"
if [ ! -e "$DEV_INSTANCE_DIR/.gitignore" ]; then
    printf '*\n' > "$DEV_INSTANCE_DIR/.gitignore"
fi
if [ ! -e "$DEV_INSTANCE_DIR/.env" ]; then
    cp "$repo_dir/.env.example" "$DEV_INSTANCE_DIR/.env"
fi
if [ ! -e "$DEV_INSTANCE_DIR/mail/provision.ndjson" ]; then
    cp "$repo_dir/dev/mail/provision.example.ndjson" "$DEV_INSTANCE_DIR/mail/provision.ndjson"
fi

printf 'Development configuration: %s/.env\n' "$DEV_INSTANCE_DIR"
printf 'Mail provisioning plan: %s/mail/provision.ndjson\n' "$DEV_INSTANCE_DIR"
