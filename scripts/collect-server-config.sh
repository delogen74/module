#!/usr/bin/env bash
# Сбор конфигурации рабочего сервера ОЗОН коннектора.
#
# Только читает систему, ничего не меняет. Значения переменных окружения и
# похожие на секреты строки заменяются на ***, остаются только имена.
# Результат: архив /tmp/ozon-config-<host>-<дата>.tar.gz
#
# Запуск (лучше от root, иначе часть данных будет недоступна):
#   sudo bash collect-server-config.sh
# Дополнительные каталоги для поиска кода можно передать аргументами:
#   sudo bash collect-server-config.sh /data/apps /home/deploy/ozon

set -u
export LC_ALL=C

HOST=$(hostname -s 2>/dev/null || echo host)
OUT="/tmp/ozon-config-${HOST}-$(date +%Y%m%d-%H%M)"
mkdir -p "$OUT"
chmod 700 "$OUT"

SEARCH_DIRS=(/opt /srv /var/www /home /root /usr/local/src /usr/local/bin "$@")
APP_PATTERN='ozon|seller|mcp|connector|коннектор'

have() { command -v "$1" >/dev/null 2>&1; }

# Маскирует значения секретов в произвольном тексте.
sanitize() {
  sed -E \
    -e 's/(Bearer[[:space:]]+)[A-Za-z0-9._~+\/=-]+/\1***/Ig' \
    -e 's/((api[_-]?key|client[_-]?id|client[_-]?secret|secret|token|passw(or)?d|pwd|auth|authorization|bearer|private[_-]?key|dsn|database_url|cookie)[A-Za-z0-9_-]*["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?)[^"'"'"'[:space:];,]+/\1***/Ig' \
    -e 's#(://[^:/@[:space:]]+:)[^@[:space:]]+@#\1***@#g'
}

# Оставляет только имена переменных из строк вида KEY=value.
env_keys() {
  sed -E -n \
    -e 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=.*/\2=***/p'
}

# Выполняет команду, пишет вывод (с маскировкой) в файл.
run() {
  local file="$1"; shift
  {
    echo "### $*"
    "$@" 2>&1
  } | sanitize >>"$OUT/$file"
  echo >>"$OUT/$file"
}

echo "Сбор в $OUT ..."

# 1. ОС и железо
run 01-os.txt cat /etc/os-release
run 01-os.txt uname -a
have hostnamectl && run 01-os.txt hostnamectl
have timedatectl && run 01-os.txt timedatectl
run 01-os.txt locale
run 01-os.txt nproc
run 01-os.txt free -h
run 01-os.txt df -hT -x tmpfs -x devtmpfs -x overlay
run 01-os.txt id

# 2. Пакеты и рантаймы
if have dpkg-query; then
  dpkg-query -W -f='${Package}\t${Version}\n' >"$OUT/02-packages-all.tsv" 2>/dev/null
  have apt-mark && apt-mark showmanual >"$OUT/02-packages-manual.txt" 2>/dev/null
  ls /etc/apt/sources.list.d/ >"$OUT/02-apt-sources.txt" 2>&1
  grep -hEv '^\s*(#|$)' /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources 2>/dev/null | sanitize >>"$OUT/02-apt-sources.txt"
elif have rpm; then
  rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}\n' | sort >"$OUT/02-packages-all.tsv"
fi
for c in python3 python pip3 node npm npx pm2 yarn pnpm bun deno go java php composer ruby \
         docker podman nginx caddy apache2 httpd psql postgres mysql mariadb redis-server \
         sqlite3 certbot git uv poetry pipx supervisord; do
  if have "$c"; then
    case "$c" in
      go) v=$(go version 2>&1) ;;
      java) v=$(java -version 2>&1 | head -1) ;;
      nginx) v=$(nginx -v 2>&1) ;;
      psql|postgres|mysql|mariadb|redis-server|sqlite3|certbot|supervisord) v=$("$c" --version 2>&1 | head -1) ;;
      *) v=$("$c" --version 2>&1 | head -1) ;;
    esac
    printf '%-14s %-40s %s\n' "$c" "$(command -v "$c")" "$v" >>"$OUT/02-runtimes.txt"
  fi
done
have pip3 && run 02-pip-global.txt pip3 list --format=freeze
have npm && run 02-npm-global.txt npm ls -g --depth=0

# 3. Сервисы systemd
if have systemctl; then
  run 03-systemd-running.txt systemctl list-units --type=service --state=running --no-pager
  run 03-systemd-enabled.txt systemctl list-unit-files --state=enabled --no-pager
  run 03-systemd-timers.txt systemctl list-timers --all --no-pager
  mkdir -p "$OUT/systemd"
  # Юниты, созданные вручную (не из пакетов): /etc/systemd/system и пользовательские.
  find /etc/systemd/system /home/*/.config/systemd/user /root/.config/systemd/user \
       -maxdepth 2 -type f \( -name '*.service' -o -name '*.timer' -o -name '*.socket' -o -name '*.path' -o -name '*.conf' \) 2>/dev/null |
  while read -r f; do
    dest="$OUT/systemd/$(echo "$f" | sed 's#^/##; s#/#__#g')"
    sed -E '/^Environment=/ {
      s/^Environment=//
      s/"([A-Za-z_][A-Za-z0-9_]*)=[^"]*"/"\1=***"/g
      s/(^|[[:space:]])([A-Za-z_][A-Za-z0-9_]*)=[^[:space:]"]*/\1\2=***/g
      s/^/Environment=/
    }' "$f" | sanitize >"$dest"
  done
  # EnvironmentFile: только имена переменных.
  grep -rhoE '^EnvironmentFile=-?[^ ]+' /etc/systemd/system 2>/dev/null | sed -E 's/^EnvironmentFile=-?//' | sort -u |
  while read -r ef; do
    [ -f "$ef" ] || continue
    { echo "### $ef"; env_keys <"$ef"; echo; } >>"$OUT/05-env-keys.txt"
  done
fi

# 4. Cron
{
  echo "### /etc/crontab"; grep -Ev '^\s*(#|$)' /etc/crontab 2>/dev/null
  for f in /etc/cron.d/*; do [ -f "$f" ] && { echo "### $f"; grep -Ev '^\s*(#|$)' "$f"; }; done
  for d in /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly; do echo "### $d"; ls "$d" 2>/dev/null; done
  for u in $(cut -d: -f1 /etc/passwd); do
    c=$(crontab -l -u "$u" 2>/dev/null | grep -Ev '^\s*(#|$)')
    [ -n "$c" ] && { echo "### crontab пользователя $u"; echo "$c"; }
  done
} 2>/dev/null | sanitize >"$OUT/04-cron.txt"

# 5. Веб-сервер и сертификаты
if have nginx; then
  run 06-nginx.txt nginx -V
  nginx -T 2>/dev/null | sanitize >"$OUT/06-nginx-full.conf"
fi
if have caddy && [ -f /etc/caddy/Caddyfile ]; then sanitize </etc/caddy/Caddyfile >"$OUT/06-Caddyfile"; fi
if have apache2ctl; then run 06-apache.txt apache2ctl -S; fi
have certbot && run 06-certbot.txt certbot certificates
ls -la /etc/letsencrypt/live 2>/dev/null >>"$OUT/06-certbot.txt"

# 6. Сеть
have ss && run 07-network.txt ss -tlnp
have ufw && run 07-network.txt ufw status verbose
have firewall-cmd && run 07-network.txt firewall-cmd --list-all
have iptables && run 07-network.txt iptables -S
run 07-network.txt cat /etc/hosts

# 7. Процессы приложения и их окружение (только имена переменных)
ps -eo pid,user,etime,rss,args --sort=-rss 2>/dev/null | grep -Ei "$APP_PATTERN|python|node|gunicorn|uvicorn|java|php|bun|deno|docker-proxy" | grep -v grep | sanitize >"$OUT/08-processes.txt"
for pid in $(ps -eo pid,args 2>/dev/null | grep -Ei "$APP_PATTERN|python|node|gunicorn|uvicorn|bun|deno" | grep -v grep | awk '{print $1}'); do
  [ -r "/proc/$pid/environ" ] || continue
  {
    echo "### PID $pid: $(tr '\0' ' ' </proc/$pid/cmdline | sanitize | cut -c1-200)"
    echo "cwd: $(readlink /proc/$pid/cwd)"
    tr '\0' '\n' </proc/$pid/environ | env_keys | grep -Ev '^(PATH|HOME|LANG|LC_[A-Z]+|TERM|SHELL|USER|LOGNAME|PWD|SHLVL|OLDPWD|_|INVOCATION_ID|JOURNAL_STREAM|SYSTEMD_EXEC_PID|MANAGERPID|XDG_[A-Z_]+|MAIL|SSH_[A-Z_]+|HOSTNAME|LS_COLORS)='
    echo
  } >>"$OUT/05-env-keys.txt"
done

# 8. Docker / pm2 / supervisor
if have docker; then
  run 09-docker.txt docker version
  run 09-docker.txt docker ps -a
  run 09-docker.txt docker images
  run 09-docker.txt docker volume ls
  run 09-docker.txt docker network ls
  docker compose ls >>"$OUT/09-docker.txt" 2>&1
  for c in $(docker ps -q 2>/dev/null); do
    {
      echo "### контейнер $(docker inspect -f '{{.Name}} {{.Config.Image}}' "$c")"
      docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$c" | env_keys
      docker inspect -f 'mounts: {{range .Mounts}}{{.Source}}->{{.Destination}} {{end}}' "$c"
      docker inspect -f 'ports: {{json .NetworkSettings.Ports}}' "$c"
      docker inspect -f 'restart: {{.HostConfig.RestartPolicy.Name}}  compose: {{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$c"
      echo
    } >>"$OUT/09-docker-containers.txt" 2>&1
  done
fi
if have pm2; then
  run 09-pm2.txt pm2 ls
  pm2 jlist 2>/dev/null | python3 -c 'import json,sys
for p in json.load(sys.stdin):
    e=p.get("pm2_env",{}); print(p.get("name"), e.get("pm_exec_path"), e.get("pm_cwd"), e.get("exec_interpreter"), sorted((e.get("env") or {}).keys()))' >>"$OUT/09-pm2.txt" 2>&1
fi
[ -d /etc/supervisor ] && find /etc/supervisor -type f -name '*.conf' -exec sh -c 'echo "### $1"; cat "$1"' _ {} \; | sanitize >"$OUT/09-supervisor.txt"

# 9. Код приложения: где лежит, какая версия, какие файлы конфигурации
{
  for d in "${SEARCH_DIRS[@]}"; do
    [ -d "$d" ] || continue
    find "$d" -maxdepth 5 -name .git -type d -not -path '*/node_modules/*' 2>/dev/null
  done | sort -u | while read -r g; do
    r=$(dirname "$g")
    echo "### $r"
    git -C "$r" remote -v 2>/dev/null | sanitize | head -2
    git -C "$r" log -1 --format='commit %H %cd %s' 2>/dev/null
    git -C "$r" branch --show-current 2>/dev/null
    echo "-- незакоммиченные изменения:"
    git -C "$r" status --short 2>/dev/null | head -50
    echo
  done
} >"$OUT/10-app-repos.txt" 2>&1

{
  echo "### каталоги с упоминанием ozon/seller/mcp"
  for d in "${SEARCH_DIRS[@]}"; do
    [ -d "$d" ] || continue
    find "$d" -maxdepth 4 -type d -iregex ".*\(ozon\|seller\|mcp\|connector\).*" -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/site-packages/*' 2>/dev/null
  done | sort -u
} >"$OUT/10-app-dirs.txt"

{
  for d in "${SEARCH_DIRS[@]}"; do
    [ -d "$d" ] || continue
    find "$d" -maxdepth 5 -type f \( -name '.env' -o -name '.env.*' -o -name '*.env' -o -name 'config.json' -o -name 'config.yaml' -o -name 'config.yml' -o -name 'settings.*' -o -name '*.toml' -o -name 'docker-compose*.yml' -o -name 'compose*.yaml' -o -name 'ecosystem.config.*' -o -name 'requirements*.txt' -o -name 'package.json' -o -name 'pyproject.toml' -o -name '*.sqlite*' -o -name '*.db' \) \
      -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/site-packages/*' -not -path '*/.cache/*' -not -path '*/.npm/*' 2>/dev/null
  done | sort -u | while read -r f; do
    echo "$(stat -c '%U:%G %a %s' "$f" 2>/dev/null)  $f"
  done
} >"$OUT/10-app-config-files.txt"

# Имена переменных из .env-файлов приложения.
grep -E '/\.env|\.env$|/[^/]*\.env\.' "$OUT/10-app-config-files.txt" | awk '{print $NF}' | while read -r ef; do
  { echo "### $ef"; env_keys <"$ef"; echo; } >>"$OUT/05-env-keys.txt"
done

# Python-окружения рядом с кодом: список зависимостей.
for d in "${SEARCH_DIRS[@]}"; do
  [ -d "$d" ] || continue
  find "$d" -maxdepth 5 -type f -name pyvenv.cfg -not -path '*/node_modules/*' 2>/dev/null
done | sort -u | while read -r cfg; do
  v=$(dirname "$cfg")
  { echo "### $v"; cat "$cfg"; "$v/bin/python" -m pip list --format=freeze 2>&1; echo; } >>"$OUT/10-app-venvs.txt"
done

# 10. Базы данных (только список баз и размеры, без данных)
if have psql && id postgres >/dev/null 2>&1; then
  (cd /tmp && su postgres -c "psql -At -c \"select datname, pg_size_pretty(pg_database_size(datname)) from pg_database where not datistemplate\"" ) >"$OUT/11-databases.txt" 2>&1
  (cd /tmp && su postgres -c "psql -At -c \"select rolname, rolcanlogin from pg_roles where rolname not like 'pg_%'\"" ) >>"$OUT/11-databases.txt" 2>&1
fi
if have mysql; then
  mysql -N -e 'show databases' >>"$OUT/11-databases.txt" 2>&1
fi
have redis-cli && redis-cli INFO server 2>&1 | grep -E 'redis_version|config_file' >>"$OUT/11-databases.txt"

# 11. Логи (последние строки сервисов приложения, с маскировкой)
if have journalctl; then
  systemctl list-units --type=service --state=running --no-legend --no-pager 2>/dev/null | awk '{print $1}' | grep -Ei "$APP_PATTERN" |
  while read -r u; do
    { echo "### $u"; journalctl -u "$u" -n 50 --no-pager 2>&1; echo; } | sanitize >>"$OUT/12-app-logs.txt"
  done
fi

# Упаковка
TAR="$OUT.tar.gz"
tar -czf "$TAR" -C "$(dirname "$OUT")" "$(basename "$OUT")"
chmod 600 "$TAR"
echo
echo "Готово: $TAR"
echo "Перед отправкой просмотрите файлы в $OUT — секреты маскируются автоматически, но проверка глазами не помешает."
