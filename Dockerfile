FROM node:22-alpine

# System dependencies for SQLite, git sync, compression, shell utilities, and tini init reaper
RUN apk add --no-cache sqlite git zstd curl ca-certificates bash jq tini

# Install 9router and bcryptjs globally
RUN npm install -g 9router@latest bcryptjs

WORKDIR /app

COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

ENV PORT=20128
EXPOSE 20128

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/app/start.sh"]
