# The application sends one JSON request. Addresses belong to this workspace;
# directories are memory rooms and text files hold memories.
def fail [code: string, message: string] {
    error make {code: $code, msg: $message}
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
    if $address == "" or ($address | str starts-with "/") {
        fail invalid_address "请使用相对于记忆房间入口的位置；入口写作 '.'。"
    }
    let lexical = [$root $address] | path join | path expand --no-symlink
    if not (within $root $lexical) {
        fail invalid_address "这个位置超出了记忆空间。"
    }
    mut ancestor = $lexical
    mut remaining = []
    while not ($ancestor | path exists --no-symlink) {
        $remaining = $remaining | prepend ($ancestor | path basename)
        $ancestor = $ancestor | path dirname
    }
    let parent = try { $ancestor | path expand --strict } catch {
        fail invalid_address "无法确定这个位置指向的记忆条目或房间。"
    }
    if not (within $root $parent) {
        fail invalid_address "这个位置指向记忆空间之外，无法访问。"
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
        fail not_found $"位置 '($target.address)' 不存在。"
    }
    $target
}

def memory-room [root: string, address: string] {
    let target = existing $root $address
    if ($target.path | path type) != "dir" {
        fail invalid_address $"位置 '($target.address)' 不是记忆房间。"
    }
    $target
}

def memory [root: string, address: string] {
    let target = existing $root $address
    if ($target.path | path type) != "file" {
        fail invalid_address $"位置 '($target.address)' 不是可读取或修订的记忆条目。"
    }
    $target
}

def entry [root: string, path: string] {
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

def dispatch [root: string, operation: string, args: record] {
    match $operation {
        "browse_memory_room" => {
            let room = memory-room $root ($args.room? | default ".")
            let entries = ls --all $room.path
                | each {|item| try { entry $root $item.name } catch { null } }
                | compact
            {room: $room.address, entries: $entries}
        },
        "find_memory" => {
            let room = memory-room $root ($args.room? | default ".")
            let mode = match ($args.match_mode? | default "literal") {
                "literal" => "--fixed-strings",
                "glob" => "--glob",
                "regex" => "--regex",
                _ => { fail invalid_argument "名称匹配方式可选 literal、glob 或 regex。" }
            }
            let case = if ($args.case_sensitive? | default false) { "--case-sensitive" } else { "--ignore-case" }
            let found = ^fd --hidden --no-ignore --print0 --color never $mode $case -- $args.query $room.path | complete
            if $found.exit_code != 0 {
                fail operation_failed ($found.stderr | str replace --all $root "." | str trim)
            }
            let matches = $found.stdout | split row (char nul)
                | where {|path| $path != "" }
                | each {|path| try { entry $root $path } catch { null } }
                | compact
            {room: $room.address, query: $args.query, matches: $matches}
        },
        "recall_memory" => {
            let room = memory-room $root ($args.room? | default ".")
            let mode = match ($args.match_mode? | default "literal") {
                "literal" => ["--fixed-strings"],
                "regex" => [],
                _ => { fail invalid_argument "内容匹配方式可选 literal 或 regex。" }
            }
            let case = if ($args.case_sensitive? | default false) { "--case-sensitive" } else { "--ignore-case" }
            let recalled = ^rg --json --hidden --no-ignore --color never ...$mode $case -- $args.clue $room.path | complete
            if $recalled.exit_code > 1 {
                fail operation_failed ($recalled.stderr | str replace --all $root "." | str trim)
            }
            let matches = $recalled.stdout | lines | each {|line| $line | from json }
                | where type == "match"
                | each {|item|
                    let target = resolve $root (relative-address $root $item.data.path.text)
                    {address: $target.address, line: $item.data.line_number, text: $item.data.lines.text}
                }
            {room: $room.address, clue: $args.clue, matches: $matches}
        },
        "read_memory" => {
            let target = memory $root $args.address
            {address: $target.address, content: (open --raw $target.path)}
        },
        "remember" => {
            let target = resolve $root $args.address
            match ($args.mode? | default "create") {
                "create" => {
                    if ($target.path | path exists) {
                        fail already_exists $"位置 '($target.address)' 已存在；请另选位置，或为已有条目选择追加、替换或修订。"
                    }
                    $args.content | save --raw $target.path
                },
                "append" => { $args.content | save --raw --append $target.path },
                "replace" => { $args.content | save --raw --force $target.path },
                _ => { fail invalid_argument "记录方式可选 create（新建）、append（追加）或 replace（替换）。" }
            }
            {address: $target.address}
        },
        "revise_memory" => {
            let target = memory $root $args.address
            let regex = match ($args.match_mode? | default "literal") {
                "literal" => false,
                "regex" => true,
                _ => { fail invalid_argument "修订匹配方式可选 literal 或 regex。" }
            }
            let before = open --raw $target.path
            let matched = if $regex { $before =~ $args.old_text } else { $before | str contains $args.old_text }
            let after = $before | str replace --all=($args.replace_all? | default false) --regex=$regex --no-expand=(not $regex) $args.old_text $args.new_text
            let revision = if not $matched {
                "no_match"
            } else if $before == $after {
                "unchanged"
            } else {
                "revised"
            }
            if $revision == "revised" { $after | save --raw --force $target.path }
            {address: $target.address, revision: $revision}
        },
        "create_memory_room" => {
            let target = resolve $root $args.address
            mkdir $target.path
            {address: $target.address}
        },
        "move_memory" => {
            let source = existing $root $args.address
            if $source.path == $root { fail invalid_address "入口位置不能移动。" }
            let destination = resolve $root $args.destination
            let target = if ($destination.path | path type) == "dir" {
                resolve $root ([$destination.address ($source.address | path basename)] | path join)
            } else { $destination }
            if ($target.path | path exists) {
                fail already_exists $"目标位置 '($target.address)' 已存在；请另选位置。"
            }
            mv $source.entry_path $target.entry_path
            {address: $target.address}
        },
        "forget_memory" => {
            let target = existing $root $args.address
            if $target.path == $root { fail invalid_address "记忆房间的入口须保留，请选择其中的条目或子房间。" }
            rm --recursive=($args.recursive? | default false) $target.entry_path
            {address: $target.address}
        },
        _ => { fail invalid_operation "无法识别这个记忆房间操作，请使用提供的记忆工具。" }
    }
}

def main [] {
    let input = $in
    let response = try {
        let request = $input | from json
        let operations = $request | columns
        if ($operations | length) != 1 {
            fail invalid_request "每次请求请选择一个记忆房间操作。"
        }
        let operation = $operations | first
        let arguments = $request | get $operation
        if not (($arguments | describe) | str starts-with "record") {
            fail invalid_request "请按工具定义提供操作参数。"
        }
        let root = $env.PWD | path expand --strict
        {result: (dispatch $root $operation $arguments)}
    } catch {|error|
        let code = $error.details.code? | default "operation_failed"
        {
            error: {
                code: (if ($code | str starts-with "nu::") { "operation_failed" } else { $code }),
                message: $error.msg
            }
        }
    }
    print ($response | to json --raw)
    if "error" in ($response | columns) { exit 1 }
}
