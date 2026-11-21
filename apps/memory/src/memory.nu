# The application sends one JSON request. Addresses belong to this workspace;
# directories are memory rooms and files hold memories.
def fail [code: string, message: string] {
    error make {code: $code, msg: $message}
}

# File operations are fallible at the selected entry. Keep their diagnostics as
# tool outcomes; workspace preparation, accounting and programming errors still
# fail the service request.
def filesystem-operation [action: closure] {
    try { do $action } catch {|failure|
        fail operation_failed $failure.msg
    }
}

def pattern-operation [action: closure] {
    try { do $action } catch {|failure|
        fail invalid_pattern ($failure.details.labels? | default [] | get -o text | str join "; " | default $failure.msg)
    }
}

def staging-path [root: string] { [$root ".ivenna-tmp"] | path join }

def prepare-workspace [root: string] {
    let staging = staging-path $root
    let marker = [$staging ".owner"] | path join
    let owner = "Ivenna unpublished memory writes\n"
    if ($staging | path exists --no-symlink) {
        if ($staging | path type) != "dir" or ($marker | path type) != "file" {
            error make {msg: "The reserved .ivenna-tmp address is occupied by unowned content."}
        }
        if (open --raw $marker) != $owner {
            error make {msg: "The reserved .ivenna-tmp address is occupied by unowned content."}
        }
        # The lock excludes other requests. Retire only this application's
        # unpublished files, including bytes left behind by a killed request.
        ls --all $staging | where name != $marker | each {|item| rm --recursive $item.name } | ignore
    } else {
        mkdir $staging
        $owner | save --raw $marker
    }
}

def within [root: string, path: string] {
    $path == $root or ($path | str starts-with $"($root)/")
}

def relative-address [root: string, path: string] {
    if $path == $root { "." } else { $path | str replace $"($root)/" "" }
}

# Resolve the nearest existing ancestor as well as existing targets. This keeps
# new addresses and symbolic links under the same workspace boundary.
def resolve [root: string, address: string] {
    if $address == "" or ($address | str starts-with "/") or ($address | str contains (char nul)) {
        fail invalid_address "Use an address relative to the shared entrance; use '.' for the entrance."
    }
    # Nu expands three-or-more dots even in string-valued filesystem paths.
    # Reject that spelling before any path command can alias another address.
    if ($address | split row "/" | any {|component| $component =~ '^\.{3,}$' }) {
        fail invalid_address "Names consisting only of three or more dots are unsupported by the memory filesystem adapter."
    }
    let lexical = [$root $address] | path join | path expand --no-symlink
    if (within (staging-path $root) $lexical) {
        fail invalid_address "This address is reserved for unpublished memory writes."
    }
    if not (within $root $lexical) {
        fail invalid_address "This address is outside the memory workspace."
    }
    mut ancestor = $lexical
    mut remaining = []
    while not ($ancestor | path exists --no-symlink) {
        $remaining = $remaining | prepend ($ancestor | path basename)
        $ancestor = $ancestor | path dirname
    }
    let parent = try { $ancestor | path expand --strict } catch {|failure|
        fail invalid_address $"This address cannot be resolved: ($failure.msg)"
    }
    if (within (staging-path $root) $parent) {
        fail invalid_address "This address resolves to unpublished memory writes."
    }
    if not (within $root $parent) {
        fail invalid_address "This address resolves outside the memory workspace."
    }
    {
        path: ([$parent ...$remaining] | path join),
        entry_path: $lexical,
        address: (relative-address $root $lexical)
    }
}

def existing [root: string, address: string] {
    let target = resolve $root $address
    if not ($target.path | path exists) {
        fail not_found $"Address '($target.address)' does not exist."
    }
    $target
}

def memory-room [root: string, address: string] {
    let target = existing $root $address
    if ($target.path | path type) != "dir" {
        fail invalid_address $"Address '($target.address)' is not a memory room."
    }
    $target
}

def memory [root: string, address: string] {
    let target = existing $root $address
    if ($target.path | path type) != "file" {
        fail invalid_address $"Address '($target.address)' is not a memory entry."
    }
    $target
}

def entry [root: string, path: string] {
    if (within (staging-path $root) $path) { return null }
    let target = resolve $root (relative-address $root $path)
    let kind = match ($target.path | path type) {
        "dir" => "room",
        "file" => "memory",
        _ => null
    }
    if $kind != null {
        {address: $target.address, name: ($target.address | path basename), kind: $kind}
    }
}

# Count names, including hard-linked names, by their logical file lengths.
# Published writes replace one name rather than modifying all links to an inode.
def workspace-usage [path: string, root?: string] {
    let root = $root | default $path
    mut logical_bytes = 0
    for item in (ls --all --long $path) {
        if $item.name == (staging-path $root) { continue }
        match $item.type {
            "file" => { $logical_bytes = $logical_bytes + ($item.size | into int) },
            "dir" => {
                if ($item.name | split row "/" | last) =~ '^\.{3,}$' {
                    error make {msg: "A workspace directory has an unsupported all-dots name. Rename it before using the memory service."}
                }
                $logical_bytes = $logical_bytes + (workspace-usage $item.name $root)
            },
            _ => {}
        }
    }
    $logical_bytes
}

# Pagination owns the model-facing result size. Stop before the encoded JSON
# exceeds 32 KiB and leave an offset that resumes with the first omitted item.
def page [items: list, args: record, context: record] {
    let offset = $args.offset? | default 0
    let maximum = $args.max_results? | default 100
    if $offset < 0 or $maximum < 1 or $maximum > 1000 {
        fail invalid_range "Use a nonnegative offset and max_results from 1 through 1000."
    }
    mut selected = []
    for item in ($items | skip $offset | take $maximum) {
        let candidate = $context | merge {items: ($selected | append $item), offset: $offset, total: ($items | length), next_offset: ($offset + ($selected | length) + 1)}
        # Reserve the two extra bytes in 'entries'/'matches' versus 'items'.
        if ({result: $candidate} | to json --raw | into binary | bytes length) > 32760 {
            if ($selected | is-empty) {
                fail result_too_large "One result exceeds the reply size. Use a shorter memory address or a narrower query."
            }
            break
        }
        $selected = $selected | append $item
    }
    let end = $offset + ($selected | length)
    {items: $selected, offset: $offset, total: ($items | length), next_offset: (if $end < ($items | length) { $end } else { null })}
}

# Return a UTF-8 boundary-aligned prefix without replacing a partial character.
def text-preview [text: string, maximum: int] {
    let bytes = $text | into binary
    let length = $bytes | bytes length
    mut end = [$length $maximum] | math min
    while $end > 0 and $end < $length and ((($bytes | bytes at $end..<($end + 1) | into int) | bits and 192) == 128) {
        $end = $end - 1
    }
    $text | str substring 0..<$end
}

def describe-entry [root: string, item: record, recursive_size: bool] {
    let target = existing $root $item.address
    let size = if $item.kind == "memory" {
        filesystem-operation { ls $target.path | first | get size | into int }
    } else if $recursive_size {
        filesystem-operation { workspace-usage $target.path $root }
    } else { null }
    $item | merge {size_bytes: $size}
}

def memory-capacity [] {
    let capacity = $env.MEMORY_CAPACITY_BYTES? | default "1073741824" | into int
    if $capacity <= 0 { error make {msg: "MEMORY_CAPACITY_BYTES must be a positive integer."} }
    $capacity
}

# The entry point holds the workspace lock across this check and the write.
def check-write [root: string, path: string, byte_length: int, capacity: int] {
    if $byte_length > 33554432 {
        fail entry_too_large "An individual memory entry can contain at most 33554432 bytes (32 MiB)."
    }
    if ($path | path exists) and ($path | path type) != "file" {
        fail invalid_address "A memory entry must be a regular file."
    }
    let current = if ($path | path type) == "file" { ls --long $path | first } else { null }
    let usage = workspace-usage $root
    let old_length = if $current == null { 0 } else { $current.size | into int }
    let projected = $usage + $byte_length - $old_length
    if $projected > $capacity and $projected > $usage {
        fail memory_capacity_exceeded $"The memories in all rooms would need ($projected) bytes, exceeding their shared capacity of ($capacity) bytes."
    }
}

# Staging shares the memory filesystem, so rename publishes one complete entry.
# No staged file is exposed as memory or counted toward logical capacity.
def publish [root: string, path: string, bytes: binary, append: bool = false] {
    filesystem-operation {
        let staging = mktemp --tmpdir-path (staging-path $root) "write.XXXXXXXXXXXX"
        try {
            if $append and ($path | path exists) {
                cp --force $path $staging
                $bytes | save --raw --append $staging
            } else {
                $bytes | save --raw --force $staging
            }
            mv --force $staging $path
        } finally {
            rm --force $staging
        }
    }
}

def recall-pattern [clue: string, mode: string] {
    let pattern = if $mode == "literal" {
        $clue | str escape-regex
    } else { $clue }
    # Consume the rest of the line in byte mode, even around invalid UTF-8.
    # Query flags remain scoped to the query; JSON keeps at most one submatch
    # instead of expanding every occurrence on a long line.
    ['(?-u:.*)(?:' $pattern ')(?-u:.*)'] | str join
}

# Drain ripgrep incrementally. Its final status travels in the same stream,
# because Nushell's structured pipeline does not retain an external exit code.
# Only a bounded result page and a scalar match count survive each input line.
def recall [root: string, room: record, args: record] {
    let mode = $args.match_mode? | default "literal"
    if $mode not-in ["literal" "regex"] {
        fail invalid_argument "Content matching mode must be literal or regex."
    }
    let pattern = recall-pattern $args.clue $mode
    let case = if ($args.case_sensitive? | default false) { "--case-sensitive" } else { "--ignore-case" }
    let offset = $args.offset? | default 0
    let maximum = $args.max_results? | default 100
    if $offset < 0 or $maximum < 1 or $maximum > 1000 {
        fail invalid_range "Use a nonnegative offset and max_results from 1 through 1000."
    }
    let diagnostic = mktemp --tmpdir-path (staging-path $root) "search.XXXXXXXXXXXX"
    try {
        let state = ^sh -c 'rg --json --sort path --hidden --no-ignore --color never "$@"; status=$?; printf "{\"ivenna_exit\":%s}\n" "$status"' ivenna-memory-recall $case -- $pattern $room.path err> $diagnostic
            | lines --strict
            | reduce --fold {items: [], total: 0, full: false, exit_code: null} {|line, state|
                if $state.exit_code != null {
                    error make {msg: "The memory search emitted output after its final status."}
                }
                let item = $line | from json
                if $item.ivenna_exit? != null {
                    return ($state | upsert exit_code $item.ivenna_exit)
                }
                if $item.type? != "match" or $item.data.path.text? == null or $item.data.lines.text? == null {
                    return $state
                }
                if (within (staging-path $root) $item.data.path.text) { return $state }
                let total = $state.total + 1
                if $total <= $offset or $state.full {
                    return ($state | upsert total $total)
                }
                if ($state.items | length) >= $maximum {
                    return ($state | merge {total: $total, full: true})
                }
                let target = resolve $root (relative-address $root $item.data.path.text)
                let text = text-preview $item.data.lines.text 2048
                let record = {address: $target.address, line: $item.data.line_number, text: $text, text_truncated: ($text != $item.data.lines.text)}
                let candidate = {result: {room: $room.address, matches: ($state.items | append $record), offset: $offset, total: $total, next_offset: ($offset + ($state.items | length) + 1)}}
                # Reserve space for the final total, which may grow as input is drained.
                if ($candidate | to json --raw | into binary | bytes length) > 32700 {
                    if ($state.items | is-empty) { fail result_too_large "One search result exceeds the encoded reply limit." }
                    return ($state | merge {total: $total, full: true})
                }
                $state | merge {items: ($state.items | append $record), total: $total}
            }
        if $state.exit_code == null or $state.exit_code not-in [0 1 2] {
            error make {msg: "The memory search did not return a valid completion status."}
        }
        if $state.exit_code == 2 {
            # Diagnostics deliberately use lossy decoding if the byte bound
            # splits a character; entry content keeps strict UTF-8 handling.
            let message = open --raw $diagnostic | bytes at 0..<8192 | decode utf8 | str trim
            let truncated = (ls $diagnostic | first | get size | into int) > 8192
            fail search_failed (if $truncated { $"($message)\n[diagnostic truncated]" } else { $message })
        }
        let end = $offset + ($state.items | length)
        {room: $room.address, matches: $state.items, offset: $offset, total: $state.total, next_offset: (if $end < $state.total { $end } else { null })}
    } finally {
        rm --force $diagnostic
    }
}

def dispatch [root: string, operation: string, args: record, capacity: int] {
    match $operation {
        "inspect_memory_space" => {
            let usage = workspace-usage $root
            {
                used_bytes: $usage,
                capacity_bytes: $capacity,
                remaining_bytes: ([0 ($capacity - $usage)] | math max),
                used_ratio: ($usage / $capacity)
            }
        },
        "visit_memory_room" => {
            let target = memory-room $root ($args.address? | default ".")
            let entries = filesystem-operation { ls --all $target.path | collect }
                | each {|item| entry $root $item.name }
                | compact
            let described = $entries | sort-by address | each {|item| describe-entry $root $item ($args.recursive_size? | default false) }
            let selected = page $described $args {address: $target.address}
            {address: $target.address, entries: $selected.items, offset: $selected.offset, total: $selected.total, next_offset: $selected.next_offset}
        },
        "find_memory" => {
            let room = memory-room $root ($args.room? | default ".")
            let mode = match ($args.match_mode? | default "literal") {
                "literal" => "--fixed-strings",
                "glob" => "--glob",
                "regex" => "--regex",
                _ => { fail invalid_argument "Name matching mode must be literal, glob, or regex." }
            }
            let case = if ($args.case_sensitive? | default false) { "--case-sensitive" } else { "--ignore-case" }
            let found = ^fd --hidden --no-ignore --print0 --color never $mode $case -- $args.query $room.path | complete
            if $found.exit_code != 0 {
                fail search_failed ($found.stderr | str trim)
            }
            let matches = $found.stdout | split row (char nul)
                | where {|path| $path != "" }
                | each {|path| entry $root $path }
                | compact
            let selected = page ($matches | sort-by address) $args {room: $room.address}
            {room: $room.address, matches: $selected.items, offset: $selected.offset, total: $selected.total, next_offset: $selected.next_offset}
        },
        "recall_memory" => {
            recall $root (memory-room $root ($args.room? | default ".")) $args
        },
        "read_memory" => {
            let target = memory $root $args.address
            let offset = $args.offset? | default 0
            let maximum = $args.max_bytes? | default 8192
            if $offset < 0 or $maximum < 4 or $maximum > 33554432 {
                fail invalid_range "Use a nonnegative byte offset and a supported transfer size."
            }
            let byte_length = filesystem-operation { ls $target.path | first | get size | into int }
            if $offset > $byte_length { fail invalid_range "The byte offset is beyond the end of this entry." }
            let end = [$byte_length ($offset + $maximum)] | math min
            let data = filesystem-operation { open --raw $target.path | bytes at $offset..<$end | into binary | encode base64 }
            let header = filesystem-operation { open --raw $target.path | bytes at 0..<32 | into binary | encode base64 }
            {address: $target.address, data: $data, header: $header, byte_length: $byte_length, offset: $offset}
        },
        "remember" => {
            let target = resolve $root $args.address
            if ($args.data | str length --utf-8-bytes) > 44739244 {
                fail entry_too_large "A memory write can transfer at most 33554432 bytes (32 MiB)."
            }
            let content = $args.data | decode base64
            let append = match ($args.mode? | default "create") {
                "create" => {
                    if ($target.path | path exists) {
                        fail already_exists $"Address '($target.address)' already exists."
                    }
                    false
                },
                "append" => true,
                "replace" => false,
                _ => { fail invalid_argument "The mode argument must be create, append, or replace." }
            }
            let before = if $append and ($target.path | path type) == "file" { filesystem-operation { ls $target.path | first | get size | into int } } else { 0 }
            check-write $root $target.path ($before + ($content | bytes length)) $capacity
            filesystem-operation { mkdir ($target.path | path dirname) }
            publish $root $target.path $content $append
            {address: $target.address}
        },
        "revise_memory" => {
            let target = memory $root $args.address
            let regex = match ($args.match_mode? | default "literal") {
                "literal" => false,
                "regex" => true,
                _ => { fail invalid_argument "Revision matching mode must be literal or regex." }
            }
            if (filesystem-operation { ls $target.path | first | get size | into int }) > 33554432 {
                fail entry_too_large "Text revision supports entries up to 33554432 bytes (32 MiB)."
            }
            let before = filesystem-operation { open --raw $target.path | collect }
            if ($before | describe) != "string" or ($before | str contains (char nul)) {
                fail unsupported_content "Text revision requires UTF-8 content without NUL bytes."
            }
            if $args.old_text == "" { fail invalid_argument "old_text must not be empty." }
            let replace_all = $args.replace_all? | default false
            let matches = pattern-operation {
                if not $replace_all {
                    # Unique edits need only distinguish zero, one and several
                    # matches. Native splitn stops after the second occurrence.
                    ($before | split row --number 3 --regex=$regex $args.old_text | length) - 1
                } else if $regex {
                    # parse reports runtime regex errors before str replace,
                    # whose upstream API can panic on backtracking failure.
                    $before | parse --regex $args.old_text | length
                } else {
                    # Literal counts need one string, not a value per match.
                    let remaining = $before | str replace --all --no-expand $args.old_text "" | str length --utf-8-bytes
                    (($before | str length --utf-8-bytes) - $remaining) // ($args.old_text | str length --utf-8-bytes)
                }
            }
            if not $replace_all and $matches > 1 {
                fail ambiguous_match "old_text matches more than once. Include more surrounding text or set replace_all to true."
            }
            let after = if $matches == 0 { $before } else {
                pattern-operation { $before | str replace --all=$replace_all --regex=$regex --no-expand=(not $regex) $args.old_text $args.new_text }
            }
            let revision = if $matches == 0 {
                "no_match"
            } else if $before == $after {
                "unchanged"
            } else {
                "revised"
            }
            if $revision == "revised" {
                check-write $root $target.path ($after | str length --utf-8-bytes) $capacity
                publish $root $target.path ($after | into binary)
            }
            {address: $target.address, revision: $revision, matches: $matches}
        },
        "create_memory_room" => {
            let target = resolve $root $args.address
            filesystem-operation { mkdir $target.path }
            {address: $target.address}
        },
        "move_memory" => {
            let source = existing $root $args.address
            if $source.path == $root { fail invalid_address "The shared entrance cannot be moved." }
            let destination = resolve $root $args.destination
            let target = if ($destination.path | path type) == "dir" {
                resolve $root ([$destination.address ($source.address | path basename)] | path join)
            } else { $destination }
            if ($target.path | path exists) {
                fail already_exists $"Destination address '($target.address)' already exists."
            }
            if (within $source.path $target.path) {
                fail invalid_address "A memory room cannot be moved into itself or a descendant."
            }
            filesystem-operation { mv $source.entry_path $target.entry_path }
            {address: $target.address}
        },
        "forget_memory" => {
            let target = existing $root $args.address
            if $target.path == $root { fail invalid_address "The shared entrance cannot be removed." }
            filesystem-operation { rm --recursive=($args.recursive? | default false) $target.entry_path }
            {address: $target.address}
        },
        _ => { fail invalid_operation "Unknown memory operation." }
    }
}

def main [] {
    let input = $in
    let workspace = try {
        if ($env.PWD | split row "/" | any {|component| $component =~ '^\.{3,}$' }) {
            error make {msg: "The workspace path contains an unsupported all-dots directory name."}
        }
        let root = $env.PWD | path expand --strict
        let capacity = memory-capacity
        prepare-workspace $root
        {root: $root, capacity: $capacity}
    } catch {|failure|
        print --stderr $failure.msg
        exit 2
    }
    let root = $workspace.root
    let capacity = $workspace.capacity
    let response = try {
        let request = $input | from json
        let operations = $request | columns
        if ($operations | length) != 1 {
            fail invalid_request "Specify exactly one memory operation per request."
        }
        let operation = $operations | first
        let arguments = $request | get $operation
        if not (($arguments | describe) | str starts-with "record") {
            fail invalid_request "Operation arguments must be a JSON object matching the tool definition."
        }
        {result: (dispatch $root $operation $arguments $capacity)}
    } catch {|error|
        mut details = $error.details
        # each/reduce add source context around an intentional operation error.
        # Unwrap only that known wrapper; unknown Nushell errors remain fatal.
        while $details.code? == "nu::shell::eval_block_with_input" and (($details.inner? | default []) | length) == 1 {
            $details = $details.inner | first
        }
        let code = $details.code?
        if $code == null or ($code | str starts-with "nu::") {
            print --stderr $error.msg
            exit 2
        }
        {
            error: {
                code: $code,
                message: $details.msg
            }
        }
    }
    let encoded = $response | to json --raw
    # Read transports carry binary data to the host adapter, which separately
    # bounds the model-facing text and preserves complete supported images.
    if ($encoded | into binary | bytes length) > 32768 and not (("result" in ($response | columns)) and ("data" in ($response.result | columns))) {
        print ({error: {code: "result_too_large", message: "The result metadata exceeds the 32768-byte reply limit. Use a shorter address or a narrower query."}} | to json --raw)
        exit 1
    }
    print $encoded
    if "error" in ($response | columns) { exit 1 }
}
