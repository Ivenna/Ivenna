# Memory rooms

Memory entries are files, and memory rooms are directories in a persistent workspace shared across sessions. Ivenna chooses what to retain and how to organize it: room hierarchy, entry names, formats, and cross-references are its own.

The [tool declarations](../packages/memory/src/tools.json) define the available operations and their parameters. Memory is a required runtime capability; the [running guide](running.md#memory-service) covers its service requirements and SSH connection, and the [architecture guide](architecture.md#autonomous-memory) explains its implementation responsibilities.

## Addresses and organization

An `address` is a literal path relative to the shared entrance, such as `languages/progress.md`; `.` is the entrance. Returned addresses use the same base. Use `find_memory` for name patterns. Addresses cannot escape the entrance through `..` or symbolic links.

Names consisting only of three or more dots, such as `...`, are unsupported. The entrance's `.ivenna-tmp` address is reserved for unpublished writes and is excluded from tools and occupied space. The [memory service requirements](running.md#memory-service) also apply when managing workspace files outside the tools.

## Result pages and shared state

Browse, find, and recall replies are paginated. `offset` defaults to `0`, and `max_results` defaults to `100` (from `1` through `1000`). Replies include `offset`, `total`, and `next_offset`; pass a non-null `next_offset` as the next call's `offset` to continue. Results are sorted by address, then by line for content matches. The 32768-byte encoded JSON limit can shorten a page before `max_results` is reached. A single result whose metadata cannot fit returns `result_too_large`.

The service serializes individual requests. A sequence of calls does not reserve entries or capacity between requests: another session can change them. Each reply describes its current snapshot. Changes between pages can alter offsets, results, and totals; pagination does not preserve a snapshot across calls. [Text reads](#reading) have their own byte offsets and page sizes.

## Browsing and metadata

`browse_memory` accepts an `address`, defaulting to `.`. A room address lists its immediate entries and child rooms; a memory entry address returns one record for that entry. Browsing retrieves metadata without memory contents.

Each record has an `address`, `name`, `kind`, and `size_bytes`. `kind` is `room` or `memory`. Entry addresses remain relative to the shared entrance, while the result's `address` identifies the selected entry or room. Listing an empty room returns `entries: []`. For example, `{"address":"languages"}` can return:

```json
{
  "result": {
    "address": "languages",
    "entries": [
      {
        "address": "languages/practice",
        "name": "practice",
        "kind": "room",
        "size_bytes": null
      },
      {
        "address": "languages/progress.md",
        "name": "progress.md",
        "kind": "memory",
        "size_bytes": 128
      }
    ],
    "offset": 0,
    "total": 2,
    "next_offset": null
  }
}
```

A memory entry's `size_bytes` is its content length in bytes. A room's size is `null` when `recursive_size` is omitted or `false`: it was not measured in this call. Set `recursive_size: true` to measure the combined size of memories in each returned room and its descendants. An empty measured room has size `0`.

Set `entry_only: true` to inspect the selected room itself instead of listing its contents. The shared entrance's own record has `address: "."` and `name: "."`. Both options default to `false`; selecting metadata and measuring room sizes are independent choices.

## Searching

`find_memory` and `recall_memory` search a `room` and its descendants. The room defaults to `.`; returned addresses remain relative to the shared entrance.

Both tools default to literal, case-insensitive matching. Set `case_sensitive: true` to make a search case-sensitive. A search with no matches returns `matches: []`; invalid patterns and search failures are tool errors.

`find_memory` searches names with `literal`, `glob`, or `regex` matching. Literal matching finds any part of a name. Matches include the entry's `address`, `name`, and `kind`. For example, use a glob to find Markdown entries under `languages`:

```json
{"query":"*.md","room":"languages","match_mode":"glob"}
```

`recall_memory` searches entry text with `literal` or `regex` matching. It returns one record per matching line, with `address`, a `line` number starting at 1, a `text` preview of at most 2048 UTF-8 bytes, and `text_truncated` to identify an omitted suffix. Use `read_memory` for complete text. For example, search text throughout the room with:

```json
{"clue":"French","room":"languages"}
```

## Reading

Call `read_memory` with an entry address:

```json
{"address":"languages/progress.md"}
```

Text reads return a byte page. `offset` defaults to `0` and must be at a UTF-8 character boundary; `max_bytes` defaults to `8192` and accepts `4` through `8192`. The result includes the entry's total `byte_length`, the page's `offset`, and `next_offset`. Use a non-null `next_offset` as the next call's `offset` to continue; `null` means the end was reached. A page can end within a long line but preserves complete UTF-8 characters. An offset beyond the entry or inside a character returns `invalid_range`.

```json
{"result":{"address":"languages/progress.md","content":"French: practice twice a week.","byte_length":30,"offset":0,"next_offset":null}}
```

The encoded text reply is at most 32768 bytes. Escaping control characters or a long address can shorten a page further.

Image entries require `offset: 0` and return a complete `content.image` description, total `byte_length`, and native image content, subject to the shared image limit. Text pagination does not split images. The optional `interpretation: "image_url"` requires `offset: 0` and presents the entry's complete nonempty text as an [image reference](content.md#image-url-references), subject to the shared reference size limit.

Content that cannot be supplied returns `content.unavailable` with its `byte_length` and `reason`. The shared [content guide](content.md) defines detection, supported formats, image descriptions, and unavailable-content diagnostics.

## Recording

`remember.content` selects exactly one source:

| Content | Meaning |
| --- | --- |
| `{"text":"..."}` | Write the supplied text as UTF-8 |
| `{"file":{"path":"..."}}` | Copy a file's original bytes from Ivenna's host filesystem |

A source file path can be absolute or relative to Ivenna's startup directory and must identify a regular file. Its bytes are copied from Ivenna's host to the memory workspace; the destination `address` remains relative to the memory entrance.

`remember.mode` controls how the bytes are stored:

| Mode | Behavior |
| --- | --- |
| `create` (default) | Write a new entry; report an error if the address exists |
| `append` | Append bytes without a separator, creating the entry if missing |
| `replace` | Write the full content, creating or overwriting the entry |

Create and append require an existing containing room. Replace also creates missing parent rooms. Use `create_memory_room` to create rooms explicitly; an existing room is reused.

Each new or updated entry is limited to 33554432 bytes (32 MiB), independently of the [shared capacity](#memory-space). A larger host source is rejected before transfer; an append whose resulting entry exceeds the limit is also rejected. Existing larger entries can still be browsed, searched, read in text pages, moved, or removed.

Recording and revision prepare a complete new file before publishing it at the address. A failed preparation preserves the previous entry. Replacing, appending, or revising one hard-linked name leaves its other names unchanged. Unpublished content is excluded from memory observations and logical capacity. Publication does not guarantee durability across a storage or power failure.

For example, call `create_memory_room` with:

```json
{"address":"languages"}
```

Then call `remember` to write a text entry:

```json
{"address":"languages/progress.md","content":{"text":"French: practice twice a week. Japanese: practice once a week."}}
```

## Revising

`revise_memory` replaces matching text in an entry. It requires UTF-8 text without NUL bytes and limits both the existing and revised entry to 32 MiB. Revisions default to literal, case-sensitive matching, and `old_text` must be nonempty.

By default, a unique match is replaced. No match returns `revision: "no_match"` without writing. Multiple non-overlapping matches return `ambiguous_match` without changing the entry; include more surrounding text or set `replace_all: true` to replace every match. The reply reports the match count in `matches` and one of these outcomes:

| `revision` | Meaning |
| --- | --- |
| `no_match` | No matching content was found |
| `unchanged` | A match was found, but the content did not change |
| `revised` | The content was revised |

Set `match_mode: "regex"` to use a regular expression. Replacement text can reference capture groups such as `${1}` and `${name}`. For example, update both labels in the entry above with:

```json
{"address":"languages/progress.md","old_text":"(French|Japanese):","new_text":"${1} study:","replace_all":true,"match_mode":"regex"}
```

With `replace_all: true`, regex validation and counting can use temporary memory beyond the entry's 32 MiB limit. The [architecture guide](architecture.md#autonomous-memory) explains this implementation limit.

## Moving and removing

For `move_memory`, `destination` can be a new address or an existing room. Moving into an existing room preserves the original name. The operation fails if the resulting target already exists and otherwise returns the actual new address.

By default, `forget_memory` removes entries or empty rooms. Set `recursive: true` to remove a room and all its contents. The shared entrance cannot be moved or removed.

## Memory space

All rooms and sessions share one capacity. Call `inspect_memory_space` with `{}` to see how much space their memories occupy and how much remains:

```json
{
  "result": {
    "used_bytes": 4096,
    "capacity_bytes": 8192,
    "remaining_bytes": 4096,
    "used_ratio": 0.5
  }
}
```

`used_bytes` counts regular-file lengths across all rooms, including hidden files. Each hard-linked name counts separately; directories, symlinks, and special files do not contribute. `capacity_bytes` is the shared limit for that total.

`remaining_bytes` is capacity minus used space, with a minimum of zero. `used_ratio` is used space divided by capacity. The deployment user [configures the capacity at the memory service](running.md#memory-service). Lowering it below the size of existing memories leaves them intact and can produce a ratio above 1.

Before `remember` or a content-changing `revise_memory`, Ivenna checks how much space the memories would occupy. Growth beyond the shared capacity returns `memory_capacity_exceeded` without changing the entry. Changes that shrink or preserve occupied space remain possible when already over capacity, as do reading, moving, and forgetting memories.

## Results and errors

A memory tool reply includes a text part containing JSON with either `result` or an operation `error`. Content-bearing results follow the shapes described above. Writes and room or file management return the affected `address`; for example, `remember` returns:

```json
{"result":{"address":"languages/progress.md"}}
```

An operation error contains `code` and `message`. Common codes include:

| Code | Meaning |
| --- | --- |
| `not_found` | The addressed entry or room does not exist |
| `already_exists` | The target is occupied for `remember` in create mode or for `move_memory` |
| `invalid_address` | The address is outside the workspace, unsupported, reserved, or identifies the wrong kind of entry |
| `source_unavailable` | The host source file could not be read; no memory request was sent |
| `unsupported_content` | Revision requires UTF-8 text without NUL bytes; no revision was written |
| `invalid_range` | A read offset or page size is invalid |
| `invalid_argument` | An argument such as empty revision text is invalid |
| `invalid_pattern` | The revision pattern is invalid |
| `search_failed` | The name or content search failed, including an invalid pattern |
| `ambiguous_match` | A revision found multiple matches without `replace_all`; no revision was written |
| `entry_too_large` | A write transfer, existing entry selected for revision, or resulting entry exceeds 32 MiB; no entry was published |
| `result_too_large` | One result's metadata cannot fit the encoded reply limit |
| `operation_failed` | An operation on the selected entry failed, with its filesystem diagnostic |
| `memory_capacity_exceeded` | The proposed growth exceeds shared capacity; the entry was not changed |

Errors from selected-entry file operations and patterns are ordinary tool replies; the next model round can use the diagnostic to continue. Workspace preparation, capacity-accounting failures, invalid service replies, and connection failures remain infrastructure failures and stop the kernel and its concurrent work.

Connection timeout or shutdown can leave an operation's effects unknown. Writes are not automatically retried. See the [SSH connection requirements](running.md#ssh-connection) for deadlines and [startup and interruption](architecture.md#startup-and-interruption) for continuation after restart.
