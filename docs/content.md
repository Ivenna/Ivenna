# Tool content

A tool result can contain several parts. When it supplies media, the accompanying text identifies the source, such as a resource URI or memory address. For observations delivered as events, see the [input contract](input.md#retained-records).

## Automatic classification

Readers recognize JPEG, PNG, GIF, and WebP by signature and PDF by its header. Other bytes qualify as text when they are valid UTF-8 and contain no NULs. A window can show text before a later window encounters binary data.

A local resource preview can direct the focus to an image or file view. A memory read can open media directly. A host command gives the focus a path to read partial text or binary output. See [resource views](resources.md#local-files-and-directories), [memory reads](memory.md#reading), and [command output](host.md#output-and-results).

## Context and continuity

While a tool result remains in working history, later turns can use its text, including any source description, and the retained media data. This applies across restarts.

| Media in the tool result | What working history retains |
| --- | --- |
| Inline image | The image bytes as read, even if the source later changes. |
| Image data URL | The URL, including the encoded image. |
| HTTP(S) image URL | The URL. It can later serve a different image or become unavailable. |
| Uploaded file | The DeepSeek file ID. Using it requires access to the account that still holds the file. |

The runtime saves the complete tool round before the next inference, subject to the mail service's [working history limits](running.md#working-history-limits).

Compaction can summarize the exchange that contains a tool result. If the handover records the host path or memory address, the focus can reopen the source to see its current contents. See [handovers](input.md#handover-generation-and-replacement) and [uploaded file retention](running.md#uploaded-model-files).

## Source size limits

When a resource or memory read identifies an oversized source, `result.content.unavailable` gives its `byte_length` and the reason.

| Reason | Meaning |
| --- | --- |
| `image_too_large` | Image data exceeds 32 MiB |
| `reference_too_large` | A local file or memory entry opened as an image URL exceeds 16 KiB |
| `file_too_large` | A file attachment exceeds 32 MiB |

## Complete files

Opening a file as an attachment uploads its current contents to DeepSeek. Later requests that include the tool result reuse the saved file ID. Reopening the source as an attachment starts another upload.

DeepSeek charges by the page when document parsing succeeds during upload. Later inference that references the file incurs model input charges. See [DeepSeek's file parsing charges](https://api-docs.deepseek.com/guides/document_parsing/#billing).

For a failed or unconfirmed upload, the result includes the source description and a text part with the original `file.byte_length` and an `error` containing a code and message.

| Code | What happened |
| --- | --- |
| `file_upload_failed` | The upload stopped before sending the file, or the file service rejected it. The message distinguishes these outcomes and identifies a size or rate limit when reported. |
| `file_upload_uncertain` | The adapter could not confirm whether the service stored the file. A new upload could create another copy. |

## Image URL references

An HTTP(S) image reference asks the model service to retrieve the image during inference. For a data URL stored in a local file or memory entry, the reader checks the source size, and the URL contributes to the encoded request size. See [source size limits](#source-size-limits), [local file views](resources.md#local-files-and-directories), and [image addresses in memory](memory.md#reading).

For each HTTP(S) image URL longer than 8192 Unicode code points, the adapter sends a JSON text part in place of the image. Its `error` object contains `code: "content_limit"`, a `message`, `omitted_images: 1`, the measured length in `actual`, the allowed length in `maximum`, and `unit: "unicode_code_points"`. The request still includes the source description, and history keeps the URL.

## Model request checks

The Responses adapter checks the complete encoded request, including retained and newly produced tool results.

| Check | Limit |
| --- | --- |
| Image parts sent in the request | 600 |
| File references | 20 |
| Encoded request body | 48 MiB |

The model service also checks limits that depend on processed input. A file reference may expand into text and images that count toward those limits. See DeepSeek's [image limits](https://api-docs.deepseek.com/guides/vision/#limits) and [document input limits](https://api-docs.deepseek.com/guides/document_parsing/#step-2-reference-a-document-in-chat).

Compaction can make room for the latest complete tool exchange. If the kernel still cannot assemble an ordinary request within the adapter's limits, the focus pauses with its saved tool results intact. See [how compaction works](architecture.md#bounded-model-context).
