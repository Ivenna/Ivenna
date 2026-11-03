# Memory rooms

Ivenna stores persistent memory in rooms shared across sessions. The model uses tools to browse, find, recall, record, and revise memories. Ivenna chooses its own room hierarchy, entry names, formats, and cross-references.

See the [running guide](running.md) for local setup or [using remote memory](running.md#using-remote-memory) to connect to another memory workspace. The [architecture guide](architecture.md#application-state-and-autonomous-memory) describes the execution protocol and module boundaries.

## Addresses and organization

| Concept | Meaning |
| --- | --- |
| Memory room | A space containing related entries and child rooms |
| Memory entry | A file stored at an address, with content and format chosen by Ivenna |
| Address | A path relative to the shared entrance, such as `languages/progress.md`; `.` is the entrance |
| Name query | Literal text, a glob pattern, or a regular expression used by `find_memory` |
| Content clue | Literal text or a regular expression used by `recall_memory` |

All addresses are relative to the shared entrance, including those returned by tools. The `room` argument limits where a tool browses or searches; it does not change the base for addresses in later calls. Moving a room or entry changes its address. References stored in memory content are not rewritten automatically.

## Tools and arguments

[tools.json](../packages/agent/src/tools.json) defines the tools and arguments available to the model. The table below lists the required arguments. Omit optional arguments to use their defaults.

| Tool | Required arguments | Purpose |
| --- | --- | --- |
| `browse_memory_room` | None | Browse a room's entries and child rooms |
| `find_memory` | `query` | Find entries and rooms by name |
| `recall_memory` | `clue` | Recall relevant entries by content |
| `read_memory` | `address` | Read an entry as text or an image |
| `remember` | `address`, `content` | Write text or copy a host file into an entry |
| `revise_memory` | `address`, `old_text`, `new_text` | Revise matching text in an entry |
| `create_memory_room` | `address` | Create a room and any missing parent rooms |
| `move_memory` | `address`, `destination` | Move or rename entries and rooms |
| `forget_memory` | `address` | Remove an entry or room |

Use `room` to limit browsing and searches to a room; it defaults to the shared entrance. Both `find_memory` and `recall_memory` also search child rooms.

For name searches, `match_mode` supports `literal`, `glob`, and `regex`; content searches support `literal` and `regex`. Searches use literal, case-insensitive matching by default. Literal name searches match any part of a name. Set `case_sensitive: true` to make searches case-sensitive. Content searches match text in entries.

`read_memory` accepts an optional `expected` object for the complete entry. Omit it for automatic classification as full text or a supported image. See [tool content](content.md) for the expectation branches, URL references, and limits.

`remember.content` selects exactly one source:

| Content | Meaning |
| --- | --- |
| `{"text":"..."}` | Write the supplied text as UTF-8 |
| `{"file":{"path":"..."}}` | Copy a file's original bytes from the service's filesystem |

A source file path can be absolute or relative to the service's startup directory. The destination `address` remains relative to the memory entrance. Browsing, name searches, moving, and removal work with entries of any format. See [tool content](content.md) for the types currently returned to the model by `read_memory`.

For `remember`, `mode` defaults to `create`, which returns an error if the address already exists. Use `append` to append the source bytes without inserting a separator, or `replace` to write the full content. Both modes can also create a missing entry. Create and append require an existing containing room; replace also creates missing parent rooms.

`revise_memory` requires the entry to contain UTF-8 text without NUL bytes. Revisions default to literal, case-sensitive matching and replace only the first match. Set `replace_all: true` to replace every match. Set `match_mode: "regex"` to use a regular expression; replacement text can reference capture groups such as `${1}` and `${name}`. Regular expressions also support inline flags.

When moving an entry or room, `destination` can be a new address or an existing room. Moving into an existing room preserves the original name. The operation fails if the resulting target already exists. By default, `forget_memory` removes entries or empty rooms. Set `recursive: true` to remove a room and all its contents. The shared entrance cannot be moved or removed.

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
{"address":"screenshots/dashboard.png","expected":{"image":{}}}
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

Every response starts with a JSON text part containing either `result` or `error`. Successful responses put the operation's output in `result`; image reads add native image content after that text part. For example, `remember` returns the entry's address:

```json
{"result":{"address":"languages/progress.md"}}
```

| Operation | Contents of `result` |
| --- | --- |
| Browse | `room` and `entries`; each entry has `address`, `name`, and `kind` |
| Find by name | `room`, `query`, and `matches`; each match has `address`, `name`, and `kind` |
| Recall by content | `room`, `clue`, and `matches`; each match has `address`, `line`, and `text` |
| Read | `address` and `content`: full text, image metadata, or an unavailable-content diagnostic |
| Revise | `address` and `revision` |
| Record, create a room, move, or remove | `address`; moving returns the actual new address |

For an image read, `content` is `{"image":{"data":{"format":"png","byte_length":12345}}}` for image bytes, or `{"image":{"url":{}}}` for a URL reference. Content that cannot be supplied returns `{"unavailable":{"byte_length":12345,"reason":"unsupported_binary"}}`; images exceeding the byte limit use `image_too_large`. These diagnostics preserve the entry's address. The [content guide](content.md) describes model request checks and history.

The `kind` field is `room` for a memory room and `memory` for a memory entry. A search with no matches returns an empty `matches` list. In content matches, `line` is a line number starting at 1. The `revision` field has three possible values:

| Value | Meaning |
| --- | --- |
| `no_match` | No matching content was found |
| `unchanged` | A match was found, but the content did not change |
| `revised` | The content was revised |

On failure, `error` provides a `code` and `message` describing the problem. `source_unavailable` means a host source file could not be read; this invocation sent no remote memory request. `unsupported_content` from a revision means the entry was not UTF-8 text without NUL bytes, so no revision was written.

`memory_unavailable` means a read-only operation ended without a complete response. `memory_change_uncertain` means memory may have changed, but the outcome is unknown.

Resuming a session may repeat operations whose results were not yet saved in a checkpoint. See [failure and recovery](architecture.md#failure-and-recovery) for details.
