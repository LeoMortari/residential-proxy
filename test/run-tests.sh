#!/usr/bin/env bash
set -u

PROXY_HOST="${PROXY_HOST:?defina PROXY_HOST}"
PROXY_USER="${PROXY_USER:?defina PROXY_USER}"
PROXY_PASSWORD="${PROXY_PASSWORD:?defina PROXY_PASSWORD}"
HTTP_PORT="${HTTP_PORT:-8888}"
SOCKS_PORT="${SOCKS_PORT:-1080}"
DOCKER_NETWORK="${DOCKER_NETWORK:-bridge}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:8.7.1}"
CANARY_IP="${CANARY_IP:-}"
EXPECT_DIFFERENT_IP="${EXPECT_DIFFERENT_IP:-1}"
LAN_TARGETS="${LAN_TARGETS:-}"

HTTP_PROXY_URL="http://${PROXY_HOST}:${HTTP_PORT}"
CRED="${PROXY_USER}:${PROXY_PASSWORD}"
SOCKS_URL="${CRED}@${PROXY_HOST}:${SOCKS_PORT}"
PASS=0
FAIL=0

c() {
  if [ "${CURL_MODE:-docker}" = native ]; then
    curl -s --connect-timeout 8 --max-time 25 "$@" 2>/dev/null
  else
    docker run --rm --network "$DOCKER_NETWORK" "$CURL_IMAGE" -s --connect-timeout 8 --max-time 25 "$@" 2>/dev/null
  fi
}
code() { c -o /dev/null -w "%{http_code}" "$@"; }
ok() { echo "PASS  $*"; PASS=$((PASS + 1)); }
bad() { echo "FAIL  $*"; FAIL=$((FAIL + 1)); }
expect() { if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1 (esperado $2, obtido $3)"; fi; }

expect "sem credencial HTTP" 407 "$(code -x "$HTTP_PROXY_URL" http://example.com/)"
expect "credencial errada HTTP" 407 "$(code -x "$HTTP_PROXY_URL" -U bad:bad http://example.com/)"
expect "HTTP:80 com credencial" 200 "$(code -x "$HTTP_PROXY_URL" -U "$CRED" http://example.com/)"
expect "HTTPS CONNECT:443 com credencial" 200 "$(code -x "$HTTP_PROXY_URL" -U "$CRED" https://example.com/)"
expect "SOCKS5h:443 com credencial" 200 "$(code --socks5-hostname "$SOCKS_URL" https://example.com/)"

socks_noauth=$(code --socks5-hostname "${PROXY_HOST}:${SOCKS_PORT}" https://example.com/)
[ "$socks_noauth" != 200 ] && ok "SOCKS5 sem credencial recusado" || bad "SOCKS5 aceitou sem credencial"
socks_badauth=$(code --socks5-hostname "bad:bad@${PROXY_HOST}:${SOCKS_PORT}" https://example.com/)
[ "$socks_badauth" != 200 ] && ok "SOCKS5 credencial errada recusado" || bad "SOCKS5 aceitou credencial errada"

direct_ip=$(c https://api.ipify.org)
proxy_ip=$(c -x "$HTTP_PROXY_URL" -U "$CRED" https://api.ipify.org)
socks_ip=$(c --socks5-hostname "$SOCKS_URL" https://api.ipify.org)
echo "INFO  IP direto deste cliente : ${direct_ip:-?}"
echo "INFO  IP de saida via HTTP    : ${proxy_ip:-?}"
echo "INFO  IP de saida via SOCKS5  : ${socks_ip:-?}"
if [ -z "$proxy_ip" ]; then
  bad "saida pelo proxy vazia"
elif [ "$EXPECT_DIFFERENT_IP" = 1 ]; then
  if [ "$proxy_ip" != "$direct_ip" ]; then ok "saida pelo proxy difere do IP direto"; else bad "saida pelo proxy igual ao IP direto"; fi
else
  echo "INFO  comparacao de IP desativada (EXPECT_DIFFERENT_IP=0)"
fi
[ "$proxy_ip" = "$socks_ip" ] && ok "HTTP e SOCKS5 saem pelo mesmo IP" || bad "HTTP e SOCKS5 saem por IPs diferentes"

headers=$(c -x "$HTTP_PROXY_URL" -U "$CRED" http://httpbin.org/headers)
if echo "$headers" | grep -qiE 'x-forwarded|"via"|forwarded|proxy-'; then bad "cabecalho de proxy/encaminhamento vaza em HTTP puro"; else ok "sem Via/Forwarded/X-Forwarded-For em HTTP puro"; fi

not_reached() {
  local out="$1"
  case "$out" in *"$2"*) return 1 ;; *) return 0 ;; esac
}

if [ -n "$CANARY_IP" ]; then
  direct_marker=$(c "http://${CANARY_IP}/")
  if [ -z "$direct_marker" ]; then
    bad "controle: canario ${CANARY_IP} nao responde direto, teste de bypass invalido"
  else
    ok "controle: canario ${CANARY_IP} responde direto (${direct_marker:0:20})"
    dec=$(awk -F. '{print ($1*16777216)+($2*65536)+($3*256)+$4}' <<<"$CANARY_IP")
    hex=$(awk -F. '{printf "0x%02x%02x%02x%02x", $1,$2,$3,$4}' <<<"$CANARY_IP")
    oct=$(awk -F. '{printf "0%o.0%o.0%o.0%o", $1,$2,$3,$4}' <<<"$CANARY_IP")
    mapped_hex=$(awk -F. '{printf "%02x%02x:%02x%02x", $1,$2,$3,$4}' <<<"$CANARY_IP")
    dashed=$(tr . - <<<"$CANARY_IP")
    forms=("$CANARY_IP" "$dec" "$hex" "$oct" "[::ffff:${CANARY_IP}]" "[::ffff:${mapped_hex}]" "${dashed}.nip.io" "${dashed}.sslip.io")
    leaks=0
    for f in "${forms[@]}"; do
      b1=$(c -x "$HTTP_PROXY_URL" -U "$CRED" "http://${f}/")
      b2=$(c -x "$HTTP_PROXY_URL" -U "$CRED" --proxytunnel "http://${f}/")
      b3=$(c --socks5-hostname "$SOCKS_URL" "http://${f}/")
      if ! not_reached "$b1$b2$b3" "$direct_marker"; then leaks=$((leaks + 1)); bad "BYPASS: canario alcancado via ${f}"; fi
    done
    [ "$leaks" = 0 ] && ok "canario privado inalcancavel em ${#forms[@]} formas de endereco, em HTTP, CONNECT e SOCKS5"
  fi
else
  echo "INFO  CANARY_IP nao definido: teste de bypass por IP privado nao executado"
fi

for t in 127.0.0.1 localhost 169.254.169.254 100.100.100.100 10.0.0.1 192.168.0.1 172.17.0.1 localtest.me 127.0.0.1.nip.io '[::1]' ${LAN_TARGETS}; do
  r1=$(code -x "$HTTP_PROXY_URL" -U "$CRED" "http://${t}/")
  r2=$(code -x "$HTTP_PROXY_URL" -U "$CRED" --proxytunnel "http://${t}/")
  r3=$(code --socks5-hostname "$SOCKS_URL" "http://${t}/")
  case "$r1" in 403 | 000 | 502) ;; *) bad "HTTP http://${t}/ retornou ${r1}"; continue ;; esac
  case "$r2" in 000 | 403 | 502) ;; *) bad "CONNECT http://${t}/ retornou ${r2}"; continue ;; esac
  case "$r3" in 000) ;; *) bad "SOCKS5 http://${t}/ retornou ${r3}"; continue ;; esac
  ok "destino privado negado: ${t} (http=${r1} connect=${r2} socks=${r3})"
done

direct_8080=$(code http://portquiz.net:8080/)
if [ "$direct_8080" = 200 ]; then
  for port in 22 25 3306 8080; do
    r1=$(code -x "$HTTP_PROXY_URL" -U "$CRED" "http://portquiz.net:${port}/")
    r2=$(code -x "$HTTP_PROXY_URL" -U "$CRED" --proxytunnel "http://portquiz.net:${port}/")
    r3=$(code --socks5-hostname "$SOCKS_URL" "http://portquiz.net:${port}/")
    if [ "$r1" = 200 ] || [ "$r2" = 200 ] || [ "$r3" = 200 ]; then bad "porta ${port} permitida (http=${r1} connect=${r2} socks=${r3})"; else ok "porta ${port} negada (http=${r1} connect=${r2} socks=${r3})"; fi
  done
else
  echo "INFO  portquiz.net:8080 inacessivel direto (${direct_8080}): teste de portas proibidas nao executado"
fi

tmp=$(mktemp)
for i in $(seq 1 30); do
  ( printf '%s
' "$(code -x "$HTTP_PROXY_URL" -U "$CRED" https://example.com/)" >>"$tmp" ) &
done
wait
n=$(grep -c '^200$' "$tmp")
rm -f "$tmp"
expect "30 conexoes HTTPS concorrentes" 30 "$n"

start=$(date +%s%N)
code -x "$HTTP_PROXY_URL" -U "$CRED" https://example.com/ >/dev/null
end=$(date +%s%N)
echo "INFO  latencia de uma requisicao HTTPS via proxy: $(((end - start) / 1000000)) ms"

echo "RESULTADO: PASS=${PASS} FAIL=${FAIL}"
[ "$FAIL" = 0 ]
