# Tool content

Memory reads and host tool results combine an operation description with text or image content. This guide defines shared classification, image references, omission diagnostics, and model-request limits. The [memory](memory.md) and [host](host.md) guides define each tool's arguments, source fields, and continuation rules; the [input contract](input.md#retained-records) covers observations delivered as events.

## Automatic classification

Readers recognize JPEG, PNG, GIF, and WebP from their byte signatures, with a limit of 32 MiB per image. Recognition does not decode pixels or validate a complete image. Text must be valid UTF-8 without NUL bytes. A filename or URL suffix does not select a media type, and a URL remains text unless image-reference interpretation is requested.

An image is classified from one complete source: a memory entry or final stdout. Text can be returned in bounded ranges or previews. For larger non-image sources, text detection checks the returned bytes; omitted bytes have not necessarily been classified.

Host stderr is text-only. Host [input modes](host.md#input-modes) determine whether the streams are separate and whether terminal processing can alter their bytes.

## Image URL references

Set `interpretation: "image_url"` on a memory read or host command to present the source's complete nonempty text as one image URL reference. For host commands, interpretation waits for final stdout. A reference has a 16 KiB byte limit; a larger source returns `reference_too_large`. Recognized image bytes retain their image-data representation, and empty output remains text.

Ivenna supplies the text unchanged, without fetching or validating the URL or referenced media. The configured model service handles the reference. For example:

```json
{"name":"image-reference","command":"printf '%s' 'https://example.com/image.png'","interpretation":"image_url"}
```

Omit `interpretation` when the source already contains image bytes or when a URL should remain text. A partial text range is never treated as an image reference.

## Content and results

A tool result contains text describing the operation and its source. Supported images add a native content part alongside that description. Memory results identify the entry address; host results preserve command state and log paths, including on nonzero exits and timeouts.

An image description has one branch:

| Branch | Description | Native part |
| --- | --- | --- |
| `data` | `format` and `byte_length` | Encoded image bytes |
| `url` | Empty object | The supplied URL |

Content that cannot be supplied has an `unavailable` description with `byte_length` and one reason:

| Reason | Meaning |
| --- | --- |
| `unsupported_binary` | The selected bytes cannot be supplied as text or as an image in this result |
| `image_too_large` | Recognized image data exceeds 32 MiB |
| `reference_too_large` | The source selected for image-reference interpretation exceeds 16 KiB |

The surrounding result identifies whether the diagnostic concerns a complete source or a selected range. An unavailable-content diagnostic leaves the operation outcome and stored source intact. The [memory](memory.md#results-and-errors) and [host](host.md#output-and-results) guides define those source descriptions.

## Model request checks

At the end of each tool batch, the Responses adapter limits newly returned images against the complete request:

| Check | Limit |
| --- | --- |
| Image count, including retained images and URL references | 600 |
| Serialized request body, including history, tools, and base64 image data | 48 MiB |

The adapter keeps new images in order up to the count limit. If the serialized request exceeds the byte limit, it omits new images from the end until the request fits or no new images remain. Each omitted image part becomes a text part containing an `error` with code `content_limit`. The operation description, source, and other parts remain available.

These checks only remove new images. Retained content or text can still leave the request above these limits. The kernel's separate [whole-request budget](architecture.md#bounded-model-context) checks the remaining request before inference and can require a handover or end execution.

## Context and continuity

Working history retains accepted image bytes for later requests and restart, independently of changes to the source. URL references retain the supplied address; the referenced content can change or become unavailable.

Unloading a context preserves its retained content. Compaction can remove images from working history, so preserve an artifact or memory address in the handover when the image may need to be read again. See [startup and interruption](architecture.md#startup-and-interruption) for what restart retains.
