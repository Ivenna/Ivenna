# Tool content

One tool result can contain several parts, such as a source description and the image it identifies. The calling focus receives them together. For observations delivered as events, see the [input contract](input.md#retained-records).

## Automatic classification

Readers recognize JPEG, PNG, GIF, and WebP by signature and PDF by its header. Other bytes qualify as text when they are valid UTF-8 and contain no NULs. A window can show text before a later window encounters binary data.

- A local resource preview returns a passage of text or the URI and suggested view for an image or file. Open that view to receive the media. See [resource views](resources.md#local-files-and-directories).
- A host command returns complete short text inline. Partial text and binary output include a path to the full log. See [command output](host.md#output-and-results).
- A memory read returns a passage of text or opens the image or document stored at that address. See [memory reads](memory.md#reading).

## Context and continuity

Working history keeps the text a tool returns. When the tool supplies media, that text identifies its source, such as a resource URI or memory address. What a later turn can use, including after a restart, depends on how the media arrived.

| Media in the tool result | What working history retains |
| --- | --- |
| Inline image | The image bytes as read, even if the source later changes. |
| Image URL | The original address. A data URL contains the image itself. An HTTP(S) URL can later serve a different image or become unavailable. |
| Uploaded file | The file ID returned by DeepSeek. Later turns can use it while the file is available in the same account. |

Inline image bytes count toward the record's `HISTORY_INLINE_IMAGE_BYTES` budget. See [working history limits](running.md#working-history-limits) for how the kernel rejects an oversized record before writing it.

Compaction can replace a tool result with a handover. If the handover keeps the host path or memory address, the focus can reopen the source to see its current contents. Uploaded files have a separate lifetime in the DeepSeek account. See [handovers](input.md#handover-generation-and-replacement) and [uploaded model files](running.md#uploaded-model-files).

## Source size limits

When a resource or memory read identifies an oversized source, `result.content.unavailable` gives its `byte_length` and the reason.

| Reason | Meaning |
| --- | --- |
| `image_too_large` | Image data exceeds 32 MiB |
| `reference_too_large` | A source opened as an image URL exceeds 16 KiB |
| `file_too_large` | A file attachment exceeds 32 MiB |

## Complete files

Opening a file as an attachment uploads its current contents to DeepSeek. Later requests that include the same tool result reuse the saved `file_id`. Opening the source again as an attachment starts another upload. For a PDF, DeepSeek parses the document during upload and charges by the page when parsing succeeds. See DeepSeek's [file parsing and billing guide](https://api-docs.deepseek.com/guides/document_parsing/).

When the adapter reports a failed or unconfirmed upload, a text part replaces the attachment. It gives the original `file.byte_length` and an `error` with a code and message. The rest of the tool result is still available.

| Code | What happened |
| --- | --- |
| `file_upload_failed` | The upload stopped before sending the file, or the file service rejected it. The message distinguishes these outcomes and identifies a size or rate limit when reported. |
| `file_upload_uncertain` | The adapter could not confirm whether the service stored the file. A new upload could create another copy. |

For an HTTP rejection, check the `model file endpoint returned HTTP` entry in the kernel log. See [upload handling](architecture.md#tool-results).

## Image URL references

An HTTP(S) image reference asks the model service to retrieve the image during inference. A data URL opened from a file or memory counts toward both the [source size limit](#source-size-limits) and the encoded request size. See [remote images](resources.md#remote-images), [local file views](resources.md#local-files-and-directories), and [image addresses in memory](memory.md#reading).

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
