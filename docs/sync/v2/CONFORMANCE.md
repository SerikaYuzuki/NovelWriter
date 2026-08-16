# v2 conformance and red-team checks

The following checks are the minimum document-only gate. The independent Swift
and Rust runners must additionally exercise every scenario fixture without
sharing canonicalization or state-machine code.

```sh
find docs/sync/v2 -name '*.json' -print0 | xargs -0 -n1 jq -e . >/dev/null
ruby -e 'require "yaml"; YAML.safe_load(File.read("docs/sync/v2/openapi.yaml"), aliases: true)'
python3 - <<'PY'
import hashlib, json
from pathlib import Path
from jsonschema import Draft202012Validator
root = Path("docs/sync/v2")
for schema, fixture in [("snapshot.schema.json", "fixtures/canonical/snapshot.json"),
                        ("command.schema.json", "fixtures/canonical/publish-command.json")]:
    model = json.loads((root / fixture).read_text())
    Draft202012Validator(json.loads((root / schema).read_text())).validate(model)
for fixture, digest_file in [("snapshot.json", "snapshot.sha256"),
                             ("publish-command.json", "publish-command.sha256")]:
    canonical = (root / "fixtures/canonical" / fixture).read_bytes()
    assert not canonical.endswith(b"\\n"), fixture
    json.loads(canonical)
    expected = (root / "fixtures/canonical" / digest_file).read_text().strip()
    assert hashlib.sha256(canonical).hexdigest() == expected
for row in json.loads((root / "fixtures/canonical/object-hashes.json").read_bytes())["objects"]:
    data = (root / "fixtures/canonical/objects" / row["file"]).read_bytes()
    assert not data.endswith(b"\\n"), row["file"]
    assert len(data) == row["byteCount"]
    assert hashlib.sha256(data).hexdigest() == row["objectId"]
print("v2 JSON/schema/hash checks passed")
PY
git diff --check
```

The production conformance runner must add byte-for-byte JCS (including a
no-final-newline assertion), duplicate-member rejection, I-JSON safe-number
checks, UTF-8/surrogate rejection, entry sorting/uniqueness, self-parent and
cycle rejection, WorkID parent lineage, object/manifest digest read-back,
receipt uniqueness, account/fence non-disclosure, upload capability binding,
CAS current+generation rejection, one-active-conflict revision append, and
process-kill migration markers. These are represented by the scenario fixtures
and are not optional semantic extensions of JSON Schema.
