#!/bin/sh

php artisan config:clear
php artisan config:cache

php-fpm -D

nginx -g "daemon off;"
