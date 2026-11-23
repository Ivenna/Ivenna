# Tool content

Tool results can carry text, images, or complete files into the calling focus's working history. A focus can ask to see an image by supplying its location. The reader returns the image as a separate part of the tool result. Observations delivered as events have their own [input contract](input.md#retained-records).

## Automatic classification

Readers recognize JPEG, PNG, GIF, and WebP by signature and PDF by its header. Other bytes qualify as text when they are valid UTF-8 and contain no NULs. A window can show text before a later window encounters binary data.

- A local resource preview returns a passage of text or a reference to the image or file. Open the suggested view to receive the media. See [resource views](resources.md#local-files-and-directories).
- A host command returns complete short text inline. Partial text and binary output include a path to the full log. See [command output](host.md#output-and-results).
- Reading a memory entry returns a passage of text, a complete image, or a complete file. See [memory reads](memory.md#reading).

## Content and results

When a tool supplies media, a text part identifies the source. An image part carries either the image bytes or an image URL. In a model request, the Responses adapter sends image bytes as a Base64 data URL in the image part. A file part carries the complete source for [upload](#complete-files).

When the reader identifies an oversized source, `content.unavailable` gives its `byte_length` and the reason.

| Reason | Meaning |
| --- | --- |
| `image_too_large` | Image data exceeds 32 MiB |
| `reference_too_large` | A source containing an image URL exceeds 16 KiB |
| `file_too_large` | A file attachment exceeds 32 MiB |

## Complete files

The Responses adapter uploads a new file attachment to the configured model service for parsing. It uses the returned file reference in the current request and reuses it on later turns. For supported inputs and service limits, see DeepSeek's [file parsing guide](https://api-docs.deepseek.com/guides/document_parsing/).

If the upload ends without a usable reference, a text part replaces the attachment. It gives the original `file.byte_length` and an `error` with a code and message. The rest of the tool result is still available.

| Code | What happened |
| --- | --- |
| `file_upload_failed` | The adapter could not send the file, or the file service rejected it. A rejection includes `error.http_status`. |
| `file_upload_uncertain` | The adapter could not confirm whether the service stored the file. A new upload could create another copy. |

See [upload handling](architecture.md#tool-results) for how the adapter handles these outcomes.

## Image URL references

An HTTP(S) image reference asks the model service to retrieve the image during inference. An image data URL already contains the image. If a command writes a data URL to a file, the focus can open the path in the image view. See [remote images](resources.md#remote-images), [local file views](resources.md#local-files-and-directories), and [image addresses in memory](memory.md#reading).

## Model request checks

Media that fit the reader's source limits must also fit in the model request. The Responses adapter includes retained media when checking new tool results against its own serialization ceiling and the provider's limits for [images](https://api-docs.deepseek.com/guides/vision/#limits) and [documents](https://api-docs.deepseek.com/guides/document_parsing/). The ceiling is a capability of the adapter; the kernel's request budget is a separate policy and is never passed down as an attachment limit.

| Check | Limit |
| --- | --- |
| HTTP(S) image URL length | 8192 Unicode code points |
| Image count, including retained images and URL references | 600 |
| File references, including retained references | 20 |
| Serialized request body when adding images, including history, tools, and file references | The adapter's serialization ceiling (48 MiB by default) |

An image data URL opened from a file or memory counts toward both the reference size limit and the serialized request size.

When new media exceed a count limit, earlier parts take priority. Files beyond the limit are omitted before upload. A new image can also be omitted to fit the adapter ceiling. Every omission records `content_limit` with the ceiling, the number and bytes of dropped parts, and the source when one is known. If the batch still exceeds the ceiling, the largest tool result is replaced by such a record; if it still does not fit, the round fails instead of sending an oversized request. Each omitted part reports `content_limit` alongside the source and the other results. Before inference, the kernel measures the actual request, including retained history and newly arrived observations, against its [context budget](running.md#context-budgets).

## Context and continuity

Working history retains accepted image and file bytes across turns and restarts, along with any file upload reference. For an image supplied by HTTP(S) URL, history retains the address. The remote image can change or become unavailable.

Unloading a context preserves its retained content. Compaction can remove media from working history. A handover can carry the host path or memory address so the focus can reopen the source later. Uploaded files have a separate [model-service retention lifecycle](running.md#uploaded-model-files).
