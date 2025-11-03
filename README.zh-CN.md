![GitHub Release](https://img.shields.io/github/v/release/hank-cp/pg_vector_embedding)
[![Tests](https://github.com/hank-cp/pg_vector_embedding/actions/workflows/test.yml/badge.svg)](https://github.com/hank-cp/pg_vector_embedding/actions/workflows/test.yml)
![GitHub](https://img.shields.io/github/license/hank-cp/pg_vector_embedding.svg)
![GitHub last commit](https://img.shields.io/github/last-commit/hank-cp/pg_vector_embedding.svg)

# pg_vector_embedding

PostgreSQL 扩展，用于使用外部嵌入服务自动生成向量嵌入。

[English Documentation](README.md)

## 特性

- 通过数据库设置进行全局嵌入服务配置
- 为表注册自动向量嵌入功能（INSERT/UPDATE时触发）
- 使用后台工作进程异步计算嵌入
- 提供同步嵌入函数用于查询
- 基于 `http` 和 `pg_background` 扩展

## 前置要求

- PostgreSQL 9.5+ 及 `vector` 扩展
- [http](https://github.com/pramsey/pgsql-http) 扩展
- [pg_background](https://github.com/vibhorkum/pg_background) 扩展
- [pgTAP](https://pgtap.org/documentation.html) 扩展（用于测试）

## 安装

```bash
git clone https://github.com/hank-cp/pg_vector_embedding.git
cd pg_vector_embedding
make
sudo make install
```

## 使用方法

### 1. 创建扩展

```sql
CREATE EXTENSION pg_vector_embedding CASCADE;
```

### 2. 配置嵌入服务

```sql
-- 设置数据库级别配置
ALTER SYSTEM SET pg_vector_embedding.embedding_url = 'https://api.siliconflow.cn/v1/embeddings';
ALTER SYSTEM SET pg_vector_embedding.embedding_api_key = 'your-api-key';
ALTER SYSTEM SET pg_vector_embedding.embedding_model = 'BAAI/bge-m3';
-- 重启 Postgres 以应用设置
```

### 3. 创建带向量列的表

```sql
CREATE TABLE documents (
    id SERIAL PRIMARY KEY,
    title TEXT,
    content TEXT,
    embedding VECTOR(1024)
);
```

### 4. 注册表以启用自动嵌入

```sql
SELECT ve_enable(
    'public',           -- 模式名
    'documents',        -- 表名
    ARRAY['title', 'content'],  -- 要嵌入的列
    'embedding'         -- 向量列名
);
```

### 5. 插入数据（自动计算嵌入）

```sql
INSERT INTO documents (title, content) 
VALUES ('PostgreSQL Extensions', 'Learn how to build powerful PostgreSQL extensions');
```

嵌入将通过 `pg_background` 异步计算并存储在 `embedding` 列中。

### 6. 使用向量相似度查询

```sql
-- 为搜索查询计算嵌入
SELECT * FROM documents
ORDER BY embedding <-> ve_compute_embedding('{"title": "PostgreSQL", "content": "extensions"}'::text)
LIMIT 10;
```

### 7. 注销表

```sql
SELECT ve_disable('public', 'documents');
```

## 测试

### 配置测试环境

创建 `test/.env` 文件：

```env
EMBEDDING_URL=https://api.siliconflow.cn/v1/embeddings
EMBEDDING_API_KEY=your-api-key
EMBEDDING_MODEL=BAAI/bge-m3
```

### 运行所有测试

```bash
cd test
./runner.sh
```

### 测试选项

```bash
# 使用自定义数据库设置运行
./runner.sh --host localhost --port 5432 --user postgres

# 运行后保留测试数据库（用于调试）
./runner.sh --no-cleanup
```

## 架构

1. **基于触发器的检测**：当注册的表被修改时，`ve_trigger()` 捕获变更
2. **列提取**：触发器使用 `ve_compact_row_data()` 将配置的信息列提取为 JSON。列注释也将包含在 JSON 中以提高嵌入质量。
3. **后台处理**：将启动后台工作进程来处理嵌入请求并更新向量列。
4. **存储**：返回的向量保存到配置的向量列中。它可以在向量相似性搜索中使用，例如 RAG。

## 配置参考

所有配置使用 `ALTER DATABASE` 存储在数据库级别：

| 键 | 描述 | 示例 |
|-----|------|------|
| `pg_vector_embedding.embedding_url` | 嵌入 API 端点 | `https://api.siliconflow.cn/v1/embeddings` |
| `pg_vector_embedding.embedding_api_key` | API 认证密钥 | `sk-...` |
| `pg_vector_embedding.embedding_model` | 使用的模型（可选） | `BAAI/bge-m3` |

表级配置通过触发器参数传递，不需要数据库设置。

## 示例：完整工作流

```sql
-- 1. 设置
CREATE EXTENSION pg_vector_embedding CASCADE;

ALTER DATABASE mydb SET pg_vector_embedding.embedding_url = 'https://api.example.com/v1/embeddings';
ALTER DATABASE mydb SET pg_vector_embedding.embedding_api_key = 'sk-xxxxx';

\c  -- 重新连接以应用设置

-- 2. 创建并注册表
CREATE TABLE articles (
    id SERIAL PRIMARY KEY,
    title TEXT,
    content TEXT,
    embedding VECTOR(1024)
);

SELECT ve_enable('public', 'articles', ARRAY['title', 'content'], 'embedding');

-- 3. 插入数据（嵌入在后台自动计算）
INSERT INTO articles (title, content) VALUES 
    ('PostgreSQL Extensions', 'Learn how to build powerful PostgreSQL extensions'),
    ('Vector Search', 'Implementing semantic search with pgvector');

-- 4. 等待后台处理（或检查嵌入是否就绪）
SELECT COUNT(*) FROM articles WHERE embedding IS NOT NULL;

-- 5. 执行相似度搜索
WITH search_query AS (
    SELECT ve_compute_embedding('{"title": "PostgreSQL", "content": "tutorial"}'::text) AS query_embedding
)
SELECT id, title, embedding <-> query_embedding AS distance
FROM articles, search_query
WHERE embedding IS NOT NULL
ORDER BY distance
LIMIT 5;
```

## 故障排查

### 嵌入未被计算

1. 检查 `pg_background` 扩展是否已安装并正常工作
2. 验证数据库配置已设置且会话已重新连接
3. 检查 PostgreSQL 日志中的后台工作进程错误
4. 确保嵌入 API 可访问且凭据有效

### 触发器未触发

1. 验证表已注册：检查表上是否存在 `pg_vector_embedding_trigger` 触发器
2. 确保表有主键（用于跟踪记录时必需）
3. 检查触发器函数是否存在：`\df ve_trigger`

## [许可证](LICENSE)
