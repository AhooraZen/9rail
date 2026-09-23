FROM node:22-alpine

# System dependencies for SQLite, git sync, compression and shell utilities
RUN apk add --no-cache sqlite git zstd curl ca-certificates bash jq

# Install 9router globally
RUN npm install -g 9router@latest

WORKDIR /app

COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

ENV PORT=20128
EXPOSE 20128

CMD ["/app/start.sh"]
