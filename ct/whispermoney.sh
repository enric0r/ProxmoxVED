#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/enric0r/ProxmoxVED/main/misc/build.func)
# Copyright (c) 2021-2026 community-scripts ORG
# Author: OpenAI (ChatGPT)
# License: MIT | https://github.com/enric0r/ProxmoxVED/raw/main/LICENSE
# Source: https://whisper.money/

APP="Whisper Money"
var_tags="${var_tags:-finance;budgeting;accounting}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-8}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -d /opt/whispermoney ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  if check_for_gh_release "whispermoney" "whisper-money/whisper-money"; then
    msg_info "Stopping Services"
    systemctl stop caddy whispermoney-ssr whispermoney-queue whispermoney-emails whispermoney-scheduler.timer whispermoney-scheduler.service
    msg_ok "Stopped Services"

    msg_info "Backing up Data"
    cp /opt/whispermoney/.env /opt/whispermoney.env.bak
    cp -r /opt/whispermoney/storage /opt/whispermoney_storage_backup
    msg_ok "Backed up Data"

    CLEAN_INSTALL=1 fetch_and_deploy_gh_release "whispermoney" "whisper-money/whisper-money" "tarball"

    msg_info "Restoring Data"
    cp /opt/whispermoney.env.bak /opt/whispermoney/.env
    rm -f /opt/whispermoney.env.bak
    cp -r /opt/whispermoney_storage_backup/. /opt/whispermoney/storage
    rm -rf /opt/whispermoney_storage_backup
    msg_ok "Restored Data"

    msg_info "Updating Application"
    cd /opt/whispermoney
    COMPOSER_ALLOW_SUPERUSER=1 $STD composer install --no-dev --optimize-autoloader --no-interaction
    $STD bun install --frozen-lockfile
    $STD bun run build:ssr
    mkdir -p storage/app/public
    mkdir -p storage/framework/cache/data storage/framework/sessions storage/framework/views storage/logs bootstrap/cache
    chown -R www-data:www-data /opt/whispermoney
    chmod -R 775 storage bootstrap/cache
    $STD php artisan migrate --force
    $STD php artisan storage:link
    $STD php artisan optimize:clear
    $STD php artisan config:cache
    $STD php artisan route:cache
    $STD php artisan view:cache
    $STD php artisan event:cache
    msg_ok "Updated Application"

    msg_info "Starting Services"
    PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;')
    systemctl start php${PHP_VER}-fpm caddy whispermoney-ssr whispermoney-queue whispermoney-emails whispermoney-scheduler.timer
    msg_ok "Started Services"
    msg_ok "Updated successfully!"
  fi
  exit
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}${CL}"
echo -e "${INFO}${YW}Configure email and open banking variables in /opt/whispermoney/.env if needed.${CL}"
