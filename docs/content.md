# Tool content

Memory reads and host commands can supply text or images to the model. This guide covers shared content handling; see [memory rooms](memory.md) and [host shell](host.md) for tool arguments and results.

## Expected content

`read_memory` and `run_host_shell` accept an optional `expected` argument for the complete entry or stdout capture. Omit it for automatic classification, or select exactly one branch below. An image expectation defaults to `representation: "data"`.

| Value | Meaning |
| --- | --- |
| `{"auto":{}}` | Identify text or a supported image from the output bytes |
| `{"text":{}}` | Expect text |
| `{"image":{}}` | Expect image data |
| `{"image":{"representation":"url"}}` | Expect an image URL reference |

Text and image-data expectations are hints; the actual bytes determine the content type.

## Image URL references

With `expected: {"image":{"representation":"url"}}`, classification treats the entire nonempty text output as one image URL reference. Ivenna passes the text unchanged, without fetching or validating the address. Recognized image bytes still return as image data, and empty output remains text. Retrieval and validation of a reference belong to the configured model service.

For example, a shell command can return an image reference:

```json
{"command":"printf '%s' 'https://example.com/image.png'","expected":{"image":{"representation":"url"}}}
```

With automatic, text, or image-data expectations, URLs remain text.

## Content and results

Supported image formats are JPEG, PNG, GIF, and WebP, identified by their format signatures. Image data is limited to 32 MiB per image. Signature recognition does not validate the complete image or decode its pixels. Text requires valid UTF-8 without NUL bytes.

Memory reads retain the full text of an entry. Shell text previews contain at most 16 KiB, retaining the beginning and end when truncated. For larger non-image shell output, text detection checks only the previewed bytes. URL-reference classification reads the full stdout so that the reference is not truncated.

Content that cannot be supplied as text or a supported image produces an `unavailable` description with its byte length and reason `unsupported_binary`. Recognized images exceeding the byte limit use reason `image_too_large`. These descriptions report what content can be supplied; they do not change the command outcome or remove a stored memory entry.

The [memory](memory.md#results-and-errors) and [shell](host.md#results-and-interruption) guides describe how content appears in each tool's reply. Shell stdout and stderr remain in full in their log files.

## Model request checks

When adding newly returned images to a session's context, Ivenna applies these local checks:

| Local check | Limit |
| --- | --- |
| Image count, including retained images and URL references | 600 |
| Serialized model request body, including history, tool definitions, and base64 image data | 48 MiB |

An image rejected by these checks is replaced by a text `content_limit` error. The tool has already run: this error means its image was omitted from model input. Existing context and text results remain intact at this step.

The [whole-context budget](architecture.md#bounded-model-context) applies separately and may be smaller than these image limits. It accounts for the complete request, including text and images. An oversized history can require a handover or produce a context-budget failure before the next model round.

The model service handles image decoding, dimensions, URL retrieval, and limits on fetched content. Local checks do not ensure that the complete request meets every service limit.

## Context and continuity

A session's runtime context retains accepted image bytes, so subsequent requests can reuse them even if the source file changes or is removed. URL results retain the supplied address; their content can change or become unavailable.

Retained images contribute to request size and context limits. A handover can replace older context, and a restart rebuilds understanding from letters rather than restoring these image bytes. Keep an artifact or memory entry when later work needs to read the image again, and include its location in the handover. See [bounded model context](architecture.md#bounded-model-context).
