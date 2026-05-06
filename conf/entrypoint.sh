#!/bin/sh

nohup php-fpm > /dev/stdout 2>/dev/stderr &
nginx -g "daemon off;" > /dev/stdout 2>/dev/stderr
