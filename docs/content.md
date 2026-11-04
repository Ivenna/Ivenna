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

Content that cannot be supplied as text or a supported image produces an `unsupported_binary` text diagnostic with its byte length. Recognized images exceeding the byte limit produce an `image_too_large` diagnostic.

The [memory](memory.md#results-and-errors) and [shell](host.md#results-and-interruption) guides describe how content appears in each tool's reply. Shell stdout and stderr remain in full in their log files.

## Model request checks

When adding newly returned images to history, Ivenna applies these local checks:

| Local check | Limit |
| --- | --- |
| Image count, including saved images and URL references | 600 |
| Serialized model request body, including history, tool definitions, and base64 image data | 48 MiB |

An image rejected by these checks is replaced by a text `content_limit` error before history is saved. Existing history and text results remain intact. See [model input and history](architecture.md#model-input-and-history) for the check timing and scope.

The model service handles image decoding, dimensions, URL retrieval, and limits on fetched content. Local checks do not ensure that the complete request meets every service limit.

## History and recovery

Session history saves accepted image bytes, so later requests reuse them even if the source file changes or is removed. URL results save the supplied address; their content can change or become unavailable.

Saved images remain in the full history sent on later requests and contribute to request size and context limits. See [model input and history](architecture.md#model-input-and-history) for replay behavior.

[Resuming](usage.md#continuing-and-resuming) a failed session reuses its saved content. Changing the source file does not replace a saved image. To retry without that image in history, start a new session and read the corrected source.
