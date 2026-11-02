#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
state_dir="$repo_dir/.ivenna/dev-memory"
container_name=${MEMORY_CONTAINER_NAME:-ivenna-memory}
volume_name=${MEMORY_VOLUME_NAME:-ivenna-memory}
image_name=${MEMORY_IMAGE:-localhost/ivenna-memory:dev}
ssh_port=${MEMORY_SSH_PORT:-2222}

if [ -z "${CONTAINER_ENGINE:-}" ]; then
    printf 'Set CONTAINER_ENGINE to the container engine CLI executable.\n' >&2
    exit 1
fi

engine() {
    "$CONTAINER_ENGINE" "$@"
}

container_exists() {
    engine container inspect "$container_name" >/dev/null 2>&1
}

volume_exists() {
    engine volume inspect "$volume_name" >/dev/null 2>&1
}

build_image() (
    build_context=$(mktemp -d "$state_dir/build.XXXXXX")
    trap 'rm -rf "$build_context"' EXIT
    trap 'exit 1' HUP INT TERM
    mkdir -p "$build_context/dev/memory" "$build_context/packages/agent/src"
    cp -p "$repo_dir/dev/memory/Containerfile" "$repo_dir/dev/memory/entrypoint.sh" \
        "$repo_dir/dev/memory/memory-shell.sh" "$repo_dir/dev/memory/sshd_config" \
        "$build_context/dev/memory/"
    cp -p "$repo_dir/packages/agent/src/memory.nu" "$build_context/packages/agent/src/"
    engine build --tag "$image_name" \
        --file "$build_context/dev/memory/Containerfile" "$build_context"
)

check_owner() {
    if container_exists; then
        owner=$(engine container inspect --format '{{index .Config.Labels "io.ivenna.dev-memory"}}' "$container_name")
        if [ "$owner" != true ]; then
            printf 'Container %s is not marked as an Ivenna memory container.\n' "$container_name" >&2
            exit 1
        fi
    fi
}

show_connection() {
    printf 'Memory room is ready.\n'
    printf 'SSH target: ivenna-memory\n'
    printf 'SSH config: %s/config\n' "$state_dir"
    printf 'Memory volume: %s\n' "$volume_name"
}

case "${1:-up}" in
    up)
        check_owner
        if volume_exists; then
            owner=$(engine volume inspect --format '{{index .Labels "io.ivenna.dev-memory"}}' "$volume_name")
            if [ "$owner" != true ]; then
                printf 'Volume %s is not marked as an Ivenna memory volume.\n' "$volume_name" >&2
                exit 1
            fi
        fi
        umask 077
        mkdir -p "$state_dir"
        if [ ! -f "$state_dir/id_ed25519" ]; then
            ssh-keygen -q -t ed25519 -N '' -C ivenna-dev-memory -f "$state_dir/id_ed25519"
        fi
        if [ ! -f "$state_dir/ssh_host_ed25519_key" ]; then
            ssh-keygen -q -t ed25519 -N '' -C ivenna-dev-memory-host -f "$state_dir/ssh_host_ed25519_key"
        fi
        if ! container_exists; then
            build_image
            if ! volume_exists; then
                engine volume create --label io.ivenna.dev-memory=true "$volume_name" >/dev/null
            fi
            engine run --detach --name "$container_name" \
                --label io.ivenna.dev-memory=true \
                --publish "127.0.0.1:${ssh_port}:22" \
                --volume "${volume_name}:/memory" \
                --volume "$state_dir/id_ed25519.pub:/run/memory-client.pub:ro,Z" \
                --volume "$state_dir/ssh_host_ed25519_key:/run/memory-host-key:ro,Z" \
                "$image_name" >/dev/null
        elif [ "$(engine container inspect --format '{{.State.Running}}' "$container_name")" != true ]; then
            engine start "$container_name" >/dev/null
        fi
        # Trust the host public key generated for this container, rather than
        # accepting whichever server happens to answer the local port.
        host_public_key=$(cut -d ' ' -f 1,2 "$state_dir/ssh_host_ed25519_key.pub")
        printf '[127.0.0.1]:%s %s\n' "$ssh_port" "$host_public_key" > "$state_dir/known_hosts"
        cat > "$state_dir/config" <<EOF
Host ivenna-memory
    HostName 127.0.0.1
    User memory
    Port $ssh_port
    IdentityFile "$state_dir/id_ed25519"
    UserKnownHostsFile "$state_dir/known_hosts"
    IdentitiesOnly yes
    StrictHostKeyChecking yes
EOF
        attempts=0
        until printf '%s\n' '{"browse_memory_room":{}}' | ssh -F "$state_dir/config" \
            -o BatchMode=yes -o ConnectTimeout=1 -T ivenna-memory >/dev/null 2>&1; do
            attempts=$((attempts + 1))
            if [ "$attempts" -ge 30 ]; then
                printf 'Memory room did not become ready. Container logs:\n' >&2
                engine logs "$container_name" >&2
                exit 1
            fi
            sleep 1
        done
        show_connection
        ;;
    down)
        check_owner
        if container_exists; then
            engine rm --force "$container_name" >/dev/null
        fi
        printf 'Memory container removed; volume %s and SSH keys are retained.\n' "$volume_name"
        ;;
    status)
        check_owner
        if container_exists; then
            engine container inspect --format '{{.Name}} {{.State.Status}}' "$container_name"
        else
            printf 'Memory container not found.\n'
        fi
        ;;
    *)
        printf 'Usage: %s [up|down|status]\n' "$0" >&2
        exit 2
        ;;
esac
