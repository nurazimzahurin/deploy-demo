#!/bin/sh

chown -R www-data:www-data /app/storage /app/bootstrap/cache
chmod -R 775 /app/storage /app/bootstrap/cache

php-fpm -D

nginx -g "daemon off;"
