# Tool content

Tool results can carry text, images, or complete files into the calling focus's working history. This guide describes what the model receives when a tool returns media. See the [input contract](input.md#retained-records) for observations delivered as events.

## Automatic classification

Readers recognize JPEG, PNG, GIF, and WebP by signature and PDF by its header. Other bytes qualify as text when they are valid UTF-8 and contain no NULs. A window can show text before a later window encounters binary data.

- A local resource preview returns a passage of text or a reference to the image or file. Open the suggested view to receive the media. See [resource views](resources.md#local-files-and-directories).
- A host command returns complete short text inline. Partial text and binary output include a path to the full log. See [command output](host.md#output-and-results).
- Reading a memory entry returns a passage of text, a complete image, or a complete file. See [memory reads](memory.md#reading).

## Content and results

When a tool supplies media, an accompanying text part identifies its source. An image part carries the image bytes or an [image URL](#image-url-references). A file part carries the complete source for [upload](#complete-files).

When the reader identifies an oversized source, `content.unavailable` gives its `byte_length` and the reason.

| Reason | Meaning |
| --- | --- |
| `image_too_large` | Image data exceeds 32 MiB |
| `reference_too_large` | A source opened as an image URL exceeds 16 KiB |
| `file_too_large` | A file attachment exceeds 32 MiB |

## Complete files

The Responses adapter uploads a new file attachment to the configured model service for parsing. The returned file reference travels with the tool result and is reused on later turns. The service can expand the reference into text and images during inference. See DeepSeek's [file parsing guide](https://api-docs.deepseek.com/guides/document_parsing/).

If the upload ends without a usable reference, a text part replaces the attachment. It gives the original `file.byte_length` and an `error` with a code and message. The rest of the tool result is still available.

| Code | What happened |
| --- | --- |
| `file_upload_failed` | The upload stopped before sending the file, or the file service rejected it. The message distinguishes these outcomes and identifies a size or rate limit when reported. |
| `file_upload_uncertain` | The adapter could not confirm whether the service stored the file. A new upload could create another copy. |

The service status is available in the kernel log. See [upload handling](architecture.md#tool-results).

## Image URL references

An HTTP(S) image reference asks the model service to retrieve the image during inference. An image data URL contains encoded image data. A data URL opened from a file or memory counts toward the reader's reference limit and the encoded request size. See [remote images](resources.md#remote-images), [local file views](resources.md#local-files-and-directories), and [image addresses in memory](memory.md#reading).

For each HTTP(S) image URL longer than 8192 Unicode code points, the adapter sends a JSON text part in place of the image. Its `error` object contains `code: "content_limit"`, a `message`, `omitted_images: 1`, the measured length in `actual`, the allowed length in `maximum`, and `unit: "unicode_code_points"`. The tool's source description stays alongside the notice, and working history retains the original URL.

## Model request checks

The Responses adapter checks the complete encoded request, including retained and newly produced tool results.

| Check | Limit |
| --- | --- |
| Image parts sent in the request | 600 |
| File references | 20 |
| Encoded request body | 48 MiB |

The model service also checks limits that depend on processed input. A file reference may expand into text and images that count toward those limits. See DeepSeek's [image limits](https://api-docs.deepseek.com/guides/vision/#limits) and [document input limits](https://api-docs.deepseek.com/guides/document_parsing/#step-2-reference-a-document-in-chat).

Compaction can make room for the latest complete tool exchange. If the kernel still cannot assemble an ordinary request within the adapter's limits, the focus pauses with its saved tool results intact. See [how compaction works](architecture.md#bounded-model-context).

## Context and continuity

Working history retains accepted image and file bytes across turns and restarts, along with any file upload reference. For an image supplied by HTTP(S) URL, history retains the address. The remote image can change or become unavailable.

Unloading a context preserves its retained content. Compaction can remove media from working history. A handover can carry the host path or memory address so the focus can reopen the source later. Uploaded files have a separate [model-service retention lifecycle](running.md#uploaded-model-files).
