#!/bin/bash
# =============================================================================
#  LYRA CENTRAL API — DEPLOY (VPS própria da Nomen, não é por-cliente)
#  Não reinventa o deploy da Lyra: clona github.com/nomen-me/lyra e delega
#  pro scripts/install.sh QUE JÁ EXISTE nesse repo (systemd + Node, testado
#  por vocês). Este script só cobre o que faltava em volta disso:
#    - Node.js >= 20 e Redis instalados
#    - .env preenchido na primeira vez (preservado em reruns, como o
#      install.sh já faz)
#    - HTTPS público em <dominio> via Traefik, na frente do serviço systemd
#      (a API roda em 127.0.0.1:8080; nada mais fica exposto)
#
#  Uso:
#    export GITHUB_TOKEN=ghp_xxxxx     # PAT com acesso de leitura ao nomen-me/lyra
#    export GEMINI_API_KEY=xxxxx       # chave real do Google AI Studio / Vertex AI
#    sudo -E ./deploy_lyra_central.sh lyra.suaempresa.com
#
#  Variáveis opcionais:
#    ADMIN_API_KEY       se não vier, é gerada na primeira execução e salva
#                         em /root/lyra_central_credentials.txt (NÃO muda em
#                         reruns — trocar isso invalida os tenants já provisionados)
#    GEMINI_MODEL         default: gemini-2.5-flash
#    EMAIL                pro certificado Let's Encrypt (default: admin@<dominio sem o 1º label>)
#    APP_USER              default: ubuntu
#    APP_DIR                default: /home/ubuntu/lyra-central-api
#
#  ⚠️ Pré-requisito FORA do alcance deste script (ver docs/01_arquitetura.md
#  do próprio repo): projeto GCP com Vertex AI/Gemini habilitado e teto de
#  gastos configurado ANTES de gerar o GEMINI_API_KEY de produção.
#
#  Pra atualizações depois do primeiro deploy, use o scripts/deploy.sh que já
#  vem no próprio repo (git pull + npm ci + restart com rollback automático
#  se o healthcheck falhar) — não este script.
# =============================================================================
set -uo pipefail

DOMINIO_LYRA="${1:?Uso: sudo -E ./deploy_lyra_central.sh <dominio> (ex: lyra.suaempresa.com)}"
GITHUB_TOKEN="${GITHUB_TOKEN:?Exporte GITHUB_TOKEN antes de rodar (PAT com acesso de leitura a github.com/nomen-me/lyra)}"
GEMINI_API_KEY="${GEMINI_API_KEY:?Exporte GEMINI_API_KEY antes de rodar (chave real do Google AI Studio / Vertex AI)}"
GEMINI_MODEL="${GEMINI_MODEL:-gemini-2.5-flash}"
GITHUB_ORG="nomen-me"
APP_USER="${APP_USER:-ubuntu}"
APP_DIR="${APP_DIR:-/home/${APP_USER}/lyra-central-api}"
EMAIL="${EMAIL:-admin@${DOMINIO_LYRA#*.}}"
CRED_FILE="/root/lyra_central_credentials.txt"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[AVISO]${NC} $1"; }
err()  { echo -e "${RED}[ERRO]${NC} $1"; }
fatal(){ echo -e "${RED}[FATAL]${NC} $1"; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
  fatal "Este script precisa correr como root. Corre com 'sudo -E'."
fi

# Espera o dpkg/apt liberar — fica como rede de segurança extra depois de
# parar_unattended_upgrades() (abaixo), caso algo ainda segure o lock por
# um instante (ex: um processo filho que não morreu junto com o serviço).
esperar_apt_livre() {
  local tentativas=0
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
    tentativas=$((tentativas+1))
    if [ $tentativas -ge 60 ]; then
      warn "dpkg/apt ainda ocupado por outro processo depois de 5min — seguindo mesmo assim (pode falhar)."
      break
    fi
    log "apt/dpkg ocupado por outro processo (provavelmente unattended-upgrades) — aguardando... (${tentativas}/60)"
    sleep 5
  done
}

# Numa VPS recém-criada o unattended-upgrades pode ficar rodando (e se
# renovando) por bastante tempo, então só ESPERAR o lock liberar corre risco
# de ficar competindo com ele. Em vez disso, para a instância atual do
# serviço antes de mexer no apt — isso não desativa as atualizações
# automáticas permanentemente, só interrompe a execução em andamento; elas
# voltam a rodar no próximo agendamento/boot normalmente.
parar_unattended_upgrades() {
  systemctl stop unattended-upgrades 2>/dev/null || true
  systemctl stop apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
  systemctl kill --kill-who=all apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
}
parar_unattended_upgrades

# =============================================================================
# 1. SISTEMA BASE — Node.js >= 20, Redis, Docker (só pro Traefik), git
# =============================================================================
log "Atualizando sistema e instalando pré-requisitos..."
esperar_apt_livre
apt update && apt install -y curl git ufw redis-server unzip || fatal "Falha ao instalar pacotes base."

if ! command -v node >/dev/null 2>&1 || [ "$(node -v | sed 's/^v//' | cut -d. -f1)" -lt 20 ]; then
  log "Instalando Node.js 20 (NodeSource)..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - || fatal "Falha ao configurar o repositório NodeSource."
  esperar_apt_livre
  apt install -y nodejs || fatal "Falha ao instalar Node.js."
fi
ok "Node.js $(node -v) OK"

systemctl enable --now redis-server
if redis-cli ping >/dev/null 2>&1; then
  ok "Redis respondendo"
else
  fatal "Redis não respondeu a PING local — verifique 'systemctl status redis-server'."
fi

if ! command -v docker >/dev/null 2>&1; then
  log "Instalando Docker (só pro Traefik, a API em si roda via systemd)..."
  esperar_apt_livre
  curl -fsSL https://get.docker.com | sh || fatal "Falha ao instalar Docker."
  systemctl enable --now docker
fi
ok "Docker disponível: $(docker --version)"

log "Configurando firewall..."
ufw allow OpenSSH; ufw allow 80; ufw allow 443; ufw --force enable
ok "Firewall configurado (só 22/80/443 públicos — a API em 127.0.0.1:8080 não é exposta diretamente)"

# =============================================================================
# 2. CLONAR / ATUALIZAR github.com/nomen-me/lyra
# =============================================================================
if [ -d "${APP_DIR}/.git" ]; then
  log "Repositório já existe em ${APP_DIR} — atualizando (git pull --ff-only)..."
  if ! (cd "$APP_DIR" && sudo -u "$APP_USER" git pull --ff-only 2>&1 | sed "s|${GITHUB_TOKEN}|***|g"); then
    err "git pull falhou — verifique conflitos manualmente em ${APP_DIR}. Seguindo com o código já presente."
  fi
else
  log "Clonando github.com/${GITHUB_ORG}/lyra em ${APP_DIR}..."
  mkdir -p "$(dirname "$APP_DIR")"
  saida=$(git clone "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_ORG}/lyra.git" "$APP_DIR" 2>&1) \
    || { echo "$saida" | sed "s|${GITHUB_TOKEN}|***|g" >&2; fatal "Falha ao clonar github.com/${GITHUB_ORG}/lyra. Confirma se GITHUB_TOKEN tem acesso ao repositório."; }
  id -u "$APP_USER" >/dev/null 2>&1 && chown -R "${APP_USER}:${APP_USER}" "$APP_DIR"
fi
ok "Código da Lyra Central em ${APP_DIR}"

# O repo pode ter uma pasta extra por dentro (ex: se o clone local que virou
# o repo já nasceu com um subdiretório "lyra-central-api/" e isso foi
# commitado assim). Em vez de assumir "scripts/install.sh" direto na raiz,
# procuramos de verdade e corrigimos APP_DIR se precisar — mesma lógica
# usada pra achar o pyproject.toml do brazil-nf.
if [ ! -f "${APP_DIR}/scripts/install.sh" ]; then
  warn "scripts/install.sh não está direto em ${APP_DIR} — procurando dentro do repositório..."
  FOUND_INSTALL="$(find "$APP_DIR" -maxdepth 4 -path '*/scripts/install.sh' 2>/dev/null | head -1)"

  # Fallback: o repo às vezes tem só um .zip cru subido ("Add files via
  # upload"), sem o código extraído/commitado de verdade. Se for o caso,
  # extrai aqui mesmo em vez de travar a operação — mas isso é só uma
  # muleta; o certo é a Nomen commitar os arquivos extraídos no repo.
  if [ -z "$FOUND_INSTALL" ]; then
    ZIP_ENCONTRADO="$(find "$APP_DIR" -maxdepth 2 -name '*.zip' -not -path '*/.git/*' 2>/dev/null | head -1)"
    if [ -n "$ZIP_ENCONTRADO" ]; then
      warn "Não achei código extraído, mas achei '${ZIP_ENCONTRADO}' — o repo parece ter só o .zip cru subido, sem commit dos arquivos de verdade. Extraindo automaticamente (isso é uma muleta; o certo é vocês commitarem os arquivos extraídos no repo, não o .zip)."
      if command -v unzip >/dev/null 2>&1 || apt install -y unzip >/dev/null 2>&1; then
        EXTRACT_TMP="$(mktemp -d)"
        unzip -o "$ZIP_ENCONTRADO" -d "$EXTRACT_TMP" >/dev/null 2>&1
        # Procura o scripts/install.sh DIRETO dentro do zip extraído, não
        # importa quantas pastas em volta existam (embrulho único, __MACOSX/
        # de zip feito em Mac, etc.) — evita a heurística frágil de "contar
        # itens no topo", que quebra com qualquer lixo extra no zip.
        INSTALL_NO_ZIP="$(find "$EXTRACT_TMP" -maxdepth 4 -path '*/scripts/install.sh' 2>/dev/null | head -1)"
        if [ -n "$INSTALL_NO_ZIP" ]; then
          RAIZ_REAL="$(dirname "$(dirname "$INSTALL_NO_ZIP")")"
          rm -rf "$APP_DIR"; mkdir -p "$APP_DIR"
          cp -a "${RAIZ_REAL}/." "$APP_DIR/"
        else
          cp -a "$EXTRACT_TMP/." "$APP_DIR/"
        fi
        rm -rf "$EXTRACT_TMP"
        FOUND_INSTALL="$(find "$APP_DIR" -maxdepth 4 -path '*/scripts/install.sh' 2>/dev/null | head -1)"
      fi
    fi
  fi

  if [ -n "$FOUND_INSTALL" ]; then
    APP_DIR="$(cd "$(dirname "$(dirname "$FOUND_INSTALL")")" && pwd)"
    warn "Usando '${APP_DIR}' como raiz real do projeto a partir daqui."
  else
    err "Não encontrei scripts/install.sh em nenhum lugar dentro de ${APP_DIR} (nem dentro de um .zip). Isto é o que o clone realmente trouxe:"
    echo "----------------------------------------------------------------"
    find "$APP_DIR" -maxdepth 2 -not -path '*/.git*' 2>/dev/null
    echo "----------------------------------------------------------------"
    echo "Total de arquivos (fora .git): $(find "$APP_DIR" -type f -not -path '*/.git/*' 2>/dev/null | wc -l)"
    (cd "$APP_DIR" && echo "Último commit: $(git log -1 --oneline 2>/dev/null || echo 'não foi possível ler')")
    fatal "Confirma no navegador se github.com/${GITHUB_ORG}/lyra realmente tem 'scripts/', 'src/' e 'package.json' commitados na raiz do branch padrão (não só um .zip solto) — a listagem acima é exatamente o que o clone trouxe."
  fi
fi

# Garante o dono certo em TODO o APP_DIR, sempre — não só no clone novo.
# O fallback de extração de .zip acima roda como root e faz "cp -a" (que
# preserva o dono de quem copiou, ou seja, root), então sem isso a pasta
# data/ fica sem permissão de escrita pro usuário que o systemd realmente
# usa (APP_USER) — e a API quebra com EACCES ao tentar gravar
# data/tenants.dev.json em modo SECRETS_PROVIDER=env.
id -u "$APP_USER" >/dev/null 2>&1 && chown -R "${APP_USER}:${APP_USER}" "$APP_DIR"

# =============================================================================
# 3. .env — só na primeira vez (reruns preservam o que já existe, ADMIN_API_KEY
#    nunca é trocada sozinha: trocar invalidaria os tenants já provisionados)
# =============================================================================
if [ ! -f "${APP_DIR}/.env" ]; then
  log "Gerando .env pela primeira vez..."
  ADMIN_API_KEY="${ADMIN_API_KEY:-$(openssl rand -hex 32)}"
  cat > "${APP_DIR}/.env" << EOF
PORT=8080
NODE_ENV=development
LOG_LEVEL=info

GEMINI_API_KEY=${GEMINI_API_KEY}
GEMINI_MODEL=${GEMINI_MODEL}

SECRETS_PROVIDER=env

ADMIN_API_KEY=${ADMIN_API_KEY}

REDIS_URL=redis://localhost:6379

TOKENS_PER_ATTENDANCE=1000
RECARGAS_MAXIMAS_MES=3

RATE_LIMIT_WINDOW_MS=60000
RATE_LIMIT_MAX_REQUESTS=60

TIMEOUT_CONSULTAR_FRETE_MS=5000
TIMEOUT_CONSULTAR_SALDO_MS=4000
TIMEOUT_CONSULTAR_ESTOQUE_MS=4000
EOF
  chmod 600 "${APP_DIR}/.env"
  id -u "$APP_USER" >/dev/null 2>&1 && chown "${APP_USER}:${APP_USER}" "${APP_DIR}/.env"

  : > "$CRED_FILE"; chmod 600 "$CRED_FILE"
  cat >> "$CRED_FILE" << EOF
LYRA_CENTRAL_URL=https://${DOMINIO_LYRA}
ADMIN_API_KEY=${ADMIN_API_KEY}
EOF
  ok ".env criado — ADMIN_API_KEY gerada e salva em ${CRED_FILE} (chmod 600)"

  warn "NODE_ENV=development + SECRETS_PROVIDER=env: as API Keys de cada tenant"
  warn "ficam num arquivo local (data/tenants.dev.json), não criptografado."
  warn "O próprio scripts/install.sh do repo BLOQUEIA subir com NODE_ENV=production"
  warn "nesse modo — de propósito. Pra produção de verdade, primeiro implemente"
  warn "gcp_secret_manager ou vault em src/services/secrets.js (ainda são stubs,"
  warn "conforme o README do repo), troque SECRETS_PROVIDER e NODE_ENV no .env,"
  warn "e rode este script de novo (ele não sobrescreve o .env que já existe —"
  warn "edite manualmente antes de rerodar)."
else
  ok ".env já existe em ${APP_DIR} — mantido como está (mesmo comportamento do install.sh do repo)"
fi

# =============================================================================
# 4. DELEGAR PRO scripts/install.sh DO PRÓPRIO REPO
#    (systemd, npm ci, checagens de segurança — não duplicamos essa lógica)
# =============================================================================
log "Rodando scripts/install.sh do repo (systemd + npm ci)..."
if APP_USER="$APP_USER" APP_DIR="$APP_DIR" bash "${APP_DIR}/scripts/install.sh"; then
  ok "lyra-central-api ativo via systemd"
else
  fatal "install.sh do repo falhou — veja a saída acima (ex: NODE_ENV=production com SECRETS_PROVIDER=env é bloqueado de propósito)."
fi

# =============================================================================
# 5. TRAEFIK — HTTPS público em ${DOMINIO_LYRA}, apontando pro systemd local
#    (network_mode: host — mais simples aqui, já que só existe UM backend
#    estático (127.0.0.1:8080), não uma stack de vários containers pra
#    descobrir dinamicamente, então nem precisa montar docker.sock)
# =============================================================================
log "Configurando Traefik (HTTPS) pra ${DOMINIO_LYRA}..."
mkdir -p /home/ubuntu/lyra-traefik/dynamic
cat > /home/ubuntu/lyra-traefik/dynamic/lyra.yml << EOF
http:
  routers:
    lyra:
      rule: "Host(\`${DOMINIO_LYRA}\`)"
      entrypoints:
        - websecure
      tls:
        certResolver: myresolver
      service: lyra
  services:
    lyra:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:8080"
EOF

cat > /home/ubuntu/lyra-traefik/docker-compose.yml << EOF
services:
  traefik:
    image: traefik:v3.6
    container_name: lyra-traefik
    restart: always
    network_mode: host
    command:
      - "--providers.file.directory=/etc/traefik/dynamic"
      - "--providers.file.watch=true"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.web.http.redirections.entrypoint.to=websecure"
      - "--entrypoints.web.http.redirections.entrypoint.scheme=https"
      - "--entrypoints.websecure.address=:443"
      - "--certificatesResolvers.myresolver.acme.httpChallenge=true"
      - "--certificatesResolvers.myresolver.acme.httpChallenge.entrypoint=web"
      - "--certificatesResolvers.myresolver.acme.email=${EMAIL}"
      - "--certificatesResolvers.myresolver.acme.storage=/letsencrypt/acme.json"
    volumes:
      - ./dynamic:/etc/traefik/dynamic:ro
      - lyra_traefik_certs:/letsencrypt
volumes:
  lyra_traefik_certs:
EOF

cd /home/ubuntu/lyra-traefik && docker compose up -d
ok "Traefik ativo — HTTPS em https://${DOMINIO_LYRA} (certificado emitido on-demand no primeiro acesso)"

# =============================================================================
# 6. VALIDAÇÃO
# =============================================================================
log "Validando..."
sleep 3
CODE_LOCAL=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:8080/healthz" 2>/dev/null)
if [ "$CODE_LOCAL" = "200" ]; then
  ok "API local (127.0.0.1:8080/healthz) respondeu HTTP 200"
else
  err "API local não respondeu 200 (HTTP ${CODE_LOCAL}) — verifica 'journalctl -u lyra-central-api -n 100 --no-pager'"
fi

sleep 5
CODE_PUBLICO=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "https://${DOMINIO_LYRA}/healthz" 2>/dev/null)
if [ "$CODE_PUBLICO" = "200" ]; then
  ok "https://${DOMINIO_LYRA}/healthz respondeu HTTP 200"
else
  warn "https://${DOMINIO_LYRA}/healthz não respondeu 200 ainda (HTTP ${CODE_PUBLICO}) — confirma se o DNS de ${DOMINIO_LYRA} já aponta pro IP desta VPS; a emissão do certificado Let's Encrypt também pode levar alguns segundos a mais no primeiro acesso."
fi

# =============================================================================
# RESUMO FINAL
# =============================================================================
ADMIN_API_KEY_ATUAL="$(grep '^ADMIN_API_KEY=' "${APP_DIR}/.env" | cut -d'=' -f2-)"
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}   LYRA CENTRAL API NO AR${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "  URL pública   → https://${DOMINIO_LYRA}"
echo -e "  Serviço       → systemctl status lyra-central-api"
echo -e "  Logs          → journalctl -u lyra-central-api -f"
echo -e "  Credenciais   → ${CRED_FILE} (chmod 600)"
echo ""
echo -e "${YELLOW}Pra usar no provisionamento de clientes (provisionar_cliente_synapse.sh):${NC}"
echo -e "  export LYRA_CENTRAL_URL=https://${DOMINIO_LYRA}"
echo -e "  export LYRA_ADMIN_API_KEY=${ADMIN_API_KEY_ATUAL}"
echo ""
echo -e "${YELLOW}Próximos passos:${NC}"
echo -e "  1. Confirme o teto de gastos no projeto GCP (Vertex AI/Gemini), se ainda não fez."
echo -e "  2. Pra atualizar o código depois, use o scripts/deploy.sh que já vem no"
echo -e "     próprio repo (dentro de ${APP_DIR}) — ele já faz git pull + rollback"
echo -e "     automático se o healthcheck falhar. Não rode este script de novo pra isso."
if grep -q '^NODE_ENV=development' "${APP_DIR}/.env" 2>/dev/null; then
  echo -e "  3. ${RED}Está em NODE_ENV=development (SECRETS_PROVIDER=env) — API Keys de tenant${NC}"
  echo -e "     ${RED}ficam em texto local, não criptografadas. Ver aviso acima antes de tratar${NC}"
  echo -e "     ${RED}isso como produção de verdade com clientes pagantes.${NC}"
fi
echo -e "${GREEN}============================================================${NC}"
