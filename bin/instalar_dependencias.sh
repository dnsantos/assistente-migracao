#!/bin/bash

###############################################################################
# instalar_dependencias.sh
# Instala swiftDialog baixando da última release do GitHub
#
# Versão: 1.1
# Atualização: Usa jq para parsing JSON da API do GitHub
###############################################################################

# Variáveis
readonly BASE_DIR="/Library/Application Support/Assistente de Migracao"
readonly LOGS_DIR="${BASE_DIR}/logs"
readonly MAIN_LOG="${LOGS_DIR}/migracao.log"
readonly DIALOG_APP="/Library/Application Support/Dialog/Dialog.app"
readonly DIALOG_BIN="/usr/local/bin/dialog"

# Variável para jq (herdada ou detectada)
JQ_BIN="${JQ_BIN:-}"

# Criar diretório de logs somente se não existir
if [[ ! -d "${LOGS_DIR}" ]]; then
    mkdir -p "${LOGS_DIR}"
fi

# Função de logging
log_message() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] $1" | tee -a "${MAIN_LOG}"
}

log_message "========================================="
log_message "Instalando dependências"
log_message "========================================="

###############################################################################
# FUNÇÃO: Detectar jq se não foi herdado
###############################################################################
detect_jq_if_needed() {
    # Se JQ_BIN já está definida (herdada), não faz nada
    if [[ -n "${JQ_BIN}" ]] && [[ -f "${JQ_BIN}" ]]; then
        log_message "✓ Usando jq herdado: ${JQ_BIN}"
        return 0
    fi

    # Detectar arquitetura
    local arch=$(uname -m)

    if [[ "$arch" == "arm64" ]]; then
        JQ_BIN="${BASE_DIR}/bin/jq-macos-arm64"
    elif [[ "$arch" == "x86_64" ]]; then
        JQ_BIN="${BASE_DIR}/bin/jq-macos-amd64"
    else
        log_message "⚠ Arquitetura não suportada: ${arch}"
        return 1
    fi

    if [[ -f "${JQ_BIN}" ]]; then
        chmod +x "${JQ_BIN}" 2>/dev/null || true
        log_message "✓ jq detectado: ${JQ_BIN}"
        return 0
    fi

    log_message "⚠ jq não encontrado: ${JQ_BIN}"
    return 1
}

###############################################################################
# FUNÇÃO: Instalar swiftDialog
###############################################################################
install_dialog() {
    # Verificar se Dialog já está instalado
    if [[ -d "${DIALOG_APP}" ]] && [[ -f "${DIALOG_BIN}" ]]; then
        local dialog_version=$("${DIALOG_BIN}" --version 2>/dev/null || echo "desconhecida")
        log_message "✓ swiftDialog já instalado (versão: ${dialog_version})"
        return 0
    fi

    log_message "swiftDialog não encontrado. Instalando..."

    # Obter informações da última release do GitHub
    log_message "Consultando API do GitHub..."
    local api_response
    api_response=$(curl --silent --fail "https://api.github.com/repos/swiftDialog/swiftDialog/releases/latest")

    if [[ -z "${api_response}" ]]; then
        log_message "✗ Falha ao consultar API do GitHub"
        return 1
    fi

    # Extrair URL do PKG usando jq (mais robusto que awk)
    local dialogURL
    if [[ -n "${JQ_BIN}" ]] && [[ -f "${JQ_BIN}" ]]; then
        log_message "Extraindo URL do download usando jq..."
        dialogURL=$(echo "${api_response}" | "${JQ_BIN}" -r '.assets[] | select(.name | endswith(".pkg")) | .browser_download_url' | head -1)
    else
        # Fallback: usar awk se jq não estiver disponível
        log_message "⚠ jq não disponível - usando awk como fallback"
        dialogURL=$(echo "${api_response}" | awk -F '"' '/browser_download_url/ && /pkg\"/ { print $4; exit }')
    fi

    if [[ -z "${dialogURL}" ]]; then
        log_message "✗ Falha ao extrair URL do Dialog"
        return 1
    fi

    log_message "URL do download: ${dialogURL}"
    log_message "Baixando swiftDialog..."

    # Team ID esperado do swiftDialog
    local expectedDialogTeamID="PWA5E9TQ59"

    # Criar diretório temporário
    local workDirectory=$(/usr/bin/basename "$0")
    local tempDirectory=$(/usr/bin/mktemp -d "/private/tmp/${workDirectory}.XXXXXX")

    # Baixar o PKG
    if ! /usr/bin/curl --location --silent "${dialogURL}" -o "${tempDirectory}/Dialog.pkg"; then
        log_message "✗ Falha ao baixar Dialog"
        /bin/rm -Rf "${tempDirectory}"
        return 1
    fi

    log_message "Download concluído. Verificando assinatura digital..."

    # Verificar Team ID do pacote
    local teamID
    teamID=$(/usr/sbin/spctl -a -vv -t install "${tempDirectory}/Dialog.pkg" 2>&1 | awk '/origin=/ {print $NF }' | tr -d '()')

    log_message "Team ID encontrado: ${teamID}"

    if [[ "${expectedDialogTeamID}" == "${teamID}" ]]; then
        log_message "✓ Assinatura verificada. Instalando..."

        if /usr/sbin/installer -pkg "${tempDirectory}/Dialog.pkg" -target / >>"${MAIN_LOG}" 2>&1; then
            /bin/rm -Rf "${tempDirectory}"

            # Verificar instalação
            if [[ -f "${DIALOG_BIN}" ]]; then
                local dialog_version=$("${DIALOG_BIN}" --version 2>/dev/null || echo "desconhecida")
                log_message "✓ swiftDialog instalado com sucesso (versão: ${dialog_version})"
                return 0
            else
                log_message "✗ Falha na verificação pós-instalação"
                return 1
            fi
        else
            log_message "✗ Falha durante a instalação"
            /bin/rm -Rf "${tempDirectory}"
            return 1
        fi
    else
        log_message "✗ Falha na verificação de assinatura digital"
        log_message "   Esperado: ${expectedDialogTeamID}"
        log_message "   Encontrado: ${teamID}"
        /bin/rm -Rf "${tempDirectory}"
        return 1
    fi
}

###############################################################################
# MAIN
###############################################################################

# Detectar jq se necessário
detect_jq_if_needed

log_message ""
log_message "Verificando swiftDialog..."

install_dialog || {
    log_message "✗ Falha ao instalar swiftDialog"
    exit 1
}

log_message ""
log_message "========================================="
log_message "✓ Dependências instaladas com sucesso"
log_message "========================================="

exit 0
