# Tool content

Tool results can carry text, images, or complete files into a focus's working history. For the source and reading options, see [resource reads](resources.md), [memory reads](memory.md#reading), and [host command output](host.md#output-and-results). For observations delivered as events, see the [input contract](input.md#retained-records).

## Automatic classification

Readers recognize JPEG, PNG, GIF, and WebP images by their byte signatures. This identifies the format before any pixels are decoded. A PDF header selects a file attachment even when the rest of the file is valid text. For other bytes, readers return UTF-8 text when it contains no NUL bytes and a file attachment when they encounter binary content.

Classification covers the bytes inspected. A text window can therefore return text even though a later window reveals binary data. Once a reader recognizes media in a host file, memory entry, or completed command's stdout, it returns the whole image or file, subject to the source size limit.

Host stderr and running output supply a text preview or an unavailable-content diagnostic. The command's input mode determines whether streams are separate and whether terminal processing can alter their bytes. See [host input modes](host.md#input-modes).

## Content and results

The text part describes the operation and its source. A resource read identifies the resource by URI, a memory read by entry address, and a command result by its state and log references. When the tool supplies media, the description identifies a separate content part.

| Description | Fields | Native part |
| --- | --- | --- |
| `image.data` | `format` and `byte_length` | Encoded image bytes |
| `image.url` | Empty object | The supplied URL |
| `file` | `byte_length` | Complete source bytes |

When a source exceeds its size limit or a text-only stream contains binary data, the reader returns an `unavailable` description with the `byte_length` and reason.

| Reason | Meaning |
| --- | --- |
| `unsupported_binary` | Binary bytes were encountered in a result that can only supply text, such as stderr or running output |
| `image_too_large` | Recognized image data exceeds 32 MiB |
| `reference_too_large` | The source selected for image-reference interpretation exceeds 16 KiB |
| `file_too_large` | A source to be supplied as a complete file exceeds 32 MiB |

The surrounding result identifies whether the diagnostic concerns a complete source or a selected range. It preserves the operation outcome and the reference to the source.

## Complete files

The adapter uploads a new file attachment to the configured model service for parsing and uses the returned file reference in the model request. See DeepSeek's [file parsing guide](https://api-docs.deepseek.com/guides/document_parsing/) for supported inputs, parsing behavior, and service limits.

If the upload ends without a usable reference, a JSON text part replaces the attachment. It gives the original `file.byte_length` and an `error` with a code and message. Other parts still describe the operation, including the exit status and log paths of a completed host command.

| Code | What happened |
| --- | --- |
| `file_upload_failed` | The adapter could not send the file, or the file service rejected it. A rejection includes `error.http_status`. |
| `file_upload_uncertain` | The adapter received no usable reference. The file service may already have stored the file. |

See [upload handling](architecture.md#tool-results) for how the adapter handles these outcomes.

## Image URL references

For an HTTP(S) image reference that passes the [model request checks](#model-request-checks), the adapter sends the URL to the configured model service for retrieval. A focus can supply the URL directly through the image view in [resource reads](resources.md#remote-images).

A memory entry or a command's final stdout can itself contain an image URL. With `interpretation: "image_url"`, the reader passes the entire nonempty text as one reference if it fits the source limit. Empty output stays text, and recognized images and files keep their native representation. See [source limits](#content-and-results), [memory reads](memory.md#reading), and [host results](host.md#output-and-results).

## Model request checks

The Responses adapter checks new media against these local limits while accounting for retained content:

| Check | Limit |
| --- | --- |
| HTTP(S) image URL length | 8192 Unicode code points |
| Image count, including retained images and URL references | 600 |
| File references, including retained references | 20 |
| Serialized request body, including history, tools, base64 images, and file references | 48 MiB |

A data URL read from memory or stdout counts toward both the source size limit and the serialized request size.

The adapter omits new HTTP(S) image URL parts that exceed the code point limit, then keeps new images and files in order up to their count limits. Files beyond the count limit are omitted before upload. If the serialized request exceeds the byte limit, it omits new images from the end until the request fits or no new images remain. Each omitted part becomes a text part containing an `error` with code `content_limit`. The operation description, source, and other parts remain available.

These checks only remove new media. Retained content, text, or file-reference metadata can still leave the request above the serialized byte limit. Before inference, the kernel checks the remaining request against its configured [context budgets](running.md#context-budgets).

## Context and continuity

Working history retains accepted image and file bytes for later requests and restart, independently of changes to the source. Opaque file upload references are retained with their bytes. URL references retain the supplied address; the referenced content can change or become unavailable.

Unloading a context preserves its retained content. Compaction can remove media from working history, so preserve an artifact or memory address in the handover when it may need to be read again. Uploaded files have a separate [model-service retention lifecycle](running.md#uploaded-model-files). See [startup and interruption](architecture.md#startup-and-interruption) for what restart retains.
