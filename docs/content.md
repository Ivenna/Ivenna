# Tool content

Memory reads and host commands can supply text and images together to the model. This guide covers their result parts; the [input contract](input.md#material-and-provenance) defines received material and excerpts. See [memory rooms](memory.md) and [host shell](host.md) for tool arguments and result fields.

## Automatic classification

`read_memory` and `run_host_shell` identify the content they return from entry or stdout bytes. The current implementation recognizes JPEG, PNG, GIF, and WebP by their signatures, with a limit of 32 MiB per image. Signature recognition does not validate a complete image or decode its pixels. Supplied text is valid UTF-8 without NUL bytes.

Each entry or stdout capture is treated as one source; classification does not split an arbitrary byte stream into multiple media parts. A URL remains text unless the caller explicitly asks to present it as an image reference. A filename or URL suffix does not select a media type.

Memory reads return the full text of an entry. Shell text previews contain at most 16 KiB, retaining the beginning and end when truncated. For larger non-image shell output, text detection checks only the previewed bytes. Only stdout can supply an image; stderr returns a text preview or an `unavailable` diagnostic.

## Image URL references

Set `interpretation: "image_url"` to present the complete nonempty text of a memory entry or stdout capture as one image URL reference. For shell output, this uses the full stdout rather than a preview. Ivenna passes the text unchanged, without fetching or validating the address or referenced media. Recognized image bytes still return as image data, and empty output remains text. The configured model service handles the reference.

For example, a shell command can return an image reference:

```json
{"command":"printf '%s' 'https://example.com/image.png'","interpretation":"image_url"}
```

Omit `interpretation` when the entry or command already supplies image bytes, or when a URL should remain text.

## Content and results

Each tool combines source content with its operation's result description. Image reads include the memory address; shell results include the command outcome and both stream descriptions, including on nonzero exits and timeouts. Supported images are supplied as native content parts alongside these descriptions.

An image description has either `data` with `format` and `byte_length`, or `url` with an empty object. The native content part carries the encoded image bytes or URL itself. The [memory](memory.md#results-and-errors) and [shell](host.md#results-and-interruption) guides describe their surrounding result fields.

The current readers return an `unavailable` description for content they cannot supply, with `byte_length` and reason `unsupported_binary` or `image_too_large`. This diagnostic concerns the returned content; it leaves the command outcome and stored memory entry unchanged. Shell stdout and stderr remain in full in their log files.

## Model request checks

At the end of each tool batch, the Responses adapter applies these local checks to retained and newly returned images:

| Local check | Limit |
| --- | --- |
| Image count, including retained images and URL references | 600 |
| Serialized model request body, including history, tool definitions, and base64 image data | 48 MiB |

The adapter keeps new images in order up to the count limit, replacing later images with text `content_limit` errors. If the serialized request exceeds the byte limit, newly returned images are then omitted from the end until it fits or no new images remain. Text descriptions, command outcomes, diagnostics, and earlier context remain available.

The separate [whole-request budget](architecture.md#bounded-model-context) may require a handover before the next model round.

The model service handles image decoding, dimensions, URL retrieval, and limits on fetched content. Local checks do not ensure that the complete request meets every service limit.

## Context and continuity

A session's runtime context retains accepted image bytes, so subsequent requests can reuse them even if the source file changes or is removed. URL results retain the supplied address; their content can change or become unavailable.

Compaction or session release can discard retained image bytes. An artifact or memory entry provides a source for reading the image again; keep its location in a handover when needed for continued work. See [startup and interruption](architecture.md#startup-and-interruption) for what a restart retains.
