# Amélie (Zig) 🚀

Amélie é uma agente autônoma de WhatsApp, reescrita do zero em **Zig** (0.15), focada em performance extrema, resiliência offline e baixo consumo de memória (< 5MB RAM, binário de ~1.1MB).

## 🌟 Funcionalidades

- **Despachante Multi-IA Dinâmico**: Suporte nativo ao **Google Gemini** e provedores da rede **OpenRouter**. A IA primária pode ser alternada em tempo de execução (`.config set provider openrouter/gemini`).
- **Resiliência e Filas Offline**: Sistema transacional e de ACKs bidirecionais integrado com a [Whatsmeow Bridge]. Se o WhatsApp ou a API de IA caírem, as mensagens entram em fila com *backoff* exponencial no SQLite e são re-processadas quando o serviço voltar.
- **Multimodalidade Pura**: Processamento nativo de Imagens, Áudio, Vídeo e Documentos (como PDFs) delegando o buffer base64 inteiramente à infraestrutura do LLM (Gemini Vision), sem consumir RAM da máquina local para parse.
- **Leitura de Links (Scraping)**: O bot detecta URLs na mensagem, extrai o texto principal (removendo tags HTML) localmente e injeta como contexto para o LLM.
- **Arquitetura Core Puro**: O domínio principal (`core` e `dominio`) não conhece bibliotecas HTTP ou de Banco de Dados. Toda lógica possui Inversão de Dependência via interfaces (`vtable` e duck-typing do Zig).

## 🛠 Pré-requisitos

Você tem duas opções para rodar a Amélie: **Localmente (Bare-metal)** ou via **Docker**.

### Opção 1: Via Docker (Recomendado para Produção)
Apenas o **Docker** e o **Docker Compose** são necessários. O Zig será baixado estruturalmente dentro do contêiner na fase de build (multi-stage), não poluindo sua máquina.

```bash
docker-compose up -d --build
```

### Opção 2: Localmente (Para Desenvolvimento)
- [Zig](https://ziglang.org/) `0.15.x` ou superior.
- Uma chave de API do Gemini Studio e/ou OpenRouter.

Clone e configure as environment variables:

```bash
git clone https://github.com/manelsen/amelie_zig.git
cd amelie_zig
cp .env.example .env
```

Edite o seu arquivo `.env`:
```ini
GEMINI_API_KEY=sua_chave_aqui
OPENROUTER_API_KEY=sua_chave_opcional_aqui

DB_PATH=./amelie.db
PORT=3000
HOST=0.0.0.0
WHATSAPP_WEBHOOK_URL=http://localhost:8080
```

Compile e execute:
```bash
zig build run -Doptimize=ReleaseSmall
```

## 🧪 Rodando Testes
Toda a suíte de negócios roda em frações de segundo:
```bash
zig build test -Doptimize=Debug
```

## 📂 Arquitetura (Hexagonal)
- **`src/dominio/`**: Regras de negócio, parser de comandos e structs puras.
- **`src/core/`**: Processador de contexto e tomada de fluxo.
- **`src/infra/`**: Adaptadores impuros, `sqlite.zig`, `http.zig`, `gemini.zig`, `openrouter.zig`, `scraper.zig`.
- **`src/shell/`**: Filas assíncronas, gerenciamento de threads de I/O e handlers de barramento.

---
*Construído com Zig ⚡*
