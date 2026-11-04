#!/bin/sh
set -eu

export PATH=/usr/local/bin:/usr/bin:/bin
cd /memory
exec flock /run/ivenna/memory.lock nu --no-config-file --no-history --stdin /usr/local/lib/ivenna/memory.nu
