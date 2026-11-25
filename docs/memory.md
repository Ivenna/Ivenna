# Memory rooms

Memory rooms hold Ivenna's shared, persistent memory beyond any one session. Ivenna chooses what to keep and how to arrange it: room hierarchy, names, content formats, and cross-references are its own. The [design intent](design.md#understanding-and-autonomy) describes memory's role in its continuing understanding.

This guide covers memory tool effects and results. See the [tool declarations](../packages/memory/src/tools.json) for parameters, the [running guide](running.md#memory-service) for setup, and the [architecture guide](architecture.md#autonomous-memory) for storage and transport.

## Addresses and organization

An `address` is a literal path relative to the shared entrance, such as `languages/progress.md`; `.` is the entrance. Returned addresses use the same base. Visiting a room does not change the base for later calls. Use `find_memory` for name patterns. Addresses cannot escape the entrance through `..` or symbolic links.

Names consisting only of three or more dots, such as `...`, are unsupported. The entrance's `.ivenna-tmp` address is reserved for unpublished writes and is excluded from tools and occupied space. The [memory service requirements](running.md#memory-service) also apply when managing workspace files outside the tools.

## Result pages and shared state

Room visits, find, and recall replies are paginated. Results are sorted by address, then by line for content matches. Use `max_results` to request up to that many items. A page can contain fewer items even when more remain. Each reply includes its `offset` and the `total` number of results. Pass a non-null `next_offset` as the next call's `offset` to continue. A single result too large to return gives `result_too_large`.

Each reply describes the memory at the time of the call. Other sessions can update entries or use available capacity between calls. Changes can shift offsets, results, and totals. [Text reads](#reading) have their own byte offsets and page sizes.

## Visiting a room

`visit_memory_room` opens a view of the room at `address`, defaulting to the shared entrance, `.`. It lists the room's immediate memories and child rooms without reading their contents. The address must identify a room; use `read_memory` to open a memory.

Each record has an `address`, `name`, `kind`, and `size_bytes`. `kind` is `room` or `memory`. Entry addresses remain relative to the shared entrance, while the result's `address` identifies the visited room. Visiting an empty room returns `entries: []`. For example, `{"address":"languages"}` can return:

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

## Searching

`find_memory` and `recall_memory` search a `room` and its descendants. The room defaults to `.`; returned addresses remain relative to the shared entrance.

Both tools default to literal, case-insensitive matching. Set `case_sensitive: true` to make a search case-sensitive. A search with no matches returns `matches: []`; invalid patterns and search failures are tool errors.

`find_memory` searches names with `literal`, `glob`, or `regex` matching. Literal matching finds any part of a name. Matches include the entry's `address`, `name`, and `kind`. For example, use a glob to find Markdown entries under `languages`:

```json
{"query":"*.md","room":"languages","match_mode":"glob"}
```

`recall_memory` searches entry contents and returns a `text` preview for each matching line. The `address` identifies the memory and `line` gives its line number, starting at 1. When `text_truncated` is true, `read_memory` can open the entry for more context. This call searches the `languages` room and its children.

```json
{"clue":"French","room":"languages"}
```

## Reading

Call `read_memory` with an entry's `address`. For text, `max_bytes` sets the page size. This call asks for the first eight bytes.

```json
{"address":"languages/progress.md","max_bytes":8}
```

The reply gives the page's text alongside the total size of the entry in bytes.

```json
{"result":{"address":"languages/progress.md","content":"French: ","byte_length":30,"offset":0,"next_offset":8}}
```

Pass `next_offset` as the next call's `offset` to continue. A null `next_offset` marks the end. A page can be shorter than requested and can end within a line. It always preserves whole UTF-8 characters. An offset beyond the entry or inside a character returns `invalid_range`.

When a read identifies an image or file, it returns the complete entry for the model service. The accompanying text gives its `address`, `byte_length`, and `kind` (`image` or `file`). An image also includes its `format`. A later text page can reveal binary data and return the whole file. See [automatic classification](content.md#automatic-classification).

An entry containing an image URL is text by default. To view the image, read it from offset zero with `interpretation: "image_url"`. The result has `kind: "image_url"` and gives the size of the stored entry. The image part carries the URL. See [image URL references](content.md#image-url-references).

```json
{"address":"references/chart","interpretation":"image_url"}
```

If the entry exceeds the size limit for that image, file, or URL reference, `content.unavailable` gives the `byte_length` and `reason`. See [content limits](content.md#content-and-results).

## Recording

`remember` writes one source to an `address` relative to the memory entrance.

| Content | Meaning |
| --- | --- |
| `{"text":"..."}` | Write the supplied text as UTF-8 |
| `{"file":{"path":"..."}}` | Copy a file's original bytes from Ivenna's host filesystem |

For a file copy, `path` must identify a regular file on the host. It can be an absolute path, a path relative to the kernel's startup directory, or a local `file://` URI. This call sends the report's bytes to the memory service and stores them in the `reports` room.

```json
{"address":"reports/annual.pdf","content":{"file":{"path":"/srv/reports/annual.pdf"}}}
```

`remember.mode` controls how the bytes are stored:

| Mode | Behavior |
| --- | --- |
| `create` (default) | Write a new entry; report an error if the address exists |
| `append` | Append bytes without a separator, creating the entry if missing |
| `replace` | Write the full content, creating or overwriting the entry |

All three modes create missing parent rooms after checking the proposed write. Ivenna can remember directly at its chosen address. `create_memory_room` also creates rooms explicitly, including empty ones; an existing room is reused.

Each new or updated entry is limited to 33554432 bytes (32 MiB), independently of the [shared capacity](#memory-space). A larger host source is rejected before transfer; an append whose resulting entry exceeds the limit is also rejected. Existing larger entries can still be listed, searched, read in text pages, moved, or removed.

Recording and revision publish a complete new entry at the chosen address. A failed preparation preserves the previous entry. Replacing, appending, or revising one hard-linked name leaves its other names unchanged. Unpublished content is excluded from memory observations and logical capacity. Published changes can be lost after a storage or power failure.

For example, call `remember` to write a text entry, creating its room if needed:

```json
{"address":"languages/progress.md","content":{"text":"French: practice twice a week. Japanese: practice once a week."}}
```

## Revising

`revise_memory` replaces matching text in an entry. The existing entry must be UTF-8 text without NUL bytes; both the existing and revised entry are limited to 32 MiB. Revisions default to literal, case-sensitive matching, and `old_text` must be nonempty.

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

## Moving and removing

For `move_memory`, `destination` can be a new address or an existing room. Moving into an existing room preserves the original name. The destination's containing room must already exist. The operation fails if the resulting target already exists and otherwise returns the actual new address.

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
| `invalid_arguments` | The invocation does not match the tool's declared parameters |
| `not_found` | The addressed entry or room does not exist |
| `already_exists` | The target is occupied for `remember` in create mode or for `move_memory` |
| `invalid_address` | The address is outside the workspace, unsupported, reserved, or identifies the wrong kind of entry |
| `source_unavailable` | Reading the host source failed before the request went to the memory service |
| `unsupported_content` | The existing entry is not valid UTF-8 text or contains NUL bytes; no revision was written |
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
