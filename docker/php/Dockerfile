FROM php:8.4-fpm

RUN apt-get update && apt-get install -y \
    zip unzip git curl libpq-dev libonig-dev

RUN docker-php-ext-install pdo_mysql mbstring

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

WORKDIR /var/www/html
