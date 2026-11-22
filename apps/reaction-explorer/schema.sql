-- Run as warehouse against the dedicated deployment database before loading.
CREATE TABLE IF NOT EXISTS public.source_snapshot (
    checksum text PRIMARY KEY CHECK (checksum ~ '^[a-f0-9]{64}$'),
    source_url text NOT NULL,
    revision text NOT NULL,
    sheet text NOT NULL,
    loaded_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS public.experiment (
    checksum text NOT NULL REFERENCES source_snapshot,
    reaction_no integer NOT NULL CHECK (reaction_no > 0),
    worksheet_row integer NOT NULL CHECK (worksheet_row >= 2),
    fields jsonb NOT NULL,
    PRIMARY KEY (checksum, reaction_no),
    UNIQUE (checksum, worksheet_row)
);
