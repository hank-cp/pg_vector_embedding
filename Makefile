EXTENSION = pg_vector_embedding
DATA = pg_vector_embedding--1.0.0.sql
REGRESS = pg_vector_embedding_test

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
