#!/bin/bash

set -e

HOST="localhost"
PORT="5432"
USER="postgres"
PASSWORD=""
CLEANUP="true"
TEST_NAME="pg_vector_embedding"

while [[ $# -gt 0 ]]; do
    case $1 in
        --host)
            HOST="$2"
            shift 2
            ;;
        --port)
            PORT="$2"
            shift 2
            ;;
        --user)
            USER="$2"
            shift 2
            ;;
        --password)
            PASSWORD="$2"
            shift 2
            ;;
        --no-cleanup)
            CLEANUP="false"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--host HOST] [--port PORT] [--user USER] [--password PASSWORD] [--no-cleanup]"
            exit 1
            ;;
    esac
done

PGPASSWORD_VAR=""
if [ -n "$PASSWORD" ]; then
    export PGPASSWORD="$PASSWORD"
    PGPASSWORD_VAR="PGPASSWORD=$PASSWORD"
fi

PSQL_CMD="psql -h $HOST -p $PORT -U $USER"

TEST_DB="${TEST_NAME}_test_$(date +%s)_$RANDOM"

echo "=== Building and installing extension ==="
if ! command -v pg_config &> /dev/null; then
    if [ -f "/Applications/Postgres.app/Contents/Versions/latest/bin/pg_config" ]; then
        export PATH="/Applications/Postgres.app/Contents/Versions/latest/bin:$PATH"
    fi
fi
make install

echo ""
echo "=== Creating test database: $TEST_DB ==="
$PSQL_CMD -d postgres -c "CREATE DATABASE $TEST_DB;"

# Load .env and set database configurations
ENV_FILE="$(dirname "$0")/.env"
if [ -f "$ENV_FILE" ]; then
    echo ""
    echo "=== Loading configuration from .env ==="
    while IFS='=' read -r key value || [ -n "$key" ]; do
        # Skip empty lines and comments
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue

        # Trim whitespace
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)

        if [ -n "$key" ] && [ -n "$value" ]; then
            # Convert EMBEDDING_URL to pg_vector_embedding.embedding_url
            db_key=$(echo "$key" | tr '[:upper:]' '[:lower:]' | sed 's/^/pg_vector_embedding./')
            echo "Setting $db_key"
            $PSQL_CMD -d "$TEST_DB" -c "ALTER SYSTEM SET $db_key = '$value';" || true
            $PSQL_CMD -d "$TEST_DB" -c "SET $db_key = '$value';" || true
        fi
    done < "$ENV_FILE"
else
    echo ""
    echo "=== Warning: .env not found, skipping configuration ==="
fi

cleanup() {
    if [ "$CLEANUP" = "true" ]; then
        echo ""
        echo "=== Cleaning up test database: $TEST_DB ==="
        $PSQL_CMD -d postgres -c "DROP DATABASE IF EXISTS $TEST_DB;" || true
    else
        echo ""
        echo "=== Keeping test database: $TEST_DB ==="
    fi
}

trap cleanup EXIT

echo ""
echo "=== Running tests ==="

FAILED=0
for TEST_FILE in "$(dirname "$0")"/pgtap_*.sql; do
    if [ -f "$TEST_FILE" ]; then
        echo "Running $(basename "$TEST_FILE")..."
        TEST_OUTPUT=$($PSQL_CMD -d $TEST_DB -f "$TEST_FILE" 2>&1)
        TEST_EXIT_CODE=$?

        echo "$TEST_OUTPUT"

        # Check for test failures
        if echo "$TEST_OUTPUT" | grep -q "Looks like you failed"; then
            FAILED=1
        fi

        # Check for SQL errors
        if echo "$TEST_OUTPUT" | grep -qE "ERROR:|FATAL:|PANIC:"; then
            echo "SQL error detected in test output"
            FAILED=1
        fi

        # Check for non-zero exit code
        if [ $TEST_EXIT_CODE -ne 0 ]; then
            echo "Test execution failed with exit code $TEST_EXIT_CODE"
            FAILED=1
        fi
        echo ""
    fi
done

if [ $FAILED -eq 1 ]; then
    echo "=== Tests FAILED ==="
    exit 1
fi

echo ""
echo "=== Test completed successfully ==="
