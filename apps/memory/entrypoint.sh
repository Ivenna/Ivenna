#!/bin/sh
set -eu

install -o memory -g memory -m 600 /run/memory-client.pub /home/memory/.ssh/authorized_keys
chown memory:memory /memory
mkdir -p /run/ivenna
touch /run/ivenna/memory.lock
chown memory:memory /run/ivenna/memory.lock
chmod 600 /run/ivenna/memory.lock
exec /usr/sbin/sshd -D -e -o "SetEnv=MEMORY_CAPACITY_BYTES=${MEMORY_CAPACITY_BYTES:-1073741824}"
