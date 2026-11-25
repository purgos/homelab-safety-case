#!/bin/bash
# cloud-restore-drill.sh -- restore the example.org cloud stack's Nextcloud from the Mega S4 backups into a
# THROWAWAY Debian 13 LXC, and prove encrypted files decrypt. Doubles as the real disaster-restore runbook
# (see VMs/cloud-nextcloud/README.md "Restore from backup"). First run: 2026-09-25, PASSED.
#
# Prep (from tomo; see the runbook for the exact commands):
#   1. pct create <id> debian-13-standard ... --unprivileged 1 --features nesting=1  (LAN only, no tailnet)
#   2. in the CT: apt install postgresql apache2 libapache2-mod-php php-{pgsql,gd,zip,intl,mbstring,xml,curl,bcmath,gmp,imagick,apcu}
#      unzip zstd sudo curl wget; put the matching Nextcloud release at /tmp/nextcloud-<ver>.zip (config.php 'version');
#      install current rclone from downloads.rclone.org (needs >=1.65 for `serve s3`; MinIO no longer ships free binaries)
#   3. stream the backups in from the jump box (decrypted there with s4crypt) into /root/restore:
#      cloud-{nextcloud,auth,edge}.tar.zst + s3/ (the nextcloud-s3 objects)
#   4. pipe this script in: ssh dyonisis 'pct exec <id> -- bash -s' < cloud-restore-drill.sh
# Lessons baked in: en_US.UTF-8 locale must exist before loading pg_dumpall; the tarballs store ABSOLUTE
# paths (tar -P); user_oidc must stay ENABLED (SSO users' accounts live in that backend -- disabling it makes
# their files "not found"); run it on an EMPTY Postgres (a second load just produces duplicate-key noise).
# DESTROY THE CONTAINER AFTERWARDS -- it holds decrypted data.
set -euo pipefail
cd /root/restore
T0=$(date +%s)
IP=$(ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1)

command -v sudo >/dev/null || { DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sudo >/dev/null 2>&1; }
echo "== 0. locale the dump needs (CREATE DATABASE ... LOCALE en_US.utf8)"
if ! locale -a | grep -qi "^en_US.utf8$"; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq locales >/dev/null 2>&1
  sed -i "s/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/" /etc/locale.gen && locale-gen >/dev/null 2>&1
  systemctl restart postgresql
fi
locale -a | grep -i "^en_US.utf8$"
echo "== 1. Postgres from cloud-auth's pg_dumpall"
zstd -dc cloud-auth.tar.zst | tar -xf - backup/dumps/postgres-all.sql
sudo -u postgres psql -q -v ON_ERROR_STOP=0 -f backup/dumps/postgres-all.sql >/tmp/pg-restore.log 2>&1 || true
echo "   errors: $(grep -c ERROR /tmp/pg-restore.log) (role/db 'already exists' is expected)"; grep ERROR /tmp/pg-restore.log | grep -v -E "already exists" | head -3 || true
sudo -u postgres psql -Atc "select datname from pg_database where not datistemplate order by 1" | tr '\n' ' '; echo
sudo -u postgres psql -d nextcloud_cloud -Atc "select 'oc_filecache rows: '||count(*) from oc_filecache"

echo "== 2. Nextcloud 35.0.0 code + config/ + data/ from the backup"
rm -rf /var/www/nextcloud && unzip -q /tmp/nextcloud-35.0.0.zip -d /var/www/
zstd -dc cloud-nextcloud.tar.zst | tar -P -xf - /var/www/nextcloud/config /var/www/nextcloud/data   # backup stores absolute paths
# isolate from production: local S3 + no Redis + no mail + local DB, via a single override file
rm -f /var/www/nextcloud/config/redis.config.php
cat > /var/www/nextcloud/config/s3-objectstore.config.php <<EOF
<?php
\$CONFIG = array (
  'trusted_domains' => array (0 => '$IP', 1 => 'localhost'),
  'overwrite.cli.url' => 'http://$IP',
  'overwriteprotocol' => 'http',
  'dbhost' => '127.0.0.1',
  'memcache.local' => '\\\\OC\\\\Memcache\\\\APCu',
  'mail_smtpmode' => 'null',
  'objectstore' => array(
    'class' => '\\\\OC\\\\Files\\\\ObjectStore\\\\S3',
    'arguments' => array(
      'bucket' => 'example-nextcloud-backups', 'region' => 'us-east-1', 'autocreate' => false,
      'hostname' => '127.0.0.1', 'port' => 8333, 'use_ssl' => false, 'use_path_style' => true,
      'key' => 'restore', 'secret' => 'restoredrill',
    ),
  ),
);
EOF
# config.php's own dbhost/memcache entries lose to later-loaded *.config.php files; drop the Redis lines outright
sed -i "/'memcache.locking'/d; /'memcache.local'/d" /var/www/nextcloud/config/config.php
chown -R www-data:www-data /var/www/nextcloud

echo "== 3. local S3 (rclone serve s3) with the restored objects"
mkdir -p /srv/s3store/example-nextcloud-backups && cp -a s3/. /srv/s3store/example-nextcloud-backups/
pkill -f "rclone serve s3" || true
nohup /usr/local/bin/rclone serve s3 /srv/s3store --addr 127.0.0.1:8333 --auth-key restore,restoredrill >/tmp/serve-s3.log 2>&1 &
sleep 3

echo "== 4. Apache vhost"
cat > /etc/apache2/sites-available/nextcloud.conf <<'EOF'
<VirtualHost *:80>
  DocumentRoot /var/www/nextcloud
  <Directory /var/www/nextcloud/>
    Require all granted
    AllowOverride All
    Options FollowSymLinks MultiViews
    <IfModule mod_rewrite.c>
      RewriteEngine On
      RewriteOptions InheritDown
      RewriteCond %{REQUEST_FILENAME} !-f
      RewriteCond %{REQUEST_FILENAME} !-d
      RewriteRule ^(.*)$ /index.php/$1 [QSA,L]
    </IfModule>
  </Directory>
</VirtualHost>
EOF
a2dissite -q 000-default >/dev/null; a2ensite -q nextcloud >/dev/null; a2enmod -q rewrite headers env dir mime >/dev/null
sed -i 's/^memory_limit = .*/memory_limit = 512M/' /etc/php/8.4/apache2/php.ini /etc/php/8.4/cli/php.ini
systemctl restart apache2

echo "== 5. occ"
OCC="sudo -u www-data php /var/www/nextcloud/occ"
$OCC status 2>&1 | grep -E "installed|version|maintenance" || true
# NOTE: keep user_oidc enabled -- SSO users live in that backend. It simply cannot reach Authentik from here.
$OCC encryption:status 2>&1 | grep -E "enabled|defaultModule" || true
echo "   elapsed so far: $(( $(date +%s) - T0 ))s"

echo "== 6. prove decryption: read a few real files through Nextcloud's file layer and compare with the recorded plaintext size"
U=${DRILL_USER:-purgos}
sudo -u postgres psql -d nextcloud_cloud -Atc "select f.path||'|'||f.unencrypted_size from oc_filecache f join oc_storages s on s.numeric_id=f.storage where s.id='object::user:$U' and f.path like 'files/%' and f.encrypted>0 and f.size>0 order by f.mtime desc limit 4" |
while IFS='|' read -r path want; do
  out=/tmp/drill-$(basename "$path" | tr ' ' _)
  $OCC files:get "$U/$path" "$out" >/dev/null 2>&1 || true
  got=$(stat -c%s "$out" 2>/dev/null || echo 0)
  [ "$got" = "$want" ] && r=PASS || r=FAIL
  printf '   %s %-40s %9s bytes (expected %9s) %s\n' "$r" "$path" "$got" "$want" "$(file -b "$out" 2>/dev/null | cut -c1-30)"
done
echo "   total elapsed: $(( $(date +%s) - T0 ))s"
