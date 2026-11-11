use std/assert

# Exercise the handler's JSON protocol with a fresh process for every request.
def request [handler: path, workspace: path, operation: record, --capacity: int = 1024, --status: int = 0] {
    let response = do {
        cd $workspace
        with-env {MEMORY_CAPACITY_BYTES: ($capacity | into string)} {
            $operation | to json --raw
                | ^$nu.current-exe --no-config-file --no-history --stdin $handler
                | complete
        }
    }
    assert equal $response.exit_code $status $response.stderr
    $response.stdout | from json
}

def revisions [handler: path, workspace: path] {
    mkdir $workspace
    let original = "Bonjour, 你好. Bonjour again."
    request $handler $workspace {remember: {address: "entry", data: ($original | encode base64)}} | ignore

    let ambiguous = request $handler $workspace {revise_memory: {address: "entry", old_text: "Bonjour", new_text: "Salut"}} --status 1
    assert equal $ambiguous.error.code "ambiguous_match"
    assert equal (open --raw ($workspace | path join "entry")) $original

    # Literal replacement keeps dollar signs and Unicode as supplied.
    let revised = request $handler $workspace {revise_memory: {address: "entry", old_text: "Bonjour", new_text: '$1 再见', replace_all: true}}
    assert equal $revised.result.revision "revised"
    assert equal $revised.result.matches 2
    assert equal (open --raw ($workspace | path join "entry")) '$1 再见, 你好. $1 再见 again.'
}

def capacity [handler: path, workspace: path] {
    mkdir $workspace
    let original = "你好"
    request $handler $workspace {remember: {address: "entry", data: ($original | encode base64)}} --capacity 6 | ignore

    let append = request $handler $workspace {remember: {address: "entry", data: ("!" | encode base64), mode: "append"}} --capacity 6 --status 1
    assert equal $append.error.code "memory_capacity_exceeded"
    assert equal (open --raw ($workspace | path join "entry")) $original

    let revision = request $handler $workspace {revise_memory: {address: "entry", old_text: $original, new_text: "你好呀"}} --capacity 6 --status 1
    assert equal $revision.error.code "memory_capacity_exceeded"
    assert equal (open --raw ($workspace | path join "entry")) $original

    # Lowering capacity must still allow existing memories to shrink.
    let shrunk = request $handler $workspace {revise_memory: {address: "entry", old_text: $original, new_text: "好"}} --capacity 3
    assert equal $shrunk.result.revision "revised"
    assert equal (open --raw ($workspace | path join "entry")) "好"
    let space = request $handler $workspace {inspect_memory_space: {}} --capacity 3
    assert equal $space.result.used_bytes 3
    assert equal $space.result.remaining_bytes 0
}

def addresses [handler: path, workspace: path, outside: path] {
    mkdir $workspace $outside
    "keep" | save --raw ($outside | path join "entry")
    ^ln -s $outside ($workspace | path join "link")

    for address in ["../outside/entry" "link/entry" "link/new-entry"] {
        let rejected = request $handler $workspace {remember: {address: $address, data: ("overwrite" | encode base64), mode: "replace"}} --status 1
        assert equal $rejected.error.code "invalid_address"
    }
    assert equal (open --raw ($outside | path join "entry")) "keep"
    assert equal (($outside | path join "new-entry") | path exists) false
}

def main [] {
    let handler = [$env.FILE_PWD "src" "memory.nu"] | path join
    let temporary = mktemp --directory
    try {
        revisions $handler ($temporary | path join "revisions")
        print "PASS: explicit memory revision"
        capacity $handler ($temporary | path join "capacity")
        print "PASS: failed growth preserves memory; shrinking remains possible"
        addresses $handler ($temporary | path join "addresses") ($temporary | path join "outside")
        print "PASS: memory addresses stay inside the workspace"
    } finally {
        rm --recursive --force $temporary
    }
}
