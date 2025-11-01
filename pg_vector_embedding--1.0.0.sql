CREATE OR REPLACE FUNCTION ve_config(p_key TEXT)
RETURNS TEXT AS $$
DECLARE
    v_value TEXT;
BEGIN
    BEGIN
        v_value := current_setting('pg_vector_embedding.' || p_key);
    EXCEPTION
        WHEN OTHERS THEN
            RETURN NULL;
    END;
    RETURN v_value;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION ve_enable(
    p_schema_name TEXT,
    p_table_name TEXT,
    p_info_columns TEXT[],
    p_vector_column TEXT
)
RETURNS VOID AS $$
DECLARE
    v_trigger_name TEXT;
    v_full_table_name TEXT;
    v_info_columns_str TEXT;
BEGIN
    v_full_table_name := quote_ident(p_schema_name) || '.' || quote_ident(p_table_name);

    v_info_columns_str := array_to_string(p_info_columns, ',');

    v_trigger_name := 'pg_vector_embedding_trigger';

    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', v_trigger_name, v_full_table_name);

    EXECUTE format(
        'CREATE TRIGGER %I AFTER INSERT OR UPDATE ON %s FOR EACH ROW EXECUTE FUNCTION ve_trigger(%L, %L)',
        v_trigger_name,
        v_full_table_name,
        v_info_columns_str,
        p_vector_column
    );

    RAISE NOTICE 'Vector embedding enabled for table %.%', p_schema_name, p_table_name;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION ve_disable(
    p_schema_name TEXT,
    p_table_name TEXT
)
RETURNS VOID AS $$
DECLARE
    v_trigger_name TEXT;
    v_full_table_name TEXT;
BEGIN
    v_full_table_name := quote_ident(p_schema_name) || '.' || quote_ident(p_table_name);
    v_trigger_name := 'pg_vector_embedding_trigger';

    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', v_trigger_name, v_full_table_name);

    RAISE NOTICE 'Vector embedding disabled for table %.%', p_schema_name, p_table_name;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION ve_compact_row_data(p_record ANYELEMENT, p_info_columns TEXT[])
RETURNS JSONB AS $$
DECLARE
    v_info_json JSONB;
    v_col TEXT;
    v_value TEXT;
    v_value_jsonb JSONB;
    v_comment TEXT;
    v_table_oid OID;
    v_col_num INTEGER;
    v_col_type OID;
    v_type_name TEXT;
    v_type_category CHAR;
BEGIN
    v_info_json := '{}'::jsonb;
    
    v_table_oid := pg_typeof(p_record)::text::regclass::oid;

    FOREACH v_col IN ARRAY p_info_columns
    LOOP
        SELECT a.attnum, a.atttypid INTO v_col_num, v_col_type
        FROM pg_attribute a
        WHERE a.attrelid = v_table_oid
        AND a.attname = v_col;
        
        SELECT t.typname, t.typcategory INTO v_type_name, v_type_category
        FROM pg_type t
        WHERE t.oid = v_col_type;
        
        SELECT pg_catalog.col_description(v_table_oid, v_col_num) INTO v_comment;
        
        IF v_type_name IN ('json', 'jsonb') THEN
            EXECUTE format('SELECT ($1).%I::JSONB', v_col) INTO v_value_jsonb USING p_record;
            
            IF v_comment IS NOT NULL AND v_comment != '' THEN
                v_info_json := v_info_json || jsonb_build_object(v_col, jsonb_build_object('_comment', v_comment, '_value', v_value_jsonb));
            ELSE
                v_info_json := v_info_json || jsonb_build_object(v_col, v_value_jsonb);
            END IF;
        ELSIF v_type_category = 'A' THEN
            EXECUTE format('SELECT to_jsonb(($1).%I)', v_col) INTO v_value_jsonb USING p_record;
            
            IF v_comment IS NOT NULL AND v_comment != '' THEN
                v_info_json := v_info_json || jsonb_build_object(v_col, jsonb_build_object('_comment', v_comment, '_value', v_value_jsonb));
            ELSE
                v_info_json := v_info_json || jsonb_build_object(v_col, v_value_jsonb);
            END IF;
        ELSE
            EXECUTE format('SELECT ($1).%I::TEXT', v_col) INTO v_value USING p_record;
            
            IF v_comment IS NOT NULL AND v_comment != '' THEN
                v_info_json := v_info_json || jsonb_build_object(v_col, v_comment || ': ' || v_value);
            ELSE
                v_info_json := v_info_json || jsonb_build_object(v_col, v_value);
            END IF;
        END IF;
    END LOOP;

    RETURN v_info_json;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION ve_compute_embedding(p_text TEXT)
RETURNS vector AS $$
DECLARE
    v_url TEXT;
    v_api_key TEXT;
    v_model TEXT;
    v_request JSONB;
    v_response JSONB;
    v_embedding_array JSONB;
    v_embedding_text TEXT;
    v_result vector;
BEGIN
    v_url := ve_config('embedding_url');
    v_api_key := ve_config('embedding_api_key');
    v_model := COALESCE(ve_config('embedding_model'), 'BAAI/bge-m3');

    IF v_url IS NULL THEN
        RAISE EXCEPTION 'Embedding URL not configured. Use: ALTER DATABASE % SET pg_vector_embedding.embedding_url = ''your_url''', current_database();
    END IF;

    v_request := jsonb_build_object(
        'model', v_model,
        'input', p_text
    );

    SELECT content::jsonb INTO v_response
    FROM http((
        'POST',
        v_url,
        ARRAY[
            http_header('Content-Type', 'application/json'),
            http_header('Authorization', 'Bearer ' || COALESCE(v_api_key, ''))
        ],
        'application/json',
        v_request::text
    )::http_request);

    v_embedding_array := v_response->'data'->0->'embedding';

    IF v_embedding_array IS NULL THEN
        RAISE EXCEPTION 'Failed to extract embedding from response: %', v_response;
    END IF;

    v_embedding_text := '[' || (
        SELECT string_agg(value::text, ',')
        FROM jsonb_array_elements(v_embedding_array)
    ) || ']';

    v_result := v_embedding_text::vector;

    RETURN v_result;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION ve_trigger()
RETURNS TRIGGER AS $$
DECLARE
    v_info_columns TEXT[];
    v_vector_column TEXT;
    v_info_json JSONB;
    v_col TEXT;
    v_value TEXT;
    v_task_id INTEGER;
    v_schema TEXT;
    v_table TEXT;
    v_pk_columns TEXT[];
    v_pk_values TEXT[];
    v_pk_col TEXT;
BEGIN
    v_schema := TG_TABLE_SCHEMA;
    v_table := TG_TABLE_NAME;

    IF TG_NARGS < 2 THEN
        RAISE EXCEPTION 'trigger_function requires 2 arguments: info_columns, vector_column';
    END IF;

    v_info_columns := string_to_array(TG_ARGV[0], ',');
    v_vector_column := TG_ARGV[1];

    v_info_json := ve_compact_row_data(NEW, v_info_columns);

    SELECT array_agg(a.attname ORDER BY array_position(i.indkey::int[], a.attnum))
    INTO v_pk_columns
    FROM pg_index i
    JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
    WHERE i.indrelid = (quote_ident(v_schema) || '.' || quote_ident(v_table))::regclass
      AND i.indisprimary;

    IF v_pk_columns IS NULL OR array_length(v_pk_columns, 1) = 0 THEN
        RAISE EXCEPTION 'Table %.% must have a primary key for vector embedding', v_schema, v_table;
    END IF;

    v_pk_values := ARRAY[]::TEXT[];
    FOREACH v_pk_col IN ARRAY v_pk_columns
    LOOP
        EXECUTE format('SELECT ($1).%I::TEXT', v_pk_col) INTO v_value USING NEW;
        v_pk_values := v_pk_values || v_value;
    END LOOP;

    PERFORM pg_background_launch(
        format(
            'SELECT ve_process_embedding(%L::jsonb)',
            jsonb_build_object(
                'schema', v_schema,
                'table', v_table,
                'vector_column', v_vector_column,
                'pk_columns', v_pk_columns,
                'pk_values', v_pk_values,
                'info', v_info_json
            )::text
        )
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION ve_process_embedding(p_params JSONB)
RETURNS VOID AS $$
DECLARE
    v_schema TEXT;
    v_table TEXT;
    v_vector_col TEXT;
    v_pk_columns TEXT[];
    v_pk_values TEXT[];
    v_info JSONB;
    v_embedding vector;
    v_where_clause TEXT;
    v_update_sql TEXT;
    i INTEGER;
BEGIN
    v_schema := p_params->>'schema';
    v_table := p_params->>'table';
    v_vector_col := p_params->>'vector_column';
    v_pk_columns := ARRAY(SELECT jsonb_array_elements_text(p_params->'pk_columns'));
    v_pk_values := ARRAY(SELECT jsonb_array_elements_text(p_params->'pk_values'));
    v_info := p_params->'info';

    v_embedding := ve_compute_embedding(v_info::text);

    v_where_clause := '';
    FOR i IN 1..array_length(v_pk_columns, 1)
    LOOP
        IF i > 1 THEN
            v_where_clause := v_where_clause || ' AND ';
        END IF;
        v_where_clause := v_where_clause || format('%I = %L', v_pk_columns[i], v_pk_values[i]);
    END LOOP;

    v_update_sql := format(
        'UPDATE %I.%I SET %I = %L WHERE %s',
        v_schema,
        v_table,
        v_vector_col,
        v_embedding::text,
        v_where_clause
    );

    EXECUTE v_update_sql;
END;
$$ LANGUAGE plpgsql;
