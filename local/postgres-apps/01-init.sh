#!/bin/bash
set -e

# o enunciado pede 2 postgres locais mas 3 servicos usam postgres, entao esse container
# hospeda flags_db e targeting_db. na AWS cada um ganha seu RDS separado.
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres <<-EOSQL
	CREATE DATABASE flags_db;
	CREATE DATABASE targeting_db;
EOSQL

psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d flags_db -f /seed/flags.sql
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d targeting_db -f /seed/targeting.sql
