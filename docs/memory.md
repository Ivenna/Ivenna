# Memory rooms

Ivenna stores persistent memory in rooms shared across sessions. Work sessions use tools to browse, find, recall, record, and revise memories. Ivenna chooses its own room hierarchy, entry names, formats, and cross-references.

See the [running guide](running.md) for local setup or [using remote memory](running.md#using-remote-memory) to connect to another memory workspace. The [architecture guide](architecture.md#autonomous-memory) describes the execution protocol and module boundaries.

## Addresses and organization

| Concept | Meaning |
| --- | --- |
| Memory room | A space containing related entries and child rooms |
| Memory entry | A file of any type stored at an address, with content and format chosen by Ivenna |
| Address | A path relative to the shared entrance, such as `languages/progress.md`; `.` is the entrance |
| Name query | Literal text, a glob pattern, or a regular expression used by `find_memory` |
| Content clue | Literal text or a regular expression used by `recall_memory` |

All addresses are relative to the shared entrance, including those returned by tools. An `address` identifies one entry or room by its literal location; use `find_memory` for name patterns.

`find_memory` and `recall_memory` search within a `room` and its child rooms. The scope defaults to `.` and does not change the base for addresses in later calls.

Moving a room or entry changes its address; references stored in memory content are not rewritten automatically.

## Tools and arguments

[tools.json](../packages/agent/src/tools.json) defines the memory tools available to work sessions. The table below lists their required arguments. Omit optional arguments to use their defaults.

| Tool | Required arguments | Purpose |
| --- | --- | --- |
| `browse_memory` | None | List a room's entries or inspect an entry or room's metadata |
| `inspect_memory_space` | None | Inspect occupied space and remaining shared capacity across all rooms |
| `find_memory` | `query` | Find entries and rooms by name |
| `recall_memory` | `clue` | Recall relevant entries by content |
| `read_memory` | `address` | Read an entry as text or an image |
| `remember` | `address`, `content` | Write text or copy a host file into an entry |
| `revise_memory` | `address`, `old_text`, `new_text` | Revise matching text in an entry |
| `create_memory_room` | `address` | Create a room and any missing parent rooms |
| `move_memory` | `address`, `destination` | Move or rename entries and rooms |
| `forget_memory` | `address` | Remove an entry or room |

`find_memory` searches names with `literal`, `glob`, or `regex` matching. `recall_memory` searches entry text with `literal` or `regex` matching. Both default to literal, case-insensitive matching; literal name searches match any part of a name. Set `case_sensitive: true` to make a search case-sensitive.

`read_memory` uses the shared [content handling](content.md) rules. Its optional `interpretation: "image_url"` presents the entry's complete text as an [image reference](content.md#image-url-references).

`remember.content` selects exactly one source:

| Content | Meaning |
| --- | --- |
| `{"text":"..."}` | Write the supplied text as UTF-8 |
| `{"file":{"path":"..."}}` | Copy a file's original bytes from Ivenna's host filesystem |

A source file path can be absolute or relative to Ivenna's startup directory. The file is read on Ivenna's host and copied to the memory workspace; the destination `address` remains relative to the memory entrance.

For `remember`, `mode` defaults to `create`, which returns an error if the address already exists. Use `append` to append the source bytes without inserting a separator, or `replace` to write the full content. Both modes can also create a missing entry. Create and append require an existing containing room; replace also creates missing parent rooms.

`revise_memory` requires the entry to contain UTF-8 text without NUL bytes. Revisions default to literal, case-sensitive matching and replace only the first match. Set `replace_all: true` to replace every match. Set `match_mode: "regex"` to use a regular expression; replacement text can reference capture groups such as `${1}` and `${name}`. Regular expressions also support inline flags.

When moving an entry or room, `destination` can be a new address or an existing room. Moving into an existing room preserves the original name. The operation fails if the resulting target already exists. By default, `forget_memory` removes entries or empty rooms. Set `recursive: true` to remove a room and all its contents. The shared entrance cannot be moved or removed.

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

A memory entry's `size_bytes` is its content length in bytes. A room's size is `null` when `recursive_size` is omitted or `false`: it was not measured in this call. Set `recursive_size: true` to measure the combined size of memories in each returned room and its descendants. An empty measured room has size `0`. Size calculation failures return an error.

Set `entry_only: true` to return one record for the selected entry or room. The shared entrance's own record has `address: "."` and `name: "."`. Both options default to `false`; recursive size calculation leaves the set of returned entries unchanged.

| Call | Result |
| --- | --- |
| `{"address":"languages/progress.md"}` | One memory entry record with its size |
| `{"address":"languages","entry_only":true}` | One room record with `size_bytes: null` |
| `{"address":"languages","entry_only":true,"recursive_size":true}` | One room record with the combined size of all its memories |
| `{"address":"languages","recursive_size":true}` | Immediate entries and child rooms, with each child room's combined size |

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

`remaining_bytes` is capacity minus used space, with a minimum of zero. `used_ratio` is used space divided by capacity; multiply by 100 for a percentage. The deployment user [configures the capacity](running.md#local-middleware-settings). Lowering it below the size of existing memories leaves them intact and can produce a ratio above 1.

Before `remember` or a content-changing `revise_memory`, Ivenna checks how much space the memories would occupy. Growth beyond the shared capacity returns `memory_capacity_exceeded` without changing the entry. A change can exactly fill the remaining space. Changes that shrink or preserve occupied space remain possible when already over capacity, as do reading, moving, and forgetting memories.

The result describes the space at the time of the query. Another session can change it before a later recording or revision. Memory operations are serialized individually; a sequence of reads and writes does not reserve the entries or capacity between calls.

## Examples

Call `create_memory_room` to create a room:

```json
{"address":"languages"}
```

Call `remember` to record an entry:

```json
{"address":"languages/progress.md","content":{"text":"French: practice twice a week. Japanese: practice once a week."}}
```

Call `remember` to store an audio recording from the host:

```json
{"address":"languages/practice.wav","content":{"file":{"path":"/path/to/practice.wav"}}}
```

Call `recall_memory` to search a room's remembered content:

```json
{"clue":"French","room":"languages"}
```

Call `find_memory` to find entries by a name pattern:

```json
{"query":"*.md","room":"languages","match_mode":"glob"}
```

Call `read_memory` to read an image entry:

```json
{"address":"screenshots/dashboard.png"}
```

Call `revise_memory` to update a passage:

```json
{"address":"languages/progress.md","old_text":"practice twice a week","new_text":"practice three times a week"}
```

A regular expression can revise several passages at once. For example, update both language labels:

```json
{"address":"languages/progress.md","old_text":"(French|Japanese):","new_text":"${1} study:","replace_all":true,"match_mode":"regex"}
```

## Results and errors

Every operation returns a text part containing JSON with either `result` or `error`. Image reads add a native image part alongside a result description containing the entry's address and image metadata. Content limits can replace that image part with a diagnostic while preserving its source description. For example, `remember` returns the entry's address:

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

The shared [content guide](content.md#content-and-results) defines image descriptions and content diagnostics.

The `kind` field is `room` for a memory room and `memory` for a memory entry. A search with no matches returns an empty `matches` list. In content matches, `line` is a line number starting at 1. The `revision` field has three possible values:

| Value | Meaning |
| --- | --- |
| `no_match` | No matching content was found |
| `unchanged` | A match was found, but the content did not change |
| `revised` | The content was revised |

An error reply provides a `code` and `message` describing the problem. `source_unavailable` means a host source file could not be read; this invocation sent no remote memory request. `unsupported_content` from a revision means the entry was not UTF-8 text without NUL bytes, so no revision was written.

`memory_capacity_exceeded` means the proposed change would increase occupied space beyond the rooms' shared capacity; the entry did not change. See [memory space](#memory-space) for the measurements and permitted changes.

`memory_unavailable` means a read-only operation ended without a complete response. `memory_change_uncertain` means memory may have changed, but the outcome is unknown.

An interrupted operation may already have changed memory. Inspect the entry before deciding whether to repeat it; restarting the kernel does not restore the old tool transcript. See [startup and interruption](architecture.md#startup-and-interruption) for details.
