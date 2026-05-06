#!/bin/sh

chown -R www-data:www-data /app/storage /app/bootstrap/cache
chmod -R 775 /app/storage /app/bootstrap/cache

nohup php-fpm > /dev/stdout 2>/dev/stderr &
nginx -g "daemon off;" > /dev/stdout 2>/dev/stderr
