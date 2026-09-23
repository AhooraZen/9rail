# 9rail - Standalone 9Router on Railway

Lightweight standalone Docker container for [9Router](https://github.com/dnakov/9router), configured for Railway deployment with automated SQLite database backup to GitHub (`AhooraZen/dbb`).

## Environment Variables

| Variable | Description | Default |
| :--- | :--- | :--- |
| `PORT` | Listening HTTP port | `20128` |
| `GH_TOKEN` | GitHub PAT for database backup and restore | (Required for backup sync) |
| `DB_REPO` | Target GitHub backup repository | `AhooraZen/dbb` |
| `PERSISTENT_DATA_PATH` | Storage volume mount point | `/data` |
| `BACKUP_INTERVAL` | Backup cadence in seconds | `300` |
