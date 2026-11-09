FROM golang:alpine AS builder

# Install build dependencies for CGO (SQLite)
RUN apk add --no-cache gcc musl-dev

WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download

COPY . .
# Build static binary with CGO enabled
RUN CGO_ENABLED=1 GOOS=linux go build -ldflags="-w -s" -o whatsmeow-bridge .

FROM alpine:latest
RUN apk add --no-cache ca-certificates tzdata
WORKDIR /app
COPY --from=builder /app/whatsmeow-bridge /usr/local/bin/

# Media and DB dir
RUN mkdir -p /app/db /app/media_tmp

ENV BRIDGE_PORT=8080
ENV AMELIE_URL=http://amelie:3000/webhook
ENV BRIDGE_DB_PATH=/app/db/whatsmeow.db
ENV MEDIA_DIR=/app/media_tmp
ENV BRIDGE_URL=http://localhost:8080

EXPOSE 8080
VOLUME ["/app/db", "/app/media_tmp"]

ENTRYPOINT ["whatsmeow-bridge"]
