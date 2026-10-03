-- Presentation metadata belongs to a history occurrence, never a snapshot.
ALTER TABLE sync_v2.history ADD COLUMN device_label text NULL
  CONSTRAINT history_device_label_length CHECK (
    device_label IS NULL OR char_length(device_label) BETWEEN 1 AND 40
  );
