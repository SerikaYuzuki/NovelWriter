-- Staged upload bytes have no read/publication authority before full digest validation.
ALTER TABLE sync_v2.upload_capabilities ADD COLUMN partial_bytes BYTEA NOT NULL DEFAULT '\x'::bytea
  CHECK (octet_length(partial_bytes) <= byte_count);
