#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: OpenAI (ChatGPT)
# License: MIT | https://github.com/enric0r/ProxmoxVED/raw/main/LICENSE
# Source: https://whisper.money/

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt install -y \
  nginx \
  redis-server
msg_ok "Installed Dependencies"

PHP_VERSION="8.4" PHP_FPM="YES" PHP_MODULES="bcmath,gd,intl,xml,zip,pdo_mysql,mbstring,curl,exif,redis,pcntl" setup_php
setup_composer
NODE_VERSION="20" setup_nodejs
setup_mariadb
MARIADB_DB_NAME="whisper_money" MARIADB_DB_USER="whisper_money" setup_mariadb_db

msg_info "Installing Bun"
export BUN_INSTALL="/usr/local/bun"
curl -fsSL https://bun.sh/install | $STD bash
ln -sf /usr/local/bun/bin/bun /usr/local/bin/bun
ln -sf /usr/local/bun/bin/bunx /usr/local/bin/bunx
chmod -R a+rx /usr/local/bun
msg_ok "Installed Bun"

fetch_and_deploy_gh_release "whispermoney" "whisper-money/whisper-money" "tarball"

msg_info "Setting up Whisper Money"
cd /opt/whispermoney
cp .env.example .env
sed -i "s|^APP_ENV=.*|APP_ENV=production|" .env
sed -i "s|^APP_DEBUG=.*|APP_DEBUG=false|" .env
sed -i "s|^APP_URL=.*|APP_URL=http://${LOCAL_IP}|" .env
sed -i "s|^LOG_LEVEL=.*|LOG_LEVEL=error|" .env
sed -i "s|^DB_HOST=.*|DB_HOST=127.0.0.1|" .env
sed -i "s|^DB_PORT=.*|DB_PORT=3306|" .env
sed -i "s|^DB_DATABASE=.*|DB_DATABASE=${MARIADB_DB_NAME}|" .env
sed -i "s|^DB_USERNAME=.*|DB_USERNAME=${MARIADB_DB_USER}|" .env
sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${MARIADB_DB_PASS}|" .env
sed -i "s|^SESSION_DRIVER=.*|SESSION_DRIVER=redis|" .env
sed -i "s|^SESSION_ENCRYPT=.*|SESSION_ENCRYPT=true|" .env
sed -i "s|^CACHE_STORE=.*|CACHE_STORE=redis|" .env
sed -i "s|^QUEUE_CONNECTION=.*|QUEUE_CONNECTION=database|" .env
sed -i "s|^REDIS_HOST=.*|REDIS_HOST=127.0.0.1|" .env
sed -i "s|^REDIS_PORT=.*|REDIS_PORT=6379|" .env
sed -i "s|^MAIL_MAILER=.*|MAIL_MAILER=log|" .env
sed -i "s|^EMAIL_VERIFICATION_ENABLED=.*|EMAIL_VERIFICATION_ENABLED=false|" .env
sed -i "s|^DEV_MODE=.*|DEV_MODE=false|" .env
grep -q "^SESSION_SECURE_COOKIE=" .env || echo "SESSION_SECURE_COOKIE=false" >>.env
COMPOSER_ALLOW_SUPERUSER=1 $STD composer install --no-dev --optimize-autoloader --no-interaction
$STD php artisan key:generate --force
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
msg_ok "Set up Whisper Money"

msg_info "Configuring Nginx"
PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;')
cat <<EOF >/etc/nginx/sites-available/whispermoney
server {
    listen 80;
    server_name _;
    root /opt/whispermoney/public;
    index index.php index.html;

    client_max_body_size 35M;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    error_page 404 /index.php;

    location ~ \.php$ {
        fastcgi_pass unix:/run/php/php${PHP_VER}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_buffer_size 128k;
        fastcgi_buffers 4 256k;
        fastcgi_busy_buffers_size 256k;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF
ln -sf /etc/nginx/sites-available/whispermoney /etc/nginx/sites-enabled/whispermoney
rm -f /etc/nginx/sites-enabled/default
$STD nginx -t
msg_ok "Configured Nginx"

msg_info "Creating Services"
cat <<EOF >/etc/systemd/system/whispermoney-ssr.service
[Unit]
Description=Whisper Money Inertia SSR
After=network.target mariadb.service redis-server.service
Requires=mariadb.service redis-server.service

[Service]
Type=simple
User=www-data
WorkingDirectory=/opt/whispermoney
Environment=BUN_INSTALL=/usr/local/bun
Environment=PATH=/usr/local/bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/usr/bin/php /opt/whispermoney/artisan inertia:start-ssr --runtime=bun
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat <<EOF >/etc/systemd/system/whispermoney-queue.service
[Unit]
Description=Whisper Money Queue Worker
After=network.target mariadb.service redis-server.service
Requires=mariadb.service redis-server.service

[Service]
Type=simple
User=www-data
WorkingDirectory=/opt/whispermoney
ExecStart=/usr/bin/php /opt/whispermoney/artisan queue:work database --queue=default --sleep=3 --tries=3 --max-time=3600
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat <<EOF >/etc/systemd/system/whispermoney-emails.service
[Unit]
Description=Whisper Money Email Queue Worker
After=network.target mariadb.service redis-server.service
Requires=mariadb.service redis-server.service

[Service]
Type=simple
User=www-data
WorkingDirectory=/opt/whispermoney
ExecStart=/usr/bin/php /opt/whispermoney/artisan queue:work database --queue=emails --sleep=1 --tries=5 --max-time=3600
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat <<EOF >/etc/systemd/system/whispermoney-scheduler.service
[Unit]
Description=Whisper Money Task Scheduler
After=network.target mariadb.service redis-server.service
Requires=mariadb.service redis-server.service

[Service]
Type=oneshot
User=www-data
WorkingDirectory=/opt/whispermoney
ExecStart=/usr/bin/php /opt/whispermoney/artisan schedule:run
EOF

cat <<EOF >/etc/systemd/system/whispermoney-scheduler.timer
[Unit]
Description=Run Whisper Money Scheduler every minute

[Timer]
OnCalendar=*-*-* *:*:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl enable -q --now php${PHP_VER}-fpm redis-server nginx whispermoney-ssr whispermoney-queue whispermoney-emails whispermoney-scheduler.timer
msg_ok "Created Services"

motd_ssh
customize
cleanup_lxc
