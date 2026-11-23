# Reading resources

The core and activities can both call `read_resource`. Pass an absolute `uri` to open a local file, a directory, or a web resource. With no arguments, the tool lists the kernel's startup directory. The result enters the calling focus's working history.

An HTTP(S) URL must have a host and omit embedded usernames and passwords. With the default view, the tool requests [page text](#web-pages) when web page access is enabled. With the `"image"` view, it passes a [direct image URL](#remote-images) to the configured model service for retrieval.

## Reading a window

`view.offset` defaults to zero. `view.limit` requests a positive number of bytes or entries. For example, `{"view":{"limit":10}}` lists up to ten entries from the startup directory.

| Source | Unit | Default and maximum window |
| --- | --- | --- |
| Text file or web page snapshot | UTF-8 bytes | 16 KiB |
| Directory listing | Entries | 100 entries |

To continue, pass `result.uri` and use `result.next_offset` as the next `view.offset`. A null `next_offset` means the reader reached the end. Text windows preserve whole characters, even when the first character exceeds the requested limit.

Starting exactly at the end of the text or listing returns an empty window. An offset beyond the end or inside a UTF-8 character returns `invalid_range`.

## Local files and directories

To open a directory entry or a command log, pass its returned `uri`. The reader follows symbolic links with the kernel's OS permissions. Each read sees the current filesystem, so edits can shift the offsets in a file or directory listing. See [host command results](host.md#output-and-results).

To construct a file URI, use an absolute path with an empty host or `localhost`. Percent-encode spaces and literal `%`, `?`, or `#` in filenames. For example, `file:///srv/notes%20today.md` opens `/srv/notes today.md`. A link to `draft.md` in that file resolves to `file:///srv/draft.md`.

- **Directories.** `entries` lists one level, sorted by filename bytes. If a name contains invalid UTF-8, `name` is null and the entry's `uri` remains usable. Each entry reports its own `kind` (`file`, `directory`, `symlink`, or `other`), its modification time (`modified_ms`, in milliseconds since the Unix epoch), and its `byte_length` if it is a regular file. Unavailable metadata is null.
- **Text files.** `content` holds the selected text. `byte_length` is null until the reader knows the file's length.
- **Images and files.** Start at offset zero for a known image or binary file. A recognized image or file arrives whole if it fits the source limit. The `"image"` view requests a recognized image explicitly, as in `{"uri":"file:///srv/chart.png","view":"image"}`. See [content classification](content.md#automatic-classification) and [source limits](content.md#content-and-results).

## Web pages

Pass a page's HTTP(S) URL to request a fresh copy as Markdown. The tool description names the page service and discloses any potential charge. See [web page access](running.md#web-page-access).

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

Here `source_uri` is the requested URL and `byte_length` is the full length of the Markdown. The title is a preview when `title_truncated` is true. Either focus can use the snapshot's `uri` to continue reading the same version without another fetch.

```json
{"uri":"ivenna:fetch/7198a8e09ae74b1c","view":{"offset":6}}
```

Snapshots expire when the kernel restarts or needs room for newer pages. Reading `source_uri` again may return a different version.

To follow a link in the Markdown, pass its destination URL. Resolve a relative link against the page's base URL when known.

## Remote images

To view a screenshot from a letter or an illustration linked in Markdown, pass the direct HTTP(S) URL with `"view":"image"`. This view also works when web page access is disabled.

```json
{"uri":"https://example.org/figures/weekly-rainfall","view":"image"}
```

The result has `kind: "image_url"` and identifies the supplied URL in `uri`. The model service handles image retrieval during inference. That request can fail if the service cannot reach the address or the model lacks image support. Working history retains the URL, so the image may change or become unavailable between turns. See [image URL references](content.md#image-url-references).

## Failure results

A failed read returns an `error` with a `code` and a `message`.

| Code | Meaning or next action |
| --- | --- |
| `invalid_arguments` | Check the argument shape. Put window fields inside a `view` object, or use the string `"image"` for the whole image. |
| `invalid_uri`, `unsupported_scheme` | Correct the reference or use a URI returned by an earlier read. |
| `unsupported_view` | The local source or Markdown snapshot cannot supply an image. Omit `view` for an ordinary read. |
| `invalid_range` | Resume at a returned `next_offset` or omit `view` to start at zero. For a web page, use `error.uri` to read the snapshot already retrieved. |
| `not_found` | The local entry or snapshot is missing. For an expired snapshot, open the original `source_uri` to fetch a fresh copy. |
| `not_readable` | The source could not be read. The message gives the reason known to the reader. |
| `rate_limited`, `read_timeout` | The service is limiting requests or the read timed out. A later read may succeed. |
| `page_too_large` | The page is too large to retrieve or retain. A smaller reading window still requires the whole page. |
| `web_unavailable` | Check the message for details about page access, the local request, or the page service. |
