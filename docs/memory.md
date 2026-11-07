# Memory rooms

Ivenna stores persistent memory in rooms shared across sessions. Work sessions use tools to browse, find, recall, record, and revise memories. Ivenna chooses its own room hierarchy, entry names, formats, and cross-references.

Memory is a required runtime capability. The [running guide](running.md#memory-service) covers its service requirements and SSH connection; the [architecture guide](architecture.md#autonomous-memory) explains its implementation responsibilities.

## Addresses and organization

| Concept | Meaning |
| --- | --- |
| Memory room | A space containing related entries and child rooms |
| Memory entry | A file of any type stored at an address, with content and format chosen by Ivenna |
| Address | A path relative to the shared entrance, such as `languages/progress.md`; `.` is the entrance |

All addresses are relative to the shared entrance, including those returned by tools. An `address` identifies one entry or room by its literal location; use `find_memory` for name patterns.

## Tools

[tools.json](../packages/memory/src/tools.json) defines the memory tools available to work sessions. The table below lists their required arguments. Omit optional arguments to use their defaults.

| Tool | Required arguments | Purpose |
| --- | --- | --- |
| `browse_memory` | None | List a room's entries or inspect an entry or room's metadata |
| `inspect_memory_space` | None | Inspect occupied space and remaining shared capacity across all rooms |
| `find_memory` | `query` | Find entries and rooms by name |
| `recall_memory` | `clue` | Search entry text for matching lines |
| `read_memory` | `address` | Read an entry as text or an image |
| `remember` | `address`, `content` | Write text or copy a host file into an entry |
| `revise_memory` | `address`, `old_text`, `new_text` | Revise matching text in an entry |
| `create_memory_room` | `address` | Create a room and any missing parent rooms |
| `move_memory` | `address`, `destination` | Move or rename entries and rooms |
| `forget_memory` | `address` | Remove an entry or room |

## Browsing and metadata

`browse_memory` accepts a literal `address`, defaulting to `.`. By default, a room address lists its immediate entries and child rooms; a memory entry address returns one record for that entry. Browsing returns metadata without retrieving memory contents. For example, `{"address":"languages"}` can return:

```json
{
  "result": {
    "address": "languages",
    "entries": [
      {
        "address": "languages/progress.md",
        "name": "progress.md",
        "kind": "memory",
        "size_bytes": 128
      },
      {
        "address": "languages/practice",
        "name": "practice",
        "kind": "room",
        "size_bytes": null
      }
    ]
  }
}
```

The result's `address` identifies the selected entry or room; addresses in `entries` remain relative to the shared entrance. Each record has an `address`, `name`, `kind`, and `size_bytes`. Listing an empty room returns `entries: []`.

A memory entry's `size_bytes` is its content length in bytes. A room's size is `null` when `recursive_size` is omitted or `false`: it was not measured in this call. Set `recursive_size: true` to measure the combined size of memories in each returned room and its descendants. An empty measured room has size `0`.

Set `entry_only: true` to return one record for the selected entry or room. The shared entrance's own record has `address: "."` and `name: "."`. Both options default to `false`; recursive size calculation leaves the set of returned entries unchanged.

| Call | Result |
| --- | --- |
| `{"address":"languages/progress.md"}` | One memory entry record with its size |
| `{"address":"languages","entry_only":true}` | One room record with `size_bytes: null` |
| `{"address":"languages","entry_only":true,"recursive_size":true}` | One room record with the combined size of all its memories |
| `{"address":"languages","recursive_size":true}` | Immediate entries and child rooms, with each child room's combined size |

## Searching and reading

`find_memory` and `recall_memory` search a `room` and its descendants. The room defaults to `.`; returned addresses remain relative to the shared entrance.

`find_memory` searches names with `literal`, `glob`, or `regex` matching. `recall_memory` searches entry text with `literal` or `regex` matching. Both default to literal, case-insensitive matching; literal name searches match any part of a name. Set `case_sensitive: true` to make a search case-sensitive.

`read_memory` uses the shared [content handling](content.md) rules. Its optional `interpretation: "image_url"` presents the entry's complete nonempty text as an [image reference](content.md#image-url-references).

For example, call `find_memory` with a glob to find Markdown entries under `languages`:

```json
{"query":"*.md","room":"languages","match_mode":"glob"}
```

Call `recall_memory` to search text throughout the room:

```json
{"clue":"French","room":"languages"}
```

## Recording and revising

`remember.content` selects exactly one source:

| Content | Meaning |
| --- | --- |
| `{"text":"..."}` | Write the supplied text as UTF-8 |
| `{"file":{"path":"..."}}` | Copy a file's original bytes from Ivenna's host filesystem |

A source file path can be absolute or relative to Ivenna's startup directory. The file is read on Ivenna's host and copied to the memory workspace; the destination `address` remains relative to the memory entrance.

`remember.mode` controls how the bytes are stored:

| Mode | Behavior |
| --- | --- |
| `create` (default) | Write a new entry; report an error if the address exists |
| `append` | Append bytes without a separator, creating the entry if missing |
| `replace` | Write the full content, creating or overwriting the entry |

Create and append require an existing containing room. Replace also creates missing parent rooms. Use `create_memory_room` to create rooms explicitly; an existing room is reused.

`revise_memory` requires the entry to contain UTF-8 text without NUL bytes. Revisions default to literal, case-sensitive matching and replace only the first match. Set `replace_all: true` to replace every match. Set `match_mode: "regex"` to use a regular expression; replacement text can reference capture groups such as `${1}` and `${name}`.

For example, call `create_memory_room` with:

```json
{"address":"languages"}
```

Then call `remember` to write a text entry:

```json
{"address":"languages/progress.md","content":{"text":"French: practice twice a week. Japanese: practice once a week."}}
```

A later `revise_memory` call can update both labels using capture expansion:

```json
{"address":"languages/progress.md","old_text":"(French|Japanese):","new_text":"${1} study:","replace_all":true,"match_mode":"regex"}
```

## Moving and removing

For `move_memory`, `destination` can be a new address or an existing room. Moving into an existing room preserves the original name. The operation fails if the resulting target already exists. References stored in memory content are not rewritten when an address changes.

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

Before `remember` or a content-changing `revise_memory`, Ivenna checks how much space the memories would occupy. Growth beyond the shared capacity returns `memory_capacity_exceeded` without changing the entry. A change can exactly fill the remaining space. Changes that shrink or preserve occupied space remain possible when already over capacity, as do reading, moving, and forgetting memories.

The result describes the space at the time of the query. Another session can change it before a later recording or revision. Memory operations are serialized individually; a sequence of reads and writes does not reserve the entries or capacity between calls.

## Results and errors

A memory tool reply includes a text part containing JSON with either `result` or an operation `error`. For example, `remember` returns the entry's address:

```json
{"result":{"address":"languages/progress.md"}}
```

| Operation | Contents of `result` |
| --- | --- |
| Browse | `address` and `entries`; each entry has `address`, `name`, `kind`, and `size_bytes` |
| Inspect space | `used_bytes`, `capacity_bytes`, `remaining_bytes`, and `used_ratio` |
| Find by name | `room`, `query`, and `matches`; each match has `address`, `name`, and `kind` |
| Recall by content | `room`, `clue`, and `matches`; each match has `address`, `line`, and `text` |
| Read | `address` and `content`: full text, an `image` description, or `unavailable` with `byte_length` and `reason` |
| Revise | `address` and `revision` |
| Record, create a room, move, or remove | `address`; moving returns the actual new address |

Image reads add native image content alongside the address and image description. The shared [content guide](content.md#content-and-results) defines image descriptions and omission diagnostics.

The `kind` field is `room` for a memory room and `memory` for a memory entry. A search with no matches returns an empty `matches` list. In content matches, `line` is a line number starting at 1. The `revision` field has three possible values:

| Value | Meaning |
| --- | --- |
| `no_match` | No matching content was found |
| `unchanged` | A match was found, but the content did not change |
| `revised` | The content was revised |

An operation error contains `code` and `message`. Common codes include:

| Code | Meaning |
| --- | --- |
| `not_found` | The addressed entry or room does not exist |
| `already_exists` | The target is occupied for `remember` in create mode or for `move_memory` |
| `invalid_address` | The address is outside the workspace or identifies the wrong kind of entry |
| `source_unavailable` | The host source file could not be read; no memory request was sent |
| `unsupported_content` | Revision requires UTF-8 text without NUL bytes; no revision was written |
| `memory_capacity_exceeded` | The proposed growth exceeds shared capacity; the entry was not changed |

Connection and protocol failures, and handler failures without an operation-error reply, stop the kernel and its concurrent work. Finer error classification and execution recovery remain undefined; see [startup and interruption](architecture.md#startup-and-interruption).
