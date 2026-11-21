# Tool content

Memory reads and host tool results combine an operation description with text, image, or file content. This guide defines shared classification, image references, omission diagnostics, and model-request limits. The [memory](memory.md) and [host](host.md) guides define each tool's arguments, source fields, and continuation rules; the [input contract](input.md#retained-records) covers observations delivered as events.

## Automatic classification

Text is valid UTF-8 without NUL bytes. Readers recognize JPEG, PNG, GIF, and WebP from byte signatures; recognition does not decode pixels or validate the complete image. Other binary content is supplied as a file. A PDF header also selects file handling when the remaining bytes would qualify as text. Filenames and URL suffixes do not select a content type.

Text can be returned in bounded ranges or previews. Its classification covers only the bytes read; omitted bytes may contain binary content. Images and files are supplied from complete sources: memory entries or final host stdout. An image or PDF header, or binary content in a selected text range or preview, selects complete-source reading.

Readers limit each image or file source to 32 MiB. Host stderr and running output supply only text or an unavailable-content diagnostic. Host [input modes](host.md#input-modes) determine whether streams are separate and whether terminal processing can alter their bytes.

## Complete files

Files contain the complete source bytes, independently of text page or preview budgets. A binary range is never supplied as though it were the whole file. Omit `interpretation` when reading a file; the [memory](memory.md#reading) and [host](host.md#output-and-results) guides show the ordinary read operations.

The configured model service owns file format recognition and parsing. See DeepSeek's [file parsing guide](https://api-docs.deepseek.com/guides/document_parsing/) for supported inputs, parsing behavior, and service limits.

If the upload ends without a usable reference, a JSON text part replaces the attachment. It gives the original `file.byte_length` and an `error` with a code and message. Other parts still describe the operation, including the exit status and log paths of a completed host command.

| Code | What happened |
| --- | --- |
| `file_upload_failed` | The adapter could not send the file, or the file service rejected it. A rejection includes `error.http_status`. |
| `file_upload_uncertain` | The adapter received no usable reference. The file service may already have stored the file. |

See [upload handling](architecture.md#tool-results) for how the adapter handles these outcomes.

## Image URL references

A URL remains text unless `interpretation: "image_url"` is set on the read or command. This presents the complete nonempty text as one image URL reference, with a 16 KiB source limit. Ivenna preserves the text without validating URL syntax or fetching the media. A partial text range is never used as an image reference.

Recognized images and files retain their native representation, and empty output remains text. The [model request checks](#model-request-checks) can omit a reference before inference; references that pass are handled by the model service. The tool-specific requirements and examples are in [memory reads](memory.md#reading) and [host results](host.md#output-and-results).

## Content and results

A tool result contains text describing the operation and its source. Images and complete files add a native content part alongside that description. Memory results identify the entry address; host results preserve command state and log paths, including on nonzero exits and timeouts.

Media descriptions accompany their native content:

| Description | Fields | Native part |
| --- | --- | --- |
| `image.data` | `format` and `byte_length` | Encoded image bytes |
| `image.url` | Empty object | The supplied URL |
| `file` | `byte_length` | Complete source bytes |

Content that cannot be supplied has an `unavailable` description with `byte_length` and one reason:

| Reason | Meaning |
| --- | --- |
| `unsupported_binary` | Binary bytes were encountered in a result that can only supply text, such as stderr or running output |
| `image_too_large` | Recognized image data exceeds 32 MiB |
| `reference_too_large` | The source selected for image-reference interpretation exceeds 16 KiB |
| `file_too_large` | A source to be supplied as a complete file exceeds 32 MiB |

The surrounding result identifies whether the diagnostic concerns a complete source or a selected range. An unavailable-content diagnostic leaves the operation outcome and stored source intact. The [memory](memory.md#results-and-errors) and [host](host.md#output-and-results) guides define those source descriptions.

## Model request checks

The Responses adapter checks new media against these local limits while accounting for retained content:

| Check | Limit |
| --- | --- |
| HTTP(S) image URL length | 8192 Unicode code points |
| Image count, including retained images and URL references | 600 |
| File references, including retained references | 20 |
| Serialized request body, including history, tools, base64 images, and file references | 48 MiB |

Image references supplied as text first pass the [16 KiB source limit](#image-url-references). Data URL references remain subject to this source limit and the serialized request byte limit; the HTTP(S) code point limit does not apply to them.

The adapter omits new HTTP(S) image URL parts that exceed the code point limit, then keeps new images and files in order up to their count limits. Files beyond the count limit are omitted before upload. If the serialized request exceeds the byte limit, it omits new images from the end until the request fits or no new images remain. Each omitted part becomes a text part containing an `error` with code `content_limit`. The operation description, source, and other parts remain available.

These checks only remove new media. Retained content, text, or file-reference metadata can still leave the request above the serialized byte limit. Before inference, the kernel checks the remaining request against its configured [context budgets](running.md#context-budgets).

## Context and continuity

Working history retains accepted image and file bytes for later requests and restart, independently of changes to the source. Opaque file upload references are retained with their bytes. URL references retain the supplied address; the referenced content can change or become unavailable.

Unloading a context preserves its retained content. Compaction can remove media from working history, so preserve an artifact or memory address in the handover when it may need to be read again. Uploaded files have a separate [model-service retention lifecycle](running.md#uploaded-model-files). See [startup and interruption](architecture.md#startup-and-interruption) for what restart retains.
