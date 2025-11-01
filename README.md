# pg_vector_embedding

PostgreSQL extension for automatic vector embedding using external embedding services.

## Features

- Global embedding service configuration via database settings
- Register tables for automatic vector embedding on INSERT/UPDATE
- Asynchronous embedding computation using background workers
- Synchronous embedding function for queries
- Based on `http` and `pg_background` extensions

## Prerequisites

- PostgreSQL 9.5+ with `vector` extension
- `http` extension
- `pg_background` extension
- `pgTAP` extension (for testing)

## Installation

```bash
make
sudo make install
```

## Usage

### 1. Create Extension

```sql
CREATE EXTENSION pg_vector_embedding CASCADE;
```

### 2. Configure Embedding Service

```sql
-- Set database-level configuration
ALTER SYSTEM SET pg_vector_embedding.embedding_url = 'https://api.siliconflow.cn/v1/embeddings';
ALTER SYSTEM SET pg_vector_embedding.embedding_api_key = 'your-api-key';
ALTER SYSTEM SET pg_vector_embedding.embedding_model = 'BAAI/bge-m3';
-- Restart Postgres to apply settings
```

### 3. Create Table with Vector Column

```sql
CREATE TABLE documents (
    id SERIAL PRIMARY KEY,
    title TEXT,
    content TEXT,
    embedding VECTOR(1024)
);
```

### 4. Register Table for Auto-Embedding

```sql
SELECT ve_enable(
    'public',           -- schema name
    'documents',        -- table name
    ARRAY['title', 'content'],  -- columns to embed
    'embedding'         -- vector column name
);
```

### 5. Insert Data (Embedding Computed Automatically)

```sql
INSERT INTO documents (title, content) 
VALUES ('PostgreSQL Extensions', 'Learn how to build powerful PostgreSQL extensions');
```

The embedding will be computed asynchronously via `pg_background` and stored in the `embedding` column.

### 6. Query with Vector Similarity

```sql
-- Compute embedding for search query
SELECT * FROM documents
ORDER BY embedding <-> ve_compute_embedding('{"title": "PostgreSQL", "content": "extensions"}'::text)
LIMIT 10;
```

### 7. Unregister Table

```sql
SELECT ve_disable('public', 'documents');
```

## Functions

### Configuration

- `ve_config(key TEXT) RETURNS TEXT` - Get configuration value from database settings

### Table Management

- `ve_enable(schema TEXT, table TEXT, info_columns TEXT[], vector_column TEXT)` - Register table for auto-embedding
- `ve_disable(schema TEXT, table TEXT)` - Unregister table

### Embedding

- `ve_compute_embedding(text TEXT) RETURNS VECTOR` - Compute embedding synchronously
- `ve_compact_row_data(record ANYELEMENT, columns TEXT[]) RETURNS JSONB` - Extract specified columns to JSON
- `ve_process_embedding(params JSONB)` - Process embedding for a specific record (used internally)

### Internal Functions

- `ve_trigger()` - Trigger function that launches background embedding tasks

## Testing

### Run All Tests

```bash
cd test
./runner.sh
```

### Configure Test Environment

Create `test/.env` file:

```env
EMBEDDING_URL=https://api.siliconflow.cn/v1/embeddings
EMBEDDING_API_KEY=your-api-key
EMBEDDING_MODEL=BAAI/bge-m3
```

### Test Options

```bash
# Run with custom database settings
./runner.sh --host localhost --port 5432 --user postgres

# Keep test database after running (for debugging)
./runner.sh --no-cleanup
```

## Architecture

1. **Trigger-based Detection**: When a registered table is modified, `ve_trigger()` captures the change
2. **Column Extraction**: The trigger extracts configured info columns as JSON using `ve_compact_row_data()`
3. **Background Processing**: A background worker is launched via `pg_background_launch()` to run `ve_process_embedding()`
4. **API Call**: The background task calls the embedding service via `http` extension using `ve_compute_embedding()`
5. **Storage**: The returned vector is saved to the configured vector column

## Configuration Reference

All configuration is stored at the database level using `ALTER DATABASE`:

| Key | Description | Example |
|-----|-------------|---------|
| `pg_vector_embedding.embedding_url` | Embedding API endpoint | `https://api.siliconflow.cn/v1/embeddings` |
| `pg_vector_embedding.embedding_api_key` | API authentication key | `sk-...` |
| `pg_vector_embedding.embedding_model` | Model to use (optional) | `BAAI/bge-m3` |

Table-level configuration is passed as trigger arguments and does not require database settings.

## Example: Full Workflow

```sql
-- 1. Setup
CREATE EXTENSION pg_vector_embedding CASCADE;

ALTER DATABASE mydb SET pg_vector_embedding.embedding_url = 'https://api.example.com/v1/embeddings';
ALTER DATABASE mydb SET pg_vector_embedding.embedding_api_key = 'sk-xxxxx';

\c  -- Reconnect to apply settings

-- 2. Create and register table
CREATE TABLE articles (
    id SERIAL PRIMARY KEY,
    title TEXT,
    content TEXT,
    embedding VECTOR(1024)
);

SELECT ve_enable('public', 'articles', ARRAY['title', 'content'], 'embedding');

-- 3. Insert data (embeddings computed automatically in background)
INSERT INTO articles (title, content) VALUES 
    ('PostgreSQL Extensions', 'Learn how to build powerful PostgreSQL extensions'),
    ('Vector Search', 'Implementing semantic search with pgvector');

-- 4. Wait for background processing (or check if embeddings are ready)
SELECT COUNT(*) FROM articles WHERE embedding IS NOT NULL;

-- 5. Perform similarity search
WITH search_query AS (
    SELECT ve_compute_embedding('{"title": "PostgreSQL", "content": "tutorial"}'::text) AS query_embedding
)
SELECT id, title, embedding <-> query_embedding AS distance
FROM articles, search_query
WHERE embedding IS NOT NULL
ORDER BY distance
LIMIT 5;
```

## Troubleshooting

### Embeddings not being computed

1. Check if `pg_background` extension is installed and working
2. Verify database configuration is set and session is reconnected
3. Check PostgreSQL logs for background worker errors
4. Ensure the embedding API is accessible and credentials are valid

### Trigger not firing

1. Verify table is registered: Check for trigger `pg_vector_embedding_trigger` on your table
2. Ensure table has a primary key (required for tracking records)
3. Check trigger function exists: `\df ve_trigger`

## License

MIT
