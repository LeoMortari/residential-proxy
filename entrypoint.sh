#!/bin/sh
set -eu

if [ -z "${PROXY_USER:-}" ] || [ -z "${PROXY_PASSWORD:-}" ]; then
  echo "ERRO: PROXY_USER e PROXY_PASSWORD sao obrigatorios." >&2
  exit 1
fi

for value in "$PROXY_USER" "$PROXY_PASSWORD"; do
  case "$value" in
    *[!A-Za-z0-9._~-]*) invalid=1 ;;
    *) invalid=0 ;;
  esac
  if [ "$invalid" = 1 ] || [ "${#value}" -lt 8 ] || [ "${#value}" -gt 128 ]; then
    echo "ERRO: PROXY_USER e PROXY_PASSWORD aceitam apenas A-Z a-z 0-9 . _ ~ - (8 a 128 caracteres)." >&2
    exit 1
  fi
done

CONFIG_FILE="/tmp/3proxy.cfg"

cat <<EOF > "$CONFIG_FILE"
nserver 1.1.1.1
nserver 8.8.8.8
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
maxconn 500

log /var/log/3proxy/3proxy.log D
logformat "L%t.%. %N.%p %E %U %C:%c %R:%r %O %I %h %T"
archiver gz /bin/gzip -f
rotate 7

auth strong
users ${PROXY_USER}:CL:${PROXY_PASSWORD}

deny * * 127.0.0.0/8
deny * * ::1
deny * * 10.0.0.0/8
deny * * 172.16.0.0/12
deny * * 192.168.0.0/16
deny * * 169.254.0.0/16
deny * * 100.64.0.0/10
deny * * 0.0.0.0/8
deny * * ::/0
deny * * localhost,*.localhost

allow * * * 80,443
deny *

proxy -p8888 -a
socks -p1080
EOF

chmod 400 "$CONFIG_FILE"

exec 3proxy "$CONFIG_FILE"
