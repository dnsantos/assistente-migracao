#!/bin/bash

###############################################################################
# notificar_teams.sh
# Envia notificações para o Microsoft Teams usando Adaptive Cards
#
# Autor: Assistente de Migração Globo
# Versão: 1.3
# Data: 2025-11-12
#
# Parâmetros:
#   $1 - Status ("inicio", "concluido", "falha")
#   $2 - Mensagem de erro (apenas para status "falha")
#
# Exit Codes:
#   0 - Sucesso
#   1 - Erro
###############################################################################

# Variáveis
readonly BASE_DIR="/Library/Application Support/Assistente de Migracao"
readonly LOGS_DIR="${BASE_DIR}/logs"
readonly MAIN_LOG="${LOGS_DIR}/migracao.log"
readonly STATE_FILE="${BASE_DIR}/migration_state.json"
readonly CONFIG_FILE="${BASE_DIR}/resources/config/migration_config.json"

# Variável para jq (herdada ou detectada)
JQ_BIN="${JQ_BIN:-}"

# Criar diretório de logs se não existir
if [[ ! -d "${LOGS_DIR}" ]]; then
    mkdir -p "${LOGS_DIR}"
fi

###############################################################################
# FUNÇÃO: Logging
###############################################################################
log_message() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] $1" | tee -a "${MAIN_LOG}"
}

###############################################################################
# FUNÇÃO: Detectar jq se necessário
###############################################################################
detect_jq_if_needed() {
    if [[ -n "${JQ_BIN}" ]] && [[ -f "${JQ_BIN}" ]]; then
        return 0
    fi

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
        export JQ_BIN
        log_message "✓ jq configurado: ${JQ_BIN}"
        return 0
    else
        log_message "⚠ jq não encontrado: ${JQ_BIN}"
        return 1
    fi
}

###############################################################################
# INICIALIZAÇÃO
###############################################################################

# Validar parâmetros
if [[ -z "$1" ]]; then
    log_message "✗ Erro: Status não fornecido para notificar_teams.sh"
    exit 1
fi

readonly status="$1"
readonly error_message="${2:-"Não especificado"}"
webhook_url=""

# Detectar jq se necessário
detect_jq_if_needed

###############################################################################
# FUNÇÃO: Ler Webhook URL do arquivo de configuração
###############################################################################
read_webhook_url() {
    if [[ -f "${CONFIG_FILE}" ]] && [[ -n "${JQ_BIN}" ]] && [[ -f "${JQ_BIN}" ]]; then
        webhook_url=$("${JQ_BIN}" -r '.intune.teams_webhook_url // ""' "${CONFIG_FILE}")
    fi

    if [[ -z "${webhook_url}" ]]; then
        log_message "⚠ Webhook URL não encontrado"
        return 1
    fi
    return 0
}

###############################################################################
# FUNÇÃO: Montar e enviar payload Adaptive Card
###############################################################################
send_notification() {
    log_message "Enviando notificação para o Teams: ${status}"

    # Obter informações do sistema
    local os_version=$(sw_vers -productVersion)
    local computer_name=$(scutil --get ComputerName 2>/dev/null || hostname)
    local serial=$(system_profiler SPHardwareDataType | awk '/Serial/ {print $4}')
    local logged_user=$(stat -f "%Su" /dev/console 2>/dev/null || echo "N/A")

    # Datas e Duração
    local start_date=$(awk 'NR==1 {print $1, $2}' "${MAIN_LOG}" | tr -d '[]')
    local end_date="Em progresso..."
    local duration="N/A"

    if [[ "$status" != "inicio" ]]; then
        end_date=$(date '+%Y-%m-%d %H:%M:%S')
        # Calcular duração
        local start_seconds=$(date -j -f "%Y-%m-%d %H:%M:%S" "$start_date" "+%s" 2>/dev/null)
        local end_seconds=$(date -j -f "%Y-%m-%d %H:%M:%S" "$end_date" "+%s" 2>/dev/null)
        if [[ -n "$start_seconds" ]] && [[ -n "$end_seconds" ]]; then
            local diff_seconds=$((end_seconds - start_seconds))
            duration="${diff_seconds}s"
        fi
    fi

    # Definir título e ícones
    local title=""
    local error_section=""

    if [[ "$status" == "inicio" ]]; then
        title="🚀 Início da Migração"
    elif [[ "$status" == "concluido" ]]; then
        title="✅ Migração Concluída com Sucesso"
    elif [[ "$status" == "falha" ]]; then
        title="❌ Migração Falhou"
        error_section=$(
            cat <<EOF
,
{
    "type": "TextBlock",
    "text": "🔴 **Erro**",
    "weight": "Bolder"
},
{
    "type": "TextBlock",
    "text": "${error_message}",
    "wrap": true
}
EOF
        )
    fi

    # Montar payload do Adaptive Card (SEM emojis nos títulos do FactSet)
    local adaptive_card_payload
    adaptive_card_payload=$(
        cat <<EOF
{
    "type": "message",
    "attachments": [
        {
            "contentType": "application/vnd.microsoft.card.adaptive",
            "content": {
                "\$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
                "type": "AdaptiveCard",
                "version": "1.4",
                "body": [
                    {
                        "type": "TextBlock",
                        "text": "${title}",
                        "weight": "Bolder",
                        "size": "Large"
                    }
                    ${error_section}
                    ,
                    {
                        "type": "FactSet",
                        "facts": [
                            {
                                "title": "Máquina:",
                                "value": "${computer_name}"
                            },
                            {
                                "title": "Serial:",
                                "value": "${serial}"
                            },
                            {
                                "title": "Usuário:",
                                "value": "${logged_user}"
                            },
                            {
                                "title": "Início:",
                                "value": "${start_date}"
                            },
                            {
                                "title": "Fim:",
                                "value": "${end_date}"
                            },
                            {
                                "title": "Duração:",
                                "value": "${duration}"
                            }
                        ]
                    }
                ]
            }
        }
    ]
}
EOF
    )

    # Enviar notificação
    local response
    response=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -d "${adaptive_card_payload}" "${webhook_url}")

    if [[ "$response" -eq 200 ]]; then
        log_message "✓ Notificação enviada com sucesso para o Teams"
        return 0
    else
        log_message "✗ Falha ao enviar notificação (HTTP: ${response})"
        log_message "Payload enviado: ${adaptive_card_payload}"
        return 1
    fi
}

###############################################################################
# MAIN
###############################################################################

if ! read_webhook_url; then
    exit 1
fi

if ! send_notification; then
    exit 1
fi

exit 0
