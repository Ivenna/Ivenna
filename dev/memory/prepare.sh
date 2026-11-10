#!/bin/sh
set -eu

: "${DEV_INSTANCE_DIR:?Set DEV_INSTANCE_DIR to an absolute instance directory}"
case $DEV_INSTANCE_DIR in
    /*) ;;
    *) printf '%s\n' 'DEV_INSTANCE_DIR must be an absolute path.' >&2; exit 1 ;;
esac

state_dir="$DEV_INSTANCE_DIR/memory"
ssh_port=${MEMORY_SSH_PORT:-2222}

umask 077
mkdir -p "$state_dir"
if [ ! -f "$state_dir/id_ed25519" ]; then
    ssh-keygen -q -t ed25519 -N '' -C ivenna-dev-memory -f "$state_dir/id_ed25519"
fi
if [ ! -f "$state_dir/ssh_host_ed25519_key" ]; then
    ssh-keygen -q -t ed25519 -N '' -C ivenna-dev-memory-host -f "$state_dir/ssh_host_ed25519_key"
fi

# Trust the generated host key instead of whichever server answers the port.
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

printf 'Memory SSH config: %s/config\n' "$state_dir"
