# Host resources

`touch` observes one file or directory on the host without changing it. Paths are limited to configured roots, and file bytes use the same [content](content.md) classification, media representation, and limits as memory reads and host results.

## Scope

`RESOURCE_ROOTS` is a colon-separated list of roots. When it is unset or empty, no roots are configured and `touch` reports `outside_scope`; the deployment opts in by naming at least one root. Roots are resolved against the startup directory and canonicalized at startup; a root that is missing or not a directory prevents the kernel from starting.

A relative `address` resolves against the first root. An absolute `address` must lie inside any root. The candidate path is normalized, then resolved through symlinks, and the canonical path must remain inside a root. `..` and symbolic links therefore cannot leave the permitted scope.

## Arguments

| Field | Meaning |
| --- | --- |
| `address` | Required path. Relative paths use the first root; absolute paths must be inside a root. |
| `offset` | Byte offset for a text range, default `0`. Must be `0` for an image, a complete file, or a directory. |
| `max_bytes` | Maximum text bytes to return, default `262144` and range `4..8388608`. Images, complete files, and directories ignore it. |

## Results

A text file returns one range:

```json
{"result":{"address":"/srv/project/README.md","kind":"file","content":"# Project\n","byte_length":11,"offset":0,"next_offset":null}}
```

`next_offset` is present when the file continues. Resume at that offset; it is always a UTF-8 character boundary. A range that would start inside a character returns `invalid_range`.

An image or complete file returns the shared description plus its native content part. A source over 32 MiB returns the shared `unavailable` description with `image_too_large` or `file_too_large`; it is never read partially.

```json
{"result":{"address":"/srv/project/logo.png","kind":"file","content":{"image":{"data":{"format":"png","byte_length":4213}}},"byte_length":4213}}
```

A directory lists one level, sorted by name:

```json
{"result":{"address":"/srv/project","kind":"directory","entries":[{"name":"README.md","kind":"file","byte_length":11,"modified_ms":1760000000000}],"truncated":false}}
```

Entries report `name`, `kind`, `byte_length`, and `modified_ms`. Size and modification time are null when they do not apply, including symbolic links. At most 100 entries are returned; `truncated` says more remain. The limit applies before sorting, so a truncated page is a sorted subset rather than the first 100 names.

## Errors

| Code | Meaning |
| --- | --- |
| `not_found` | The path or a parent does not exist. |
| `outside_scope` | The path is outside every root, including after symlink resolution. |
| `not_readable` | Permission was denied, or the path is not a regular file or directory. |
| `invalid_range` | The offset is beyond the file, inside a character, or not allowed for this source. |
| `invalid_arguments` | The request does not match the declaration. |

Failure results contain `{"error":{"code":"...","message":"..."}}` and never empty content. Paths are canonical absolute paths; the result may differ textually from the requested address.

## Relationship to memory

[Memory rooms](memory.md) keep what Ivenna chose to remember and are reached through `read_memory`. `touch` reads the host filesystem, including files an activity or a person changed outside memory. An image or file read through either path is classified the same way; neither operation copies the source into a memory room.
