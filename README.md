# Residential Proxy

Proxy de saída (3proxy) para rodar num servidor da sua rede de casa e fazer o tráfego de outra máquina (por exemplo, um servidor na nuvem) sair pelo IP residencial, como um proxy residencial contratado. Fala HTTP/HTTPS (CONNECT) na `8888` e SOCKS5 na `1080`, com a mesma credencial. Roda em arm64 e amd64 (3proxy 0.9.4 compilado da fonte, versão e sha256 fixados no `Dockerfile`).

```
cliente (browser/scraper na nuvem) --rede privada--> proxy (sua casa, este container) --internet--> destino (vê o IP de casa)
```

A rede privada entre as duas pontas pode ser uma VPN mesh como a Tailscale ou WireGuard. O proxy foi pensado para ser alcançável **só por ela**.

> **Aviso:** nunca exponha as portas do proxy na internet pública. Um proxy com acesso aberto é abusado em minutos. O compose recusa subir sem `BIND_ADDR`, e a credencial é só a segunda barreira.

## Subir

Requisitos: Docker com Compose e um IP privado do host para publicar as portas (por exemplo, o IP da Tailscale).

```bash
cp .env.example .env
```

Preencha o `.env`:

```
BIND_ADDR=<IP privado do host, ex.: o IP da VPN/Tailscale>
PROXY_USER=<usuário>
PROXY_PASSWORD=<senha, gere com: openssl rand -hex 16>
```

```bash
docker compose up -d --build
docker compose ps
```

- `BIND_ADDR` é obrigatório. As portas nunca são publicadas em `0.0.0.0`.
- Usuário e senha ficam vazios no `.env.example` de propósito: o container recusa subir sem eles. Aceitam só `A-Z a-z 0-9 . _ ~ -`, de 8 a 128 caracteres (impede injeção de linhas no `3proxy.cfg`).
- O `.env` está no `.gitignore`. Nunca versione credenciais.
- O build compila o 3proxy e imprime um erro em `transparent_plugin.c`: é um plugin opcional que não é usado, o binário principal compila normalmente.

## Cliente (Camoufox / Playwright)

Use HTTP na `8888`. O SOCKS5 com usuário e senha não é confiável em todos os navegadores.

```python
proxy = {"server": "http://<BIND_ADDR>:8888", "username": "<usuário>", "password": "<senha>"}
with Camoufox(headless=True, proxy=proxy) as browser:
    page = browser.new_page()
    page.goto("https://api.ipify.org")
```

O DNS é resolvido no proxy (HTTP CONNECT sempre; no SOCKS5 use `socks5h://`).

## Testes

Rode a partir da máquina cliente, que é a que deve sair pelo IP residencial:

```bash
PROXY_HOST=<BIND_ADDR> PROXY_USER=<usuário> PROXY_PASSWORD=<senha> bash test/run-tests.sh
```

Variáveis opcionais:

- `CURL_MODE=native`: usa o `curl` do host em vez de um container (cliente sem acesso ao Docker).
- `DOCKER_NETWORK`: rede Docker do cliente (padrão `bridge`).
- `CANARY_IP`: IP privado de um servidor HTTP que responde ao cliente. O teste tenta alcançá-lo pelo proxy em 8 formas de endereço (pontilhado, decimal, hex, octal, IPv6 mapeado em duas notações, `nip.io`, `sslip.io`) por HTTP, CONNECT e SOCKS5. Qualquer resposta é bypass.
- `LAN_TARGETS`: IPs extras da sua LAN que devem ser negados (ex.: o roteador).
- `EXPECT_DIFFERENT_IP=0`: desativa a exigência de que o IP de saída seja diferente do IP direto (use quando cliente e proxy estão na mesma máquina).

O script valida 407 sem credencial e com credencial errada, HTTP, CONNECT e SOCKS5 funcionando, IP de saída diferente do IP direto, ausência de `Via`/`Forwarded`/`X-Forwarded-For`, negação de destinos privados e de portas fora de 80/443, bypass por canário, 30 conexões concorrentes e a latência de uma requisição.

## Segurança

O proxy não pode virar porta de entrada para a sua rede de casa. O ACL nega, depois de resolver o nome, loopback, RFC 1918, `169.254.0.0/16` (metadata de nuvem), `100.64.0.0/10` (CGNAT/Tailscale) e `0.0.0.0/8`, e libera só destino nas portas 80 e 443.

- **IPv6 é negado por completo** (`deny * * ::/0`). Sem isso, no SOCKS5 um endereço IPv6 mapeado como `::ffff:192.168.0.1` escapava do ACL de IPv4 e alcançava a rede privada (reproduzido com um canário antes da correção). O egress sai por IPv4.
- `proxy -a`: o 3proxy deixa de injetar `Forwarded: for=<IP do cliente>` nas requisições HTTP puras. Em HTTPS (CONNECT) o conteúdo já é um túnel.
- Container: usuário `10001`, `read_only`, `cap_drop: ALL`, `no-new-privileges`, 64 MB e 0,5 CPU, `tmpfs` para `/tmp` e logs, healthcheck, logs sem senha. Medido em um SBC arm64: cerca de 3 MiB de RAM.
- A senha vem do `.env` (fora do git) e é gravada só no `tmpfs`, nunca em disco.
- A credencial é a segunda barreira. A primeira é a rede privada: restrinja por ACL da própria VPN para que só a máquina cliente alcance as portas `8888` e `1080`.

## Limitações

- Só portas 80 e 443 de destino e só IPv4.
- O DNS usa `1.1.1.1` e `8.8.8.8`, não o resolvedor do seu provedor.
- Um IP residencial reduz, mas não elimina, desafios anti-bot. O teste automatizado prova que o tráfego sai pelo IP de casa, não o efeito em um site específico.
- Use só para tráfego seu e respeitando os termos dos sites de destino.
