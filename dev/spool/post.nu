#!/usr/bin/env nu
# Publish one message into a spool inbox directory.
#
#   nu dev/spool/post.nu /var/lib/ivenna/inbox operator "hello"
#
# The document is written to a dot-prefixed `.tmp` name and renamed into place,
# so the runtime never observes a partially written file. The file name carries
# arrival order; the runtime acknowledges by moving it into `.acked/`.
def main [
    directory: string # spool inbox directory, i.e. INBOX_SPOOL_DIR
    sender: string # correspondent id, e.g. operator
    text: string # message body
] {
    mkdir $directory
    let now = (date now)
    let nanos = ($now | into int)
    let name = $"($nanos)-((random int 100000..999999))"
    let document = {
        from: [$sender]
        text: $text
        observed_at_unix_ms: ($nanos / 1_000_000 | into int)
    } | to json
    let temporary = $"($directory)/.($name).json.tmp"
    let final = $"($directory)/($name).json"
    $document | save --force --raw $temporary
    mv $temporary $final
    print $final
}
