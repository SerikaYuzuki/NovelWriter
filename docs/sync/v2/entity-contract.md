# v2 whole-work entity contract

The manifest synchronizes the complete known NovelDocument plus attachment
metadata/bytes. The dynamic EntityKey grammar is closed by
`snapshot.schema.json`:

```text
work/document | work/title | work/synopsis
work/{chapter,character,plot-card,flag,world-note,attachment}-order
chapter/{ChapterID}/title | chapter/{ChapterID}/episode-order
episode/{EpisodeID}/title | episode/{EpisodeID}/body | episode/{EpisodeID}/memo
character/{CharacterID}
plot-card/{PlotCardID}
flag/{FlagID}
world-note/{WorldNoteID}
attachment/{AttachmentID}/metadata | attachment/{AttachmentID}/bytes
```

The content type/schema mapping is exact: `work/document` uses
`work-document.schema.json`; every `*/title`, `work/synopsis`, episode body,
and episode memo uses `string-value.schema.json`; every `*-order` and
`episode-order` uses `id-order.schema.json`; character, plot-card, flag,
world-note, and attachment metadata use their correspondingly named schema.
Those entries use `application/vnd.fuminiwa.entity+json;version=2`.
`attachment/{AttachmentID}/bytes` alone uses `application/octet-stream` and is
not parsed as JSON. Any other pairing is `schemaViolation`.

Every ID in an order payload has exactly the required dynamic entries, every
dynamic payload ID equals its EntityKey ID, every Episode belongs to exactly
one chapter order, and plot/flag chapter references resolve to that work or are
null. Attachment metadata byteCount equals the raw bytes entry. No unlisted
dynamic entity is silently ignored. Deletion is represented by absence from
the authoritative order plus absence of its dynamic entries in a complete
Snapshot.

`fixtures/canonical/expected-model.json` is the logical expected model for the
canonical manifest/object closure. Swift and Rust independently materialize
that exact sync model. Swift then exports its portable projection through the
`.novelpkg` v3 writer and the package validator reads it back. Package v3 does
not encode Snapshot Sync AttachmentID: its attachment identity is the
validator-approved portable relative name plus exact bytes. Therefore package
round-trip equality deliberately excludes `attachmentId` while requiring an
exact bijection by normalized portable name, byte count, and byte digest. On
import as a new Work, the importer assigns a fresh UUID to each attachment,
uses that UUID consistently in attachment-order/metadata/bytes EntityKeys, and
must not infer or preserve the old sync-local AttachmentID from file name or
content digest. All other known model IDs and values remain logically equal;
attachment bytes remain byte-for-byte equal. This is a projection rule, not a
change to the `.novelpkg` v3 format.
