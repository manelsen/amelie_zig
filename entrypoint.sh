#!/bin/sh
set -e

# Bridge em background com auto-restart.
# Se o Zig cair, o Docker reinicia o container inteiro (restart: unless-stopped).
# Se só o bridge cair, o loop o sobe de volta sem derrubar a sessão WA.
(
  while true; do
    echo "[zigmelie] iniciando bridge..."
    /app/bridge || true
    echo "[zigmelie] bridge encerrou, reiniciando em 2s..."
    sleep 2
  done
) &

# Aguarda o bridge subir antes de iniciar o Zig
sleep 1

echo "[zigmelie] iniciando amelie-zig..."
exec /app/amelie-zig
