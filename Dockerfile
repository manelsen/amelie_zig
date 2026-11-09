# Multi-stage build for Amélie-Zig
FROM alpine:latest AS builder

WORKDIR /app

# Install Zig and build dependencies
RUN apk add --no-cache \
    zig \
    sqlite-dev

# Copy source code
COPY . .

# Build the project
RUN zig build

# Runtime stage
FROM alpine:latest

WORKDIR /app

# Install runtime dependencies
RUN apk add --no-cache sqlite-libs

# Copy binary from builder
COPY --from=builder /app/zig-out/bin/amelie-zig /usr/local/bin/amelie-zig

# Create directory for database
RUN mkdir -p /data && \
    chown -R nobody:nobody /data

# Switch to non-root user
USER nobody

# Set working directory
WORKDIR /data

# Expose port
EXPOSE 3000

# Set environment variables
ENV GEMINI_API_KEY=""
ENV DB_PATH="/data/amelie.db"
ENV WHATSAPP_WEBHOOK_URL="http://whatsapp-bridge:8080/send"
ENV PORT="3000"
ENV HOST="0.0.0.0"

# Run the application
ENTRYPOINT ["/usr/local/bin/amelie-zig"]
