# Reading resources

Both the core and activities can call `read_resource`. Use an absolute host path or file URI for [local files and directories](#local-files-and-directories), or omit `location` to list the kernel's startup directory. An HTTP(S) URL opens a [remote image](#remote-images) with the image view or a [web page](#web-pages) when page retrieval is enabled.

## Reading a window

Omit `view` to read the first page. To request a particular page size, set `view.limit`. For text files and web pages, the size and offset count UTF-8 bytes. For directories, they count entries. For example, `{"view":{"limit":10}}` lists up to ten entries from the startup directory.

A page can be shorter than requested even when more remains. Text pages preserve whole characters, so the first character can exceed a small byte request. To continue, pass `result.uri` as `location` and `result.next_offset` as `view.offset`. The final page omits `next_offset`.

Starting exactly at the end of the text or listing returns an empty window. An offset beyond the end or inside a UTF-8 character returns `invalid_range`.

## Local files and directories

Pass a [command log's path](host.md#output-and-results) directly as `location`. The reader follows symbolic links when opening a path. Each read sees the current filesystem, so edits between reads can shift offsets.

Opening a text file in the default view returns a passage in `result.content`, with `byte_length` when known. If the reader encounters a recognized image, a PDF, or binary data, the preview gives the file's `uri`, `byte_length`, and the `view` to use. To receive the media, pass that URI as `location` with the suggested view. An oversized source gives its size and reason in `content.unavailable`. See [source limits](content.md#content-and-results).

You can also request the view directly. For example, this call attaches a complete local file for the model service to parse.

```json
{"location":"/srv/report.pdf","view":"file"}
```

Use `"image"` to open a recognized image file. If a file contains only a direct HTTP(S) image URL or an image data URL, the default view reads the address as text. The image view reads the complete address as an image reference and accepts a single trailing LF or CRLF.

Opening a directory lists its entries in filename byte order. Each entry has a reusable `uri`, a `name` when it is valid UTF-8, and a `kind` when known. Long paths can shorten a page. To include modification times (`metadata.modified_ms`, milliseconds since the Unix epoch) and regular-file sizes (`metadata.byte_length`) when available, request `{"view":{"metadata":true}}`.

Absolute paths are literal, so `/srv/reports/Q4 #1%.pdf` opens the file with exactly that name. A file URI has an empty host or `localhost` and uses percent escapes for spaces and literal `%`, `?`, or `#` in filenames. The reader can return a URI such as `file:///srv/reports/Q4-%FF.pdf` for a name containing non-UTF-8 bytes.

## Web pages

When web page access is enabled, use an HTTP(S) URL with the default view to fetch the page as Markdown. The URL must have a host and omit embedded usernames and passwords. The tool description names the service that receives the URL and indicates whether fetching the page may incur a charge. See [web page access](running.md#web-page-access).

Use `result.uri` as `location` to read the same snapshot in the core or an activity without another fetch. Use `result.source_uri`, the original URL, as `location` to fetch a fresh copy.

For example, `{"location":"https://example.org/guide","view":{"limit":6}}` might return the heading of a page.

```json
{
  "result": {
    "uri": "ivenna:fetch/7198a8e09ae74b1c",
    "source_uri": "https://example.org/guide",
    "kind": "webpage",
    "title": "One",
    "content": "# One\n",
    "byte_length": 37,
    "offset": 0,
    "next_offset": 6
  }
}
```

This window contains the first six bytes of a 37-byte snapshot. Continue from `next_offset` using the snapshot URI.

```json
{"location":"ivenna:fetch/7198a8e09ae74b1c","view":{"offset":6}}
```

The initial fetch and a snapshot read from offset zero include the original URL and the title when available. A shortened title carries `title_truncated: true`. Later windows omit these fields. Snapshots expire when the kernel restarts or needs room for newer pages.

To follow a link in the Markdown, pass its destination URL. Resolve a relative link against the page's base URL when known.

## Remote images

To view a screenshot from a letter or an illustration linked in Markdown, pass the direct HTTP(S) URL with `"view":"image"`. This view also works when web page access is disabled.

```json
{"location":"https://example.org/figures/weekly-rainfall","view":"image"}
```

The tool identifies the original URL in `result.uri` and supplies an image reference. The model service can retrieve the image during inference when the URL is reachable, the model supports images, and the reference fits the [image URL limit](content.md#image-url-references).

## Failure results

A failed read returns an `error` with a `code` and a `message`.

| Code | Meaning or next action |
| --- | --- |
| `invalid_arguments` | Check the argument shape. Use a window object, `"image"`, or `"file"` for `view`. |
| `invalid_path` | Supply an absolute host path with no NUL bytes. |
| `invalid_uri`, `unsupported_scheme` | Correct the reference or use a URI returned by an earlier read. |
| `unsupported_view` | The source cannot provide the requested view. See the message for the available read. |
| `invalid_range` | Resume at a returned `next_offset` or omit `view` to start at zero. For a web page, use `error.uri` to read the snapshot already retrieved. |
| `not_found` | The local entry or snapshot is missing. For an expired snapshot, open the original `source_uri` to fetch a fresh copy. |
| `not_readable` | Check the message for the cause, such as a file exceeding the view's size limit during the read. |
| `rate_limited`, `read_timeout` | The service is limiting requests or the read timed out. A later read may succeed. |
| `page_too_large` | The page is too large to retrieve or retain. A smaller reading window still requires the whole page. |
| `web_unavailable` | Check the message to see whether page retrieval is disabled or the page service could not complete the request. |
