CREATE TABLE IF NOT EXISTS notes (
    id uuid PRIMARY KEY,
    body varchar(500) NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
