# Tool content

Memory reads and host commands can return text or images directly to the model. `read_memory` classifies an entry's contents; `run_host_shell` classifies stdout and returns stderr as diagnostics.

Memory entries can contain any file type. This guide describes content returned to the model; the [memory guide](memory.md) covers writing and managing entries.

## Expected content

Both tools accept an optional `expected` argument. Select exactly one branch below, or omit the argument for automatic classification. An image expectation defaults to `representation: "data"`.

| Value | Meaning |
| --- | --- |
| `{"auto":{}}` | Identify text or a supported image from the output bytes |
| `{"text":{}}` | Expect text |
| `{"image":{}}` | Expect image data |
| `{"image":{"representation":"url"}}` | Expect an image URL reference |

Text and image-data expectations are hints; classification uses the actual bytes.

Read an image entry with `read_memory`:

```json
{"address":"screenshots/dashboard.png","expected":{"image":{}}}
```

Supply a host file through `run_host_shell`:

```json
{"command":"cat /path/to/screenshot.png","expected":{"image":{}}}
```

Memory addresses are relative to the shared memory entrance. Shell paths use the service account's filesystem; a relative path is resolved by the command's working directory. See [memory rooms](memory.md) and [host shell](host.md) for arguments and access boundaries.

## Image URL references

With `expected: {"image":{"representation":"url"}}`, either tool passes its entire nonempty text output unchanged as one native image reference. Recognized image bytes still return as image data. Retrieval and validation of the reference belong to the configured model service. Empty output remains text.

For example, a shell command can return an image reference:

```json
{"command":"printf '%s' 'https://example.com/image.png'","expected":{"image":{"representation":"url"}}}
```

With automatic, text, or image-data expectations, URLs remain text.

## Content and results

Supported image formats are JPEG, PNG, GIF, and WebP, identified by their format signatures. Image bytes returned to the model may contain at most 32 MiB per image. Text results require valid UTF-8 without NUL bytes.

Memory reads retain the full text of an entry. Shell text is returned as a preview of at most 16 KiB, retaining the beginning and end when truncated. For larger non-image shell output, text detection checks only the previewed bytes. Full stdout and stderr remain in their log files. An image expectation with `representation: "url"` reads the full stdout text so that its reference is not truncated.

Content that cannot be supplied as text or a supported image produces a text diagnostic with its byte length and reason. Recognized images exceeding the size limit also return a diagnostic. If a stderr preview contains binary data or invalid UTF-8, it returns an `unsupported_binary` diagnostic.

Each memory entry or stdout capture supplies one content value. A tool result starts with a JSON text summary of the operation, followed by any native image part. Text content remains in the summary. These parts are sent together in the next model request. See [memory results](memory.md#results-and-errors) and [shell results](host.md#results-and-interruption) for their structures.

## History and limits

Image bytes are saved in session history, so later requests and service restarts use the same content even if the source file changes or is removed. For image URLs, history saves the address; later requests may retrieve changed content or fail if the URL becomes unavailable.

Images remain part of the full history sent on later requests and contribute to request size and context limits. See [model input and history](architecture.md#model-input-and-history) for replay behavior.

When adding newly returned images to history, Ivenna applies two request checks, based on [DeepSeek's image limits](https://api-docs.deepseek.com/guides/vision/#limits):

| Local check | Limit |
| --- | --- |
| Image count, including saved images and URL references | 600 |
| Serialized model request body, including base64 image data | 48 MiB |

The configured model service handles image decoding, dimensions, URL retrieval, and aggregate image limits including fetched content. Local checks can omit new images; they do not ensure that a request meets every model limit. Earlier history or text alone can exceed the request-size limit, and inputs merged after these checks can increase the request size further.

Invalid tool arguments return `invalid_arguments`. Images rejected by Ivenna's model request checks are omitted from saved history and accompanied by a `content_limit` error. Other text from the same tool result is retained, including memory addresses, command outcomes, and stream descriptions. Image rejection does not change the reported command outcome.

Format recognition does not validate the complete image or decode its pixels. The model service may reject image data or fail to fetch a URL, causing the model request and session to fail. [Resuming](usage.md#continuing-and-resuming) reuses saved image bytes and references. To retry corrected image bytes, start a new session; changing the source file does not replace the saved image. See [tool content](architecture.md#tool-content) for implementation boundaries.
