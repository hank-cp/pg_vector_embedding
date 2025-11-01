BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;
CREATE EXTENSION IF NOT EXISTS http;
CREATE EXTENSION IF NOT EXISTS pg_background;
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_vector_embedding;

SELECT plan(20);

SELECT has_function('ve_config', ARRAY['text'], 've_config function should exist');
SELECT has_function('ve_enable', ARRAY['text', 'text', 'text[]', 'text'], 've_enable function should exist');
SELECT has_function('ve_disable', ARRAY['text', 'text'], 've_disable function should exist');
SELECT has_function('ve_compact_row_data', ARRAY['anyelement', 'text[]'], 've_compact_row_data function should exist');
SELECT has_function('ve_compute_embedding', ARRAY['text'], 've_compute_embedding function should exist');
SELECT has_function('ve_trigger', 've_trigger should exist');
SELECT has_function('ve_process_embedding', ARRAY['jsonb'], 've_process_embedding function should exist');

SELECT ok(
    ve_config('embedding_url') IS NOT NULL AND ve_config('embedding_url') != '',
    'Config should be set and retrieved correctly via current_setting'
);

SELECT is(
         ve_config('embedding_url'),
         'https://api.siliconflow.cn/v1/embeddings',
         ve_config('embedding_url')
       );

SELECT is(
         ve_config('embedding_api_key'),
         'sk-gjvlkbiknbooainxppvsdheqyxxagzqfgaawnsbjlailjmst',
         ve_config('embedding_api_key')
       );

SELECT is(
         ve_config('embedding_model'),
         'BAAI/bge-m3',
         ve_config('embedding_model')
       );

CREATE TABLE test_table (
    id SERIAL PRIMARY KEY,
    title TEXT,
    content TEXT,
    json_data JSONB,
    embedding VECTOR(1024)
);

SELECT lives_ok(
    $$SELECT ve_enable('public', 'test_table', ARRAY['title', 'content', 'json_data'], 'embedding')$$,
    'Should register table successfully'
);

SELECT has_trigger('public', 'test_table', 'pg_vector_embedding_trigger', 'Trigger should be created on registered table');

CREATE TYPE test_record AS (
    id INTEGER,
    title TEXT,
    content TEXT,
    json_data JSONB,
    embedding VECTOR(1024)
);

SELECT is(
    ve_compact_row_data(ROW(1, 'Test Title', 'Test Content', '{"key": "value"}', NULL)::test_record, ARRAY['title', 'content', 'json_data']),
    '{"title": "Test Title", "content": "Test Content", "json_data": {"key": "value"}}'::jsonb,
    'compact_row_data should correctly extract specified columns to JSON'
);

-- Test array field handling
CREATE TABLE test_with_array (
    id SERIAL PRIMARY KEY,
    tags TEXT[],
    numbers INTEGER[]
);

INSERT INTO test_with_array (tags, numbers) VALUES (ARRAY['tag1', 'tag2'], ARRAY[1, 2, 3]);

SELECT is(
    (SELECT ve_compact_row_data(test_with_array, ARRAY['tags', 'numbers'])
     FROM test_with_array WHERE id = 1),
    '{"tags": ["tag1", "tag2"], "numbers": [1, 2, 3]}'::jsonb,
    'compact_row_data should handle array fields as JSON arrays'
);

-- Test column comments feature
CREATE TABLE test_with_comments (
    id SERIAL PRIMARY KEY,
    product_name TEXT,
    description TEXT,
    embedding VECTOR(1024)
);

COMMENT ON COLUMN test_with_comments.product_name IS 'Product name';
COMMENT ON COLUMN test_with_comments.description IS 'Product description';

INSERT INTO test_with_comments (product_name, description) VALUES ('Widget', 'A useful gadget');

SELECT is(
    (SELECT ve_compact_row_data(test_with_comments, ARRAY['product_name', 'description'])
     FROM test_with_comments WHERE id = 1),
    '{"product_name": "Product name: Widget", "description": "Product description: A useful gadget"}'::jsonb,
    'compact_row_data should include column comments in output'
);

-- Test full workflow: manually call ve_process_embedding to simulate trigger behavior
CREATE TABLE articles (
    id SERIAL PRIMARY KEY,
    title TEXT,
    content TEXT,
    embedding VECTOR(1024)
);

INSERT INTO articles (title, content) VALUES
    ('PostgreSQL Extensions', 'Learn how to build powerful PostgreSQL extensions'),
    ('Vector Search Tutorial', 'Implementing semantic search with pgvector extension'),
    ('Database Triggers Guide', 'Understanding PostgreSQL trigger functions');

-- Manually process embeddings (simulating what trigger would do in background)
DO $$
DECLARE
    v_params JSONB;
    v_id INTEGER;
BEGIN
    FOR v_id IN 1..3 LOOP
        SELECT jsonb_build_object(
            'schema', 'public',
            'table', 'articles',
            'vector_column', 'embedding',
            'pk_columns', ARRAY['id'],
            'pk_values', ARRAY[v_id::text],
            'info', jsonb_build_object('title', title, 'content', content)
        ) INTO v_params
        FROM articles WHERE id = v_id;

        PERFORM ve_process_embedding(v_params);
    END LOOP;
END $$;

-- Verify embedding was computed and stored
SELECT ok(
    (SELECT COUNT(*) FROM articles WHERE embedding IS NOT NULL) = 3,
    'Should have computed and stored embeddings for all articles'
);

-- Test vector search: compute embedding for query and find similar articles
DO $$
DECLARE
    v_search_embedding VECTOR(1024);
    v_found_id INTEGER;
    v_found_title TEXT;
BEGIN
    -- Compute embedding for search query
    v_search_embedding := ve_compute_embedding('{"title": "PostgreSQL Extensions", "content": "Learn how to build powerful PostgreSQL extensions"}'::text);

    -- Find most similar article using cosine distance
    SELECT id, title INTO v_found_id, v_found_title
    FROM articles
    WHERE embedding IS NOT NULL
    ORDER BY embedding <-> v_search_embedding
    LIMIT 1;

    -- Store results in a temp table for verification
    CREATE TEMP TABLE IF NOT EXISTS search_results (
        found_id INTEGER,
        found_title TEXT
    );

    INSERT INTO search_results VALUES (v_found_id, v_found_title);
END $$;

-- Verify we found the correct article (should be the first one)
SELECT ok(
    (SELECT found_id FROM search_results LIMIT 1) = 1
    AND (SELECT found_title FROM search_results LIMIT 1) = 'PostgreSQL Extensions',
    'Vector search should find the most similar article'
);

SELECT lives_ok(
    $$SELECT ve_disable('public', 'test_table')$$,
    'Should unregister table successfully'
);

SELECT finish();

ROLLBACK;
