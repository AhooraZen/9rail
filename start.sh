#!/bin/bash
set -e

echo "🚀 Bootstrapping Standalone 9Router on Railway..."

# Support volume mount at /data or fallback to /app/data
DATA_DIR="${PERSISTENT_DATA_PATH:-/data}"
mkdir -p "$DATA_DIR/9router/db" "$DATA_DIR/9router/runtime" "$DATA_DIR/9router/logs"
mkdir -p /root/.9router

# Symlink persistent directories to standard /root/.9router paths
ln -sfn "$DATA_DIR/9router/db" /root/.9router/db
ln -sfn "$DATA_DIR/9router/runtime" /root/.9router/runtime
ln -sfn "$DATA_DIR/9router/logs" /root/.9router/logs

TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-$GITHUB_PERSONAL_ACCESS_TOKEN}}"
REPO="${DB_REPO:-AhooraZen/dbb}"
RESTORE_TMP="/tmp/dbb_restore"

DB_FILE="$DATA_DIR/9router/db/data.sqlite"

# Check if database is missing or empty (0 settings/providers)
SHOULD_RESTORE=0
if [ ! -f "$DB_FILE" ]; then
  SHOULD_RESTORE=1
elif [ "$(sqlite3 "$DB_FILE" "SELECT count(*) FROM settings;" 2>/dev/null || echo 0)" -eq 0 ]; then
  echo "⚠️ Existing database is empty or uninitialized. Triggering restore..."
  SHOULD_RESTORE=1
fi

# --- STEP 1: Restore SQLite database from GitHub repo 'dbb' if needed ---
if [ -n "$TOKEN" ] && [ "$SHOULD_RESTORE" -eq 1 ]; then
  echo "🔍 Restoring 9Router database from $REPO..."
  rm -rf "$RESTORE_TMP"
  
  # Try branch '9router' first
  if git clone --depth 1 -b 9router "https://x-access-token:${TOKEN}@github.com/${REPO}.git" "$RESTORE_TMP" 2>/dev/null; then
    if [ -f "$RESTORE_TMP/data.sqlite" ]; then
      cp "$RESTORE_TMP/data.sqlite" "$DB_FILE"
      echo "✅ Database restored from '9router' branch (size: $(du -h "$DB_FILE" | cut -f1))."
    elif [ -f "$RESTORE_TMP/9router.tar.zst" ]; then
      zstd -d -c "$RESTORE_TMP/9router.tar.zst" | tar -xf - -C "$DATA_DIR/9router/db" 2>/dev/null || true
      echo "✅ Database restored from '9router.tar.zst' on '9router' branch."
    fi
  # Fallback to 'main' branch (where the initial archive exists)
  elif git clone --depth 1 -b main "https://x-access-token:${TOKEN}@github.com/${REPO}.git" "$RESTORE_TMP" 2>/dev/null; then
    if [ -f "$RESTORE_TMP/databases.tar.zst" ]; then
      EXTRACT_DIR="/tmp/extract_dbb"
      rm -rf "$EXTRACT_DIR" && mkdir -p "$EXTRACT_DIR"
      zstd -d -c "$RESTORE_TMP/databases.tar.zst" | tar -xf - -C "$EXTRACT_DIR" 2>/dev/null || true
      if [ -f "$EXTRACT_DIR/9router/db/data.sqlite" ]; then
        cp "$EXTRACT_DIR/9router/db/data.sqlite" "$DB_FILE"
        echo "✅ Initial 9Router database extracted and restored from 'main' branch archive."
      elif [ -f "$EXTRACT_DIR/data.sqlite" ]; then
        cp "$EXTRACT_DIR/data.sqlite" "$DB_FILE"
        echo "✅ Database extracted from archive."
      fi
      rm -rf "$EXTRACT_DIR"
    fi
  fi
  rm -rf "$RESTORE_TMP"
fi

# Verify integrity and auto-recover active SQLite database if needed
if [ -f "$DB_FILE" ]; then
  chk="$(sqlite3 "$DB_FILE" "PRAGMA integrity_check;" 2>/dev/null || echo "corrupt")"
  if [ "$chk" != "ok" ]; then
    echo "⚠️ [INTEGRITY WARNING] Database data.sqlite: $chk"
    echo "🔧 [AUTO-REPAIR] Attempting automatic recovery..."
    sqlite3 "$DB_FILE" "REINDEX;" 2>/dev/null || true
  else
    echo "✅ SQLite database verified (integrity: ok, size: $(du -h "$DB_FILE" | cut -f1), providers: $(sqlite3 "$DB_FILE" "SELECT count(*) FROM providerConnections;" 2>/dev/null || echo 0))."
  fi

  # Support password / auth override via environment variables
  PASS="${ADMIN_PASSWORD:-${INITIAL_PASSWORD}}"
  if [ -n "$PASS" ]; then
    HASH=$(node -e "try { const b = require('bcryptjs'); console.log(b.hashSync(process.argv[1], 10)); } catch(e) { console.log(''); }" "$PASS" 2>/dev/null || true)
    if [ -n "$HASH" ]; then
      sqlite3 "$DB_FILE" "UPDATE settings SET data = json_set(data, '$.password', '$HASH', '$.requireLogin', true) WHERE id=1;" 2>/dev/null || true
      echo "🔑 Password successfully updated in database from INITIAL_PASSWORD/ADMIN_PASSWORD."
    fi
  fi

  if [ "$REQUIRE_LOGIN" = "false" ]; then
    sqlite3 "$DB_FILE" "UPDATE settings SET data = json_set(data, '$.requireLogin', false) WHERE id=1;" 2>/dev/null || true
    echo "🔓 Login disabled in database (REQUIRE_LOGIN=false)."
  fi
fi

# --- STEP 2: Background atomic backup daemon (syncs to branch '9router') ---
backup_loop() {
  SYNC_DIR="$DATA_DIR/.dbb_sync_9router"
  CHECKSUM_FILE="$DATA_DIR/.9router_checksum.sha256"
  INTERVAL="${BACKUP_INTERVAL:-3600}"

  if [ -z "$TOKEN" ]; then
    echo "⚠️ GH_TOKEN not provided; backup daemon disabled."
    return
  fi

  echo "🛡️ [BACKUP WORKER] Started. Syncing 9Router DB to $REPO (branch: 9router) every ${INTERVAL}s"

  while true; do
    sleep "$INTERVAL"
    [ ! -f "$DB_FILE" ] && continue

    # Do not backup if database is somehow empty
    SETTING_CNT="$(sqlite3 "$DB_FILE" "SELECT count(*) FROM settings;" 2>/dev/null || echo 0)"
    [ "$SETTING_CNT" -eq 0 ] && continue

    # Calculate checksum based on configuration & provider tables (ignoring volatile ephemeral logs)
    CURRENT_CS=$(sqlite3 "$DB_FILE" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'request%' AND name NOT LIKE 'log%'; " 2>/dev/null | while read -r tbl; do sqlite3 "$DB_FILE" "SELECT * FROM $tbl;" 2>/dev/null; done | sha256sum | awk '{print $1}')
    [ -z "$CURRENT_CS" ] && CURRENT_CS=$(sha256sum "$DB_FILE" 2>/dev/null | awk '{print $1}')
    LAST_CS=""
    [ -f "$CHECKSUM_FILE" ] && LAST_CS=$(cat "$CHECKSUM_FILE" 2>/dev/null || true)

    if [ -z "$CURRENT_CS" ] || [ "$CURRENT_CS" = "$LAST_CS" ]; then
      continue
    fi

    # 1. Atomic online backup snapshot with vacuuming
    STAGING="/tmp/9router_backup"
    rm -rf "$STAGING" && mkdir -p "$STAGING"
    sqlite3 "$DB_FILE" ".backup '$STAGING/data.sqlite'" 2>/dev/null || true
    sqlite3 "$STAGING/data.sqlite" "VACUUM;" 2>/dev/null || true

    # 2. Check snapshot integrity
    CHK=$(sqlite3 "$STAGING/data.sqlite" "PRAGMA integrity_check;" 2>/dev/null || echo "fail")
    if [ "$CHK" != "ok" ]; then
      echo "⚠️ [BACKUP WORKER] Backup snapshot failed integrity check ($CHK). Skipping."
      rm -rf "$STAGING"
      continue
    fi

    # 3. Setup git orphan branch and push
    rm -rf "$SYNC_DIR" && mkdir -p "$SYNC_DIR"
    cd "$SYNC_DIR"
    git init >/dev/null 2>&1
    git config user.name "9Router-Backup-Worker"
    git config user.email "backup@localhost"
    git remote add origin "https://x-access-token:${TOKEN}@github.com/${REPO}.git" 2>/dev/null || true

    git checkout --orphan 9router >/dev/null 2>&1 || git checkout -b 9router >/dev/null 2>&1
    cp "$STAGING/data.sqlite" "$SYNC_DIR/data.sqlite"
    git add data.sqlite >/dev/null 2>&1
    git commit -m "Auto backup 9router: $(date -u +'%Y-%m-%d %H:%M:%SZ')" >/dev/null 2>&1

    if git push -f origin 9router >/dev/null 2>&1; then
      echo "$CURRENT_CS" > "$CHECKSUM_FILE"
      echo "💾 [BACKUP WORKER] Database synced to $REPO (branch: 9router) at $(date -u +'%Y-%m-%d %H:%M:%SZ')"
    else
      echo "⚠️ [BACKUP WORKER] Git push to branch 9router failed."
    fi
    rm -rf "$STAGING" "$SYNC_DIR"
  done
}

backup_loop &

# --- STEP 3: Locate and start 9Router standalone server ---
APP_DIR="$(npm root -g 2>/dev/null)/9router/app"
if [ ! -d "$APP_DIR" ] || [ ! -f "$APP_DIR/custom-server.js" ]; then
  APP_DIR="$(find / -name 'custom-server.js' 2>/dev/null | grep '9router/app/custom-server.js' | head -n 1 | xargs -r dirname)"
fi

LISTEN_PORT="${PORT:-20128}"

if [ -n "$APP_DIR" ] && [ -f "$APP_DIR/custom-server.js" ]; then
  echo "📡 Launching 9Router standalone server from $APP_DIR on port $LISTEN_PORT..."
  cd "$APP_DIR"
  exec env PORT="$LISTEN_PORT" HOSTNAME="0.0.0.0" node --optimize_for_size --max-old-space-size=256 custom-server.js
else
  echo "📡 Launching 9Router with global CLI on port $LISTEN_PORT..."
  exec 9router start --port "$LISTEN_PORT" --host 0.0.0.0
fi
