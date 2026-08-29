-- Chave de API fixa so pro ambiente local.
-- O auth-service guarda o sha256 da chave, entao da pra pre-cadastrar o hash e pular
-- o bootstrap (subir auth -> POST /admin/keys -> copiar a chave -> reiniciar o resto).
-- Chave em texto plano: tm_key_local_dev_123
-- Na AWS isso NAO existe: la a chave e gerada de verdade e vai pro Secret.
INSERT INTO api_keys (name, key_hash)
VALUES ('dev-local', 'a65bbb05a442b87ec792e357050d28720319cb246be1a8445feeb092feb860c0')
ON CONFLICT (key_hash) DO NOTHING;
