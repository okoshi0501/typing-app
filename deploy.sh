#!/usr/bin/env bash
set -euo pipefail

# -------------------------
# カスタマイズ可能な設定
# -------------------------
APP_DIR="/var/www/html"                # アプリの現在のリリースが置かれるディレクトリ
REPO_URL="git@github.com:your/repo.git"
BRANCH="${BRANCH:-main}"               # デフォルトブランチ。CIから上書き可
RELEASES_DIR="${APP_DIR}/releases"
CURRENT_DIR="${APP_DIR}/current"
KEEP_RELEASES=5
USER="www-data"
GROUP="www-data"
COMPOSER_FLAGS="--no-dev --optimize-autoloader --prefer-dist --no-interaction --no-progress"
NPM_BUILD_CMD="npm ci && npm run build" # フロントビルドが不要なら空にする
MIGRATE="true"                         # マイグレーションを実行するか
MAINTENANCE_ON="docker compose exec app php artisan down --no-interaction || true"
MAINTENANCE_OFF="docker compose exec app php artisan up || true"
LOGFILE="/var/log/deploy.log"

timestamp() { date +"%Y%m%d%H%M%S"; }

# -------------------------
# ログ出力
# -------------------------
log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"
}

# -------------------------
# エラーハンドラ
# -------------------------
on_error() {
  local rc=$?
  log "ERROR: deploy failed with exit code ${rc}"
  # 必要ならロールバックを呼ぶ
  if [ -n "${NEW_RELEASE:-}" ]; then
    log "Attempting rollback to previous release"
    rollback || log "Rollback failed"
  fi
  exit $rc
}
trap on_error ERR

# -------------------------
# リリース作成
# -------------------------
create_release() {
  mkdir -p "$RELEASES_DIR"
  NEW_RELEASE="${RELEASES_DIR}/$(timestamp)"
  log "Creating new release directory: $NEW_RELEASE"
  git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$NEW_RELEASE"
}

# -------------------------
# 依存インストールとビルド
# -------------------------
install_deps_and_build() {
  cd "$NEW_RELEASE"
  log "Installing composer dependencies"
  docker compose exec app composer install $COMPOSER_FLAGS

  if [ -n "$NPM_BUILD_CMD" ]; then
    if command -v npm >/dev/null 2>&1; then
      log "Building frontend assets"
      eval "$NPM_BUILD_CMD"
    else
      log "npm not found, skipping frontend build"
    fi
  fi
}

# -------------------------
# 権限設定
# -------------------------
set_permissions() {
  log "Setting ownership to ${USER}:${GROUP} and permissions"
  chown -R "$USER":"$GROUP" "$NEW_RELEASE"
  mkdir -p "$NEW_RELEASE/storage" "$NEW_RELEASE/bootstrap/cache"
  chown -R "$USER":"$GROUP" "$NEW_RELEASE/storage" "$NEW_RELEASE/bootstrap/cache"
  chmod -R ug+rwx "$NEW_RELEASE/storage" "$NEW_RELEASE/bootstrap/cache"
}

# -------------------------
# リリース切替
# -------------------------
switch_symlink() {
  log "Switching current symlink to new release"
  ln -sfn "$NEW_RELEASE" "$CURRENT_DIR"
}

# -------------------------
# キャッシュとマイグレーション
# -------------------------
optimize_and_migrate() {
  cd "$CURRENT_DIR"
  log "Clearing config cache"
  docker compose exec app php artisan config:clear

  if [ "$MIGRATE" = "true" ]; then
    log "Putting app into maintenance mode"
    eval "$MAINTENANCE_ON"
  fi

  log "Running migrations (if any)"
  if [ "$MIGRATE" = "true" ]; then
    docker compose exec app php artisan migrate --force
  fi

  log "Caching config, routes, views"
  docker compose exec app php artisan config:cache
  docker compose exec app php artisan route:cache || log "route:cache failed, continuing"
  docker compose exec app php artisan view:cache || log "view:cache failed, continuing"

  if [ "$MIGRATE" = "true" ]; then
    log "Bringing app out of maintenance mode"
    eval "$MAINTENANCE_OFF"
  fi
}

# -------------------------
# ワーカー再起動
# -------------------------
restart_workers() {
  cd "$CURRENT_DIR"
  if docker compose exec app php artisan queue:restart --help >/dev/null 2>&1; then
    log "Restarting queue workers"
    docker compose exec app php artisan queue:restart
  else
    log "No queue restart command available or not needed"
  fi

  # PHP-FPM 再起動が必要ならアンコメントして使う
  # log "Restarting php-fpm"
  # systemctl reload php8.1-fpm || systemctl restart php8.1-fpm
}

# -------------------------
# 古いリリース削除
# -------------------------
cleanup_releases() {
  log "Cleaning up old releases, keeping last $KEEP_RELEASES"
  cd "$RELEASES_DIR"
  ls -1tr | head -n -"$KEEP_RELEASES" | xargs -r -I {} rm -rf {}
}

# -------------------------
# ロールバック
# -------------------------
rollback() {
  log "Performing rollback"
  if [ ! -d "$RELEASES_DIR" ]; then
    log "No releases directory, cannot rollback"
    return 1
  fi
  PREV=$(ls -1tr "$RELEASES_DIR" | tail -n 2 | head -n 1 || true)
  if [ -z "$PREV" ]; then
    log "No previous release to rollback to"
    return 1
  fi
  PREV_PATH="${RELEASES_DIR}/${PREV}"
  log "Switching current to ${PREV_PATH}"
  ln -sfn "$PREV_PATH" "$CURRENT_DIR"
  log "Rollback complete"
  return 0
}

# -------------------------
# メイン処理
# -------------------------
main() {
  log "Starting deploy for branch $BRANCH"
  create_release
  install_deps_and_build
  set_permissions
  switch_symlink
  optimize_and_migrate
  restart_workers
  cleanup_releases
  log "Deploy finished successfully"
}

main "$@"
