# Deployment Deep Dive

A complete explanation of every file, command, and concept used to deploy this Laravel app on Railway using Docker, GitHub Actions, and nginx + php-fpm.

---

## Table of Contents

1. [The Big Picture](#the-big-picture)
2. [How PHP Gets Served](#how-php-gets-served)
3. [Dockerfile](#dockerfile)
4. [conf/nginx.conf](#confnginxconf)
5. [conf/nginx-site.conf](#confnginx-siteconf)
6. [conf/entrypoint.sh](#confentrypointsh)
7. [docker-compose.yml](#docker-composeyml)
8. [GitHub Actions Workflows](#github-actions-workflows)
9. [railway.toml](#railwaytoml)
10. [The Full Deploy Flow](#the-full-deploy-flow)
11. [The Staging Flow](#the-staging-flow)
12. [Rollback](#rollback)

---

## The Big Picture

When a user visits your app, this is what happens:

```
User's browser
     |
     | HTTP request
     v
   nginx                  <-- web server, handles HTTP
     |
     | forwards .php requests
     v
  php-fpm                 <-- PHP process manager, executes your code
     |
     | runs
     v
Laravel app               <-- your actual application
```

nginx and php-fpm are two separate programs running inside the same Docker container. nginx handles the HTTP layer. php-fpm handles the PHP execution layer. They talk to each other via a local network port (9000).

---

## How PHP Gets Served

### Why not just nginx alone?

nginx is a web server. It can serve static files (images, CSS, HTML) extremely fast. But it cannot execute PHP. It has no PHP interpreter built in.

### Why not just php alone?

PHP has a built-in web server (`php artisan serve`) but it is single-threaded, not production-grade, and not designed to handle real traffic.

### The solution: nginx + php-fpm

**php-fpm** (FastCGI Process Manager) is a PHP process manager. It:
- Starts a pool of PHP worker processes
- Listens on a TCP port (9000 by default)
- Receives PHP files to execute from nginx
- Returns the output back to nginx

**The request flow in detail:**

```
1. Browser sends: GET /index.php HTTP/1.1

2. nginx receives it
   - Is it a static file? No
   - Does it match \.php$? Yes
   - Forward to php-fpm at 127.0.0.1:9000

3. php-fpm receives the FastCGI request
   - Picks an available worker process
   - Executes /app/public/index.php
   - Laravel boots, handles the request, returns HTML

4. php-fpm sends the HTML back to nginx

5. nginx sends the HTTP response back to the browser
```

FastCGI is just a protocol — a standard way for a web server to talk to an external program that generates dynamic content.

---

## Dockerfile

```dockerfile
# Stage 1: Install composer dependencies
FROM php:8.2-fpm AS vendor
```

**FROM** — every Dockerfile starts with a base image. `php:8.2-fpm` is an official PHP image that already has PHP 8.2 and php-fpm installed. The `AS vendor` names this stage so we can reference it later.

**Multi-stage build** — this Dockerfile has two stages. Stage 1 exists only to install composer dependencies. Stage 2 is the actual production image. This keeps the final image small because composer (and git, curl, etc.) don't end up in production.

```dockerfile
WORKDIR /tmp/app
```

**WORKDIR** — sets the working directory inside the container. All subsequent commands run from this path. If it doesn't exist, Docker creates it.

```dockerfile
RUN apt-get update && apt-get install -y \
    git \
    curl \
    libpng-dev \
    libonig-dev \
    libxml2-dev \
    zip \
    unzip
```

**RUN** — executes a shell command during the image build. `apt-get update` refreshes the package list. `apt-get install -y` installs packages without prompting for confirmation (`-y` = yes to all). These packages are needed by composer and some PHP extensions.

The `&&` chains commands. The `\` is line continuation — same command, split across lines for readability.

```dockerfile
COPY --from=composer:latest /usr/bin/composer /usr/bin/composer
```

**COPY --from** — copies a file from another image (not from your local machine). `composer:latest` is the official composer image. We just grab the single binary from it rather than installing composer from scratch.

```dockerfile
COPY composer.json composer.lock ./
```

**COPY** — copies files from your local machine into the image. We only copy `composer.json` and `composer.lock` first (not the entire app) because Docker caches each layer. If these files haven't changed, Docker reuses the cached layer and skips the `composer install` step — making rebuilds much faster.

```dockerfile
RUN composer install \
    --no-dev \
    --no-scripts \
    --no-interaction \
    --prefer-dist \
    --ignore-platform-reqs
```

Installs PHP dependencies.

- `--no-dev` — skip development packages (phpunit, etc.), production only
- `--no-scripts` — don't run composer scripts (like `php artisan package:discover`), we'll do that at runtime
- `--no-interaction` — don't ask any questions
- `--prefer-dist` — download zip archives instead of cloning git repos, faster
- `--ignore-platform-reqs` — don't check PHP version/extension requirements, the final image handles that

---

```dockerfile
# Stage 2: Final production image
FROM php:8.2-fpm
```

Starts fresh from the base PHP image. Everything from Stage 1 is gone except what we explicitly copy.

```dockerfile
WORKDIR /app
```

All app files will live at `/app`.

```dockerfile
RUN apt-get update && apt-get install -y \
    nginx \
    libpng-dev \
    libonig-dev \
    libxml2-dev \
    && docker-php-ext-install pdo_mysql mbstring exif pcntl bcmath gd dom \
    && rm -rf /var/lib/apt/lists/*
```

Installs nginx and PHP extensions needed by Laravel:

- `pdo_mysql` — lets PHP connect to MySQL databases
- `mbstring` — multibyte string functions (required by Laravel)
- `exif` — image metadata reading
- `pcntl` — process control (needed for queue workers)
- `bcmath` — arbitrary precision math
- `gd` — image manipulation
- `dom` — XML/HTML DOM parsing

`docker-php-ext-install` is a helper script included in the official PHP Docker image that compiles and installs PHP extensions.

`rm -rf /var/lib/apt/lists/*` — deletes the apt package cache. Reduces image size. Best practice: always clean up after apt-get in the same RUN command (same layer), otherwise the cache is already baked in.

```dockerfile
COPY . /app
COPY --from=vendor /tmp/app/vendor /app/vendor
```

First line copies your entire app into `/app`. Second line copies the `vendor/` directory from Stage 1 (where composer ran) into the app. Order matters — we copy the full app first, then overwrite `vendor/` with the one built in the clean Linux environment.

```dockerfile
COPY conf/nginx.conf /etc/nginx/nginx.conf
COPY conf/nginx-site.conf /etc/nginx/sites-enabled/default
COPY conf/entrypoint.sh /entrypoint.sh
```

Copies our custom nginx configuration files into the locations nginx expects them, and copies the entrypoint script to the root.

```dockerfile
RUN chmod +x /entrypoint.sh
```

Makes the entrypoint script executable. Without this, the container would fail with "permission denied" when trying to run it.

```dockerfile
EXPOSE 80
```

Documents that this container listens on port 80. Does not actually open the port — it's metadata. Docker and Railway use this to know which port to route traffic to.

```dockerfile
ENTRYPOINT ["/entrypoint.sh"]
```

**ENTRYPOINT** — the command that runs when the container starts. Uses exec form (JSON array) rather than shell form (`ENTRYPOINT "/entrypoint.sh"`) because exec form runs the process directly without a shell wrapper, which means signals (like SIGTERM for graceful shutdown) are passed correctly to the process.

---

## conf/nginx.conf

The main nginx configuration file.

```nginx
user www-data;
```

nginx worker processes run as the `www-data` user (low-privilege system user). Security best practice — never run web servers as root.

```nginx
worker_processes auto;
```

Number of nginx worker processes. `auto` sets it to the number of CPU cores available.

```nginx
pid /run/nginx.pid;
```

Where nginx writes its process ID. Used by nginx to manage itself (reload, stop, etc.).

```nginx
events {
    worker_connections 1024;
}
```

Each worker process can handle up to 1024 simultaneous connections. Total connections = worker_processes × worker_connections.

```nginx
http {
    include /etc/nginx/mime.types;
```

Loads the MIME types file — tells nginx what Content-Type header to send for each file extension (`.js` → `application/javascript`, `.png` → `image/png`, etc.).

```nginx
    default_type application/octet-stream;
```

For file types not in the MIME list, default to binary stream.

```nginx
    sendfile on;
```

Uses the OS's `sendfile()` syscall to transfer files directly from disk to network socket, bypassing user space. Faster for serving static files.

```nginx
    keepalive_timeout 65;
```

How long to keep an idle HTTP connection open (seconds). Reduces overhead of establishing new connections for multiple requests.

```nginx
    access_log /dev/stdout;
    error_log /dev/stderr;
```

Send access logs and error logs to stdout/stderr instead of files. This is essential in Docker — containers don't have persistent log files, and Docker/Railway captures stdout/stderr as the container's logs. Without this, you'd see no nginx logs in Railway.

```nginx
    include /etc/nginx/sites-enabled/*;
```

Loads virtual host configurations from this directory. Our `nginx-site.conf` is placed here.

---

## conf/nginx-site.conf

The virtual host — tells nginx how to handle requests for this specific site.

```nginx
server {
    listen 80;
```

This server block handles requests on port 80 (standard HTTP).

```nginx
    root /app/public;
```

The document root — where nginx looks for files to serve. Laravel's entry point is `public/index.php`, so the root must be `public/`, not `/app/`.

```nginx
    index index.php;
```

When a directory is requested (e.g. `/`), look for `index.php` first.

```nginx
    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }
```

**try_files** — for every request:
1. Try to serve the exact file (`$uri`) — e.g. `/css/app.css`
2. Try to serve it as a directory (`$uri/`)
3. If neither exists, pass to `/index.php` with the query string — Laravel's router handles it

This is what makes Laravel's routing work. Every request that isn't a real file ends up at `index.php`.

```nginx
    location ~ \.php$ {
        fastcgi_pass 127.0.0.1:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
    }
```

**location ~ \.php$** — matches any request ending in `.php` (regex match with `~`).

**fastcgi_pass 127.0.0.1:9000** — forward this request to php-fpm listening on localhost port 9000. Both nginx and php-fpm are in the same container, so `127.0.0.1` works.

**fastcgi_param SCRIPT_FILENAME** — tells php-fpm the full path to the PHP file to execute. `$document_root` = `/app/public`, `$fastcgi_script_name` = `/index.php`.

**include fastcgi_params** — loads standard FastCGI parameters (request method, headers, etc.) that php-fpm needs.

---

## conf/entrypoint.sh

```sh
#!/bin/sh
```

Shebang line — tells the OS which interpreter to use. `/bin/sh` is the POSIX shell, available on all Linux systems. More portable than `/bin/bash`.

```sh
chown -R www-data:www-data /app/storage /app/bootstrap/cache
chmod -R 775 /app/storage /app/bootstrap/cache
```

**chown** — change ownership. `www-data:www-data` = user:group. The `-R` flag applies recursively to all files and subdirectories.

**Why** — the `COPY . /app` in the Dockerfile copies files owned by root. php-fpm runs as `www-data`. Laravel needs to write to `storage/` (logs, sessions, cache, compiled views) and `bootstrap/cache/` (package manifest, config cache) on every request. If `www-data` can't write there, Laravel throws a 500 error.

**chmod 775** — owner and group can read/write/execute, others can read/execute. The `7` = rwx, `5` = r-x.

```sh
nohup php-fpm > /dev/stdout 2>/dev/stderr &
```

**php-fpm** — starts the PHP FastCGI process manager. It forks worker processes and listens on port 9000.

**nohup** — "no hang up". Normally, when a terminal closes, processes receive SIGHUP and die. nohup makes the process ignore SIGHUP. Needed here because we're running in a script.

**> /dev/stdout** — redirect standard output to stdout (so Docker/Railway captures php-fpm logs).

**2>/dev/stderr** — redirect standard error to stderr.

**&** — run in the background. Without this, the script would block here and never start nginx.

```sh
nginx -g "daemon off;" > /dev/stdout 2>/dev/stderr
```

Starts nginx in the foreground (`daemon off`). By default nginx forks itself into the background and the parent process exits. In Docker, if the main process (PID 1) exits, the container stops. `daemon off` keeps nginx as the foreground process, keeping the container alive.

The container lives as long as this nginx process runs.

---

## docker-compose.yml

Used for **local development only**. Not used on Railway.

```yaml
version: '3.8'
```

Docker Compose file format version.

```yaml
services:
  app:
    build: .
```

**build: .** — build the image from the Dockerfile in the current directory (`.`). In production, we use a pre-built image from GHCR instead.

```yaml
    ports:
      - "8000:80"
```

Map host port 8000 to container port 80. Format is `host:container`. Access the app at `localhost:8000`. nginx inside the container listens on 80.

```yaml
    volumes:
      - .:/app
```

Mount the current directory into `/app` in the container. Changes to your local files are immediately reflected inside the container without rebuilding. Note: this overrides the files copied in during `docker build`.

```yaml
    environment:
      - APP_KEY=base64:8lmJ0B/O+zDV499+8HTczidROP1aP3pKDP/BmtbCT/k=
      - APP_DEBUG=true
```

Environment variables passed into the container. These override what's in `.env` inside the container.

---

## GitHub Actions Workflows

### deploy.yml

Triggers on every push to `main`.

```yaml
on:
  push:
    branches:
      - main
```

**on** — defines what event triggers this workflow. `push` to `main` only.

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      packages: write
      contents: read
```

**runs-on** — which GitHub-hosted runner to use. `ubuntu-latest` is a fresh Ubuntu VM spun up for each run.

**permissions** — by default the `GITHUB_TOKEN` has limited permissions. `packages: write` is required to push images to GHCR (GitHub Container Registry). `contents: read` is needed to checkout the code.

```yaml
    steps:
      - uses: actions/checkout@v3
```

**uses** — runs a pre-built action. `actions/checkout@v3` clones your repository into the runner. Without this, the runner has no code.

```yaml
      - name: Login to GHCR
        run: echo "${{ secrets.GITHUB_TOKEN }}" | docker login ghcr.io -u "${{ github.repository_owner }}" --password-stdin
```

**secrets.GITHUB_TOKEN** — automatically provided by GitHub Actions for every run. Scoped to the repository. Used here to authenticate with GHCR.

**github.repository_owner** — a built-in context variable. Resolves to `nurazimzahurin`.

**--password-stdin** — reads the password from stdin instead of as a flag. Safer — password doesn't appear in process list or logs.

```yaml
      - name: Build image
        run: |
          docker build \
            -t ghcr.io/${{ github.repository_owner }}/deploy-demo:${{ github.sha }} \
            -t ghcr.io/${{ github.repository_owner }}/deploy-demo:latest \
            .
```

**docker build** — builds the Docker image from the Dockerfile in `.`.

**-t** — tag the image. We tag it twice:
- `:<sha>` — the exact commit SHA. Immutable. Used for rollbacks.
- `:latest` — always points to the most recent build.

**github.sha** — the full Git commit SHA that triggered this workflow run.

```yaml
      - name: Push image
        run: |
          docker push ghcr.io/${{ github.repository_owner }}/deploy-demo:${{ github.sha }}
          docker push ghcr.io/${{ github.repository_owner }}/deploy-demo:latest
```

Pushes both tags to GHCR. After this step, the image is publicly available (or privately, depending on your GHCR settings).

```yaml
  deploy:
    runs-on: ubuntu-latest
    needs: build
    environment: production
```

**needs: build** — this job only starts after the `build` job succeeds. If build fails, deploy never runs.

**environment: production** — links this job to a GitHub environment. You can add protection rules here (required reviewers, wait timers). GitHub records each deployment against this environment.

```yaml
      - name: Update Railway image tag
        run: |
          curl -X POST \
            -H "Authorization: Bearer ${{ secrets.RAILWAY_TOKEN }}" \
            -H "Content-Type: application/json" \
            -d '{"query": "mutation { serviceInstanceUpdate(...) }"}' \
            https://backboard.railway.app/graphql/v2
```

Railway exposes a GraphQL API. We make two calls:
1. `serviceInstanceUpdate` — tells Railway which image tag to use for the next deploy
2. `serviceInstanceDeploy` — triggers the actual deploy

**secrets.RAILWAY_TOKEN** — stored in GitHub repo secrets. Never hardcoded in the workflow file.

---

### rollback.yml

```yaml
on:
  workflow_dispatch:
    inputs:
      image_tag:
        description: 'Commit SHA to rollback to'
        required: true
```

**workflow_dispatch** — manually triggered from the GitHub Actions UI. The `inputs` section adds a form field when you click "Run workflow". You paste in a previous commit SHA and Railway switches to that image.

This works because every deploy tags the image with the commit SHA. As long as GHCR hasn't deleted old images, any previous SHA is a valid rollback target.

---

### deploy-staging.yml

Identical structure to `deploy.yml` but:
- Triggers on push to `staging` branch
- Tags images as `staging-<sha>` and `staging`
- Uses the staging Railway environment ID
- Uses the `staging` GitHub environment

```yaml
on:
  push:
    branches:
      - staging
```

Only pushes to the `staging` branch trigger this workflow. `main` pushes still only trigger `deploy.yml`.

---

## railway.toml

Railway reads this file from the root of your repo on every deploy.

```toml
[deploy]
healthcheckPath = "/healthz"
healthcheckTimeout = 30

[[services]]
internalPort = 80
```

**healthcheckPath** — after the container starts, Railway sends a GET request to this path. If it gets a 200 response within the timeout, the deploy is marked successful. If not, the deploy is marked failed and Railway does not route traffic to it.

**healthcheckTimeout** — how many seconds Railway waits for the health check to pass.

**internalPort** — tells Railway which port inside the container to route external traffic to. Matches the `EXPOSE 80` in the Dockerfile and the `listen 80` in nginx config.

---

## The Full Deploy Flow

```
1. You push a commit to main
         |
2. GitHub Actions triggers deploy.yml
         |
3. Runner checks out code, logs into GHCR
         |
4. Docker builds the image (multi-stage)
   - Stage 1: composer install
   - Stage 2: copy app + vendor, install nginx, copy conf files
         |
5. Image pushed to GHCR with two tags:
   ghcr.io/nurazimzahurin/deploy-demo:<sha>
   ghcr.io/nurazimzahurin/deploy-demo:latest
         |
6. Railway API call: update service to use :<sha> image
         |
7. Railway API call: trigger deploy
         |
8. Railway pulls the image from GHCR
         |
9. Railway starts the container
   - entrypoint.sh runs
   - chown/chmod storage dirs
   - php-fpm starts (background)
   - nginx starts (foreground)
         |
10. Railway probes GET /healthz
    - nginx receives it
    - passes to php-fpm
    - Laravel returns {"status":"ok"}
    - Railway marks deploy successful
         |
11. Traffic routes to the new container
```

---

## The Staging Flow

```
feature branch
     |
     | merge
     v
  staging branch  →  deploy-staging.yml  →  Railway staging environment
     |
     | test here
     | merge
     v
   main branch    →  deploy.yml          →  Railway production environment
```

You never merge directly to `main` without testing on staging first. If staging breaks, production is safe.

---

## Rollback

When a bad deploy reaches production:

```
1. Find the last good commit SHA:
   git log --oneline

2. GitHub → Actions → Rollback → Run workflow
   Enter the SHA

3. Railway updates the service to use that image tag
4. Railway redeploys from that old image

5. Site is back to the previous version
```

Rollback is fast because the old image already exists in GHCR — no rebuild needed. Railway just switches which image it runs.
