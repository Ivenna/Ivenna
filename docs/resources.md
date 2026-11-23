# Reading resources

The core and activities can both call `read_resource`. Pass an absolute `uri` to open a source, or call `read_resource({})` to list the kernel's startup directory. Each result enters the calling focus's working history.

By default, reads start at the beginning and return recognized local media whole. Pass a `view` object to select a window of text or directory entries. For an HTTP(S) URL, the default requests Markdown from the page reader when page retrieval is enabled. Set `view` to `"image"` to pass that URL to the configured model service as an image reference.

## Reading a window

`view.offset` gives the starting position, counting from zero. `view.limit` requests a positive number of bytes or entries. For example, `{"view":{"limit":10}}` lists up to ten entries from the startup directory.

| Source | Unit | Default and maximum window |
| --- | --- | --- |
| Text file or web page snapshot | UTF-8 bytes | 16 KiB |
| Directory listing | Entries | 100 entries |

To continue, pass `result.uri` and set `view.offset` to `result.next_offset`. Use the returned offset even when the window is shorter than requested. A null `next_offset` means the reader reached the end. Text windows preserve whole characters, even when the first character exceeds the requested limit.

Starting exactly at the end of the text or listing returns an empty window. An offset beyond the end or inside a UTF-8 character returns `invalid_range`. Each local read sees the current filesystem, so edits to a file or directory can shift later offsets.

## Local files and directories

Local reads follow symbolic links and use the kernel's OS account. To open a directory entry, pass its returned `uri`. An activity can also share a command's stdout or stderr URI with the core so it can read the log after the command ends. See [host command results](host.md#output-and-results).

To construct a file URI, use an absolute path with an empty host or `localhost`. Percent-encode spaces and literal `%`, `?`, or `#` in filenames. For example, `file:///srv/notes%20today.md` opens `/srv/notes today.md`. A relative link to `draft.md` in that document resolves to `file:///srv/draft.md`.

- **Directories.** The result lists one level in `entries`, ordered by filename bytes. Each entry has a `uri`, a `name`, and a `kind` (`file`, `directory`, `symlink`, or `other`). A name that cannot be represented in UTF-8 is null, and its URI remains usable. Metadata describes the entry itself. The `kind`, regular file size (`byte_length`), and modification time (`modified_ms`) are null when unavailable.
- **Text files.** The selected text is in `content`. The file's `byte_length` is null until the reader knows the length.
- **Images and binary files.** Open a known media file at offset zero. The result carries the whole image or file, or an `unavailable` description when it exceeds the media limit. A file can start with text and first reveal binary data during a later read. That read returns the whole file if it fits. To request an image explicitly, use `{"uri":"file:///srv/chart.png","view":"image"}`. The reader recognizes supported images by their bytes. See [content classification](content.md#automatic-classification) and [file attachments](content.md#complete-files).

## Web pages

To read a page as Markdown, pass an HTTP(S) URL with a host and no embedded username or password. Each read of the source URL requests a fresh snapshot. The tool description names the page service that receives the URL and indicates whether the request may incur a charge. See [web page access](running.md#web-page-access).

For example, `{"uri":"https://example.org/guide","view":{"limit":6}}` might return the heading of a page.

```json
{
  "result": {
    "uri": "ivenna:fetch/7198a8e09ae74b1c",
    "source_uri": "https://example.org/guide",
    "kind": "webpage",
    "title": "One",
    "title_truncated": false,
    "content": "# One\n",
    "byte_length": 37,
    "offset": 0,
    "next_offset": 6
  }
}
```

Here `source_uri` is the requested URL. The returned `uri` identifies the snapshot. Either focus can continue reading the same version without another fetch.

```json
{"uri":"ivenna:fetch/7198a8e09ae74b1c","view":{"offset":6}}
```

Suppose this window contains `[Next](https://example.org/two)` and has a null `next_offset`. The snapshot ends here. To visit the linked page, call `{"uri":"https://example.org/two"}`. Resolve relative links against the page's base URL when known. If the extracted text contains only a button label, the destination URL must come from another source.

The result includes a title preview. `title_truncated` is true when the preview omits part of the title. When a snapshot is no longer available, opening its `source_uri` can produce a different version.

## Remote images

To view a screenshot from a letter or an illustration linked in Markdown, pass the direct HTTP(S) URL. A URL can identify an image even if its path has no filename extension.

```json
{"uri":"https://example.org/figures/weekly-rainfall","view":"image"}
```

The result has `kind: "image_url"` and identifies the supplied URL in `uri`. The model service can retrieve the image from that address during inference. An inaccessible URL or a model without image support can cause the inference request to fail. Working history retains the URL, so a later turn may see a changed image or lose access to it. See [image URL references](content.md#image-url-references).

## Failure results

A failed read returns an `error` with a `code` and a `message`.

| Code | Meaning or next action |
| --- | --- |
| `invalid_arguments` | Check the argument shape. Put window fields inside a `view` object, or use the string `"image"` for the whole image. |
| `invalid_uri`, `unsupported_scheme` | Correct the reference or use a URI returned by an earlier read. |
| `unsupported_view` | The local source or Markdown snapshot cannot supply an image. Omit `view` for an ordinary read. |
| `invalid_range` | Use a valid offset. For a web page, `error.uri` identifies the snapshot already retrieved. |
| `not_found` | No local entry or retained snapshot was found at this URI. Open the original `source_uri` if a fresh snapshot is wanted. |
| `not_readable` | The source could not be read. The message gives the reason known to the reader. |
| `rate_limited`, `read_timeout` | The service is limiting requests or the read timed out. A later read may succeed. |
| `page_too_large` | The page is too large to retrieve or retain. A smaller reading window still requires the whole page. |
| `web_unavailable` | Page retrieval is unavailable. Check the message for the service's response or a configuration problem. |
