#!/bin/sh

chown -R www-data:www-data /app/storage /app/bootstrap/cache
chmod -R 775 /app/storage /app/bootstrap/cache

if [ "$1" = "php" ]; then
  exec "$@"
fi

php-fpm -D
nginx -g "daemon off;"
