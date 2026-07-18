CREATE TABLE public.items (
    id text PRIMARY KEY,
    name text NOT NULL,
    source_url text,
    image_url text,
    active boolean DEFAULT true NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    source_updated_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT items_id_format_check CHECK (id ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
    CONSTRAINT items_name_check CHECK (btrim(name) <> ''),
    CONSTRAINT items_source_url_check CHECK (source_url IS NULL OR source_url ~ '^https://[^[:space:]]+$'),
    CONSTRAINT items_image_url_check CHECK (image_url IS NULL OR image_url ~ '^https://[^[:space:]]+$'),
    CONSTRAINT items_metadata_object_check CHECK (jsonb_typeof(metadata) = 'object')
);

ALTER TABLE public.items ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.items FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.items TO anon, authenticated;
GRANT ALL ON TABLE public.items TO service_role;

CREATE POLICY items_public_read
ON public.items
FOR SELECT
TO anon, authenticated
USING (true);
