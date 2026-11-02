#!/bin/sh
set -eu

install -o memory -g memory -m 600 /run/memory-client.pub /home/memory/.ssh/authorized_keys
chown memory:memory /memory
exec /usr/sbin/sshd -D -e
