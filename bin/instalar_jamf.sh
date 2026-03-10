#!/bin/bash

###############################################################################
# instalar_jamf.sh
# Enrolla o Mac no Jamf Pro via MDM (ABM PreStage)
#
# Autor: Assistente de Migração Globo
# Versão: 1.0
# Data: 2025-11-11
#
# Descrição:
#   Script que enrolla o Mac no Jamf Pro renovando o enrollment MDM.
#   Premissa: Mac já está no Apple Business Manager e no PreStage do Jamf.
#   Apenas executa "profiles renew -type enrollment" e monitora a conclusão.
#
# Exit Codes:
#   0 - Sucesso (Jamf enrollado)
#   1 - Erro geral
#   2 - Timeout no enrollment
#   3 - Enrollment falhou
#
###############################################################################

# Variáveis
readonly BASE_DIR="/Library/Application Support/Assistente-de-Migracao-Globo"
readonly LOGS_DIR="${BASE_DIR}/logs"
readonly MAIN_LOG="${LOGS_DIR}/migracao.log"
readonly STATE_FILE="${BASE_DIR}/migration_state.json"
readonly CONFIG_FILE="${BASE_DIR}/resources/config/migration_config.json"
readonly DIALOG_LOG="/var/tmp/dialog_migration.log"
readonly PROFILES_CMD="/usr/bin/profiles"
readonly JAMF_BINARY="/usr/local/bin/jamf"

# Obter serial number
readonly MACHINE_SERIAL=$(system_profiler SPHardwareDataType | awk '/Serial/ {print $4}')

# Variável para jq (herdada ou detectada)
JQ_BIN="${JQ_BIN:-}"

# Criar diretório de logs somente se não existir
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
# FUNÇÃO: Atualizar Dialog (item index 3)
###############################################################################
update_dialog() {
    local statustext="$1"

    if [[ -f "${DIALOG_LOG}" ]]; then
        echo "listitem: index: 3, statustext: ${statustext}" >>"${DIALOG_LOG}"
    fi
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
        return 1
    fi

    if [[ -f "${JQ_BIN}" ]]; then
        chmod +x "${JQ_BIN}" 2>/dev/null || true
        return 0
    fi
    return 1
}

###############################################################################
# INICIALIZAÇÃO
###############################################################################

log_message "========================================="
log_message "ENROLLANDO NO JAMF PRO"
log_message "Serial do Mac: ${MACHINE_SERIAL}"
log_message "========================================="

# Verificar se está rodando como root
if [[ $EUID -ne 0 ]]; then
    log_message "✗ Este script precisa ser executado como root"
    exit 1
fi

# Detectar jq se necessário
detect_jq_if_needed

###############################################################################
# FUNÇÃO: Verificar se já está enrollado no Jamf
###############################################################################
check_jamf_enrollment() {
    log_message "Verificando enrollment existente..."

    local mdm_enrollment
    mdm_enrollment=$("${PROFILES_CMD}" status -type enrollment 2>/dev/null)

    if echo "${mdm_enrollment}" | grep -q "MDM enrollment: Yes"; then
        local mdm_server
        mdm_server=$(echo "${mdm_enrollment}" | grep "MDM server:" | cut -d: -f2- | xargs)

        if echo "${mdm_server}" | grep -qi "jamf"; then
            log_message "✓ Mac já está enrollado no Jamf"
            log_message "   Servidor: ${mdm_server}"
            return 0
        fi
    fi

    return 1
}

###############################################################################
# FUNÇÃO: Renovar enrollment MDM (Jamf via ABM)
###############################################################################
renew_mdm_enrollment() {
    log_message "Renovando enrollment MDM..."
    update_dialog "🔄 Renovando enrollment MDM..."

    # Executar comando de renovação
    log_message "Executando: profiles renew -type enrollment"

    if "${PROFILES_CMD}" renew -type enrollment 2>&1 | tee -a "${MAIN_LOG}"; then
        log_message "✓ Comando de renovação executado"
        return 0
    else
        log_message "✗ Falha ao executar comando de renovação"
        return 1
    fi
}

###############################################################################
# FUNÇÃO: Monitorar enrollment do Jamf
###############################################################################
monitor_jamf_enrollment() {
    local checks=20                       # Número de tentativas
    local interval=30                     # Intervalo em segundos
    local max_time=$((checks * interval)) # Tempo total: 10 minutos

    log_message "Monitorando enrollment do Jamf..."
    log_message "   Máximo de tentativas: ${checks}"
    log_message "   Intervalo: ${interval}s"
    log_message "   Tempo máximo: $((max_time / 60)) minutos"

    for ((i = 1; i <= checks; i++)); do
        update_dialog "⏳ Aguardando enrollment no Jamf (${i}/${checks})..."

        log_message "Tentativa ${i}/${checks}: Verificando enrollment..."
        sleep $interval

        # Verificar se enrollou no Jamf
        local mdm_enrollment
        mdm_enrollment=$("${PROFILES_CMD}" status -type enrollment 2>/dev/null)

        if echo "${mdm_enrollment}" | grep -q "MDM enrollment: Yes"; then
            local mdm_server
            mdm_server=$(echo "${mdm_enrollment}" | grep "MDM server:" | cut -d: -f2- | xargs)

            if echo "${mdm_server}" | grep -qi "jamf"; then
                log_message "✓ Enrollment no Jamf concluído (tentativa ${i}/${checks})"
                log_message "   Servidor: ${mdm_server}"
                update_dialog "✅ Enrollado no Jamf"
                return 0
            else
                log_message "   MDM ativo mas não é Jamf: ${mdm_server}"
            fi
        else
            log_message "   Aguardando enrollment..."
        fi
    done

    # Timeout
    log_message "✗ Timeout: Enrollment não concluído após ${checks} tentativas ($((max_time / 60)) minutos)"
    update_dialog "✗ Timeout no enrollment"
    return 1
}

###############################################################################
# FUNÇÃO: Verificar binário do Jamf
###############################################################################
verify_jamf_binary() {
    log_message "Verificando instalação do binário Jamf..."
    update_dialog "🔍 Verificando binário Jamf..."

    if [[ -f "${JAMF_BINARY}" ]]; then
        local jamf_version
        jamf_version=$("${JAMF_BINARY}" version 2>/dev/null || echo "desconhecida")
        log_message "✓ Binário Jamf instalado"
        log_message "   Versão: ${jamf_version}"
        log_message "   Caminho: ${JAMF_BINARY}"
        return 0
    else
        log_message "⚠ Binário Jamf não encontrado em ${JAMF_BINARY}"
        log_message "   Enrollment via MDM não instala o binário imediatamente"
        log_message "   Será instalado via política posteriormente"
        return 1
    fi
}

###############################################################################
# FUNÇÃO: Executar recon (atualizar inventário)
###############################################################################
validate_jss() {
    if [[ ! -f "${JAMF_BINARY}" ]]; then
        log_message "⚠ Binário Jamf não disponível - pulando recon"
        return 0
    fi

    log_message "Validando se JSS está disponível..."
    sleep 60
    update_dialog "📋 Atualizando inventário do Jamf..."

    if "${JAMF_BINARY}" startup 2>&1 | tee -a "${MAIN_LOG}"; then
        log_message "✓ O JSS está disponível..."
        return 0
    else
        log_message "⚠ Falha ao validar JSS (não crítico)"
        return 1
    fi
}

###############################################################################
# FUNÇÃO: Atualizar arquivo de estado
###############################################################################
update_migration_state() {
    if [[ ! -f "${STATE_FILE}" ]]; then
        log_message "⚠ Arquivo de estado não encontrado - pulando atualização"
        return 0
    fi

    log_message "Atualizando arquivo de estado..."

    # Atualizar usando jq
    if [[ -n "${JQ_BIN}" ]] && [[ -f "${JQ_BIN}" ]]; then
        local temp_file="${STATE_FILE}.tmp"
        "${JQ_BIN}" \
            '.mdm_type = "jamf" | .migration_status = "jamf_enrolled"' \
            "${STATE_FILE}" >"${temp_file}" 2>/dev/null

        if [[ -f "${temp_file}" ]]; then
            mv "${temp_file}" "${STATE_FILE}"
            log_message "✓ Arquivo de estado atualizado"
        fi
    else
        # Fallback: sed
        sed -i '' 's/"mdm_type": "none"/"mdm_type": "jamf"/' "${STATE_FILE}" 2>/dev/null || true
        sed -i '' 's/"migration_status": "intune_removed"/"migration_status": "jamf_enrolled"/' "${STATE_FILE}" 2>/dev/null || true
        log_message "✓ Arquivo de estado atualizado (via sed)"
    fi
}

###############################################################################
# MAIN - EXECUÇÃO PRINCIPAL
###############################################################################

# 1. Verificar se já está no Jamf
if check_jamf_enrollment; then
    log_message "Mac já está enrollado no Jamf - nada a fazer"
    update_dialog "✅ Já enrollado no Jamf"

    # Tentar executar recon mesmo assim
    verify_jamf_binary && validate_jss

    exit 0
fi

# 2. Renovar enrollment MDM
update_dialog "🔄 Iniciando enrollment no Jamf..."

if ! renew_mdm_enrollment; then
    log_message "✗ Falha ao renovar enrollment MDM"
    update_dialog "✗ Falha ao renovar enrollment"
    exit 1
fi

# 3. Monitorar enrollment
if ! monitor_jamf_enrollment; then
    log_message "✗ Timeout no enrollment do Jamf"
    exit 2
fi

# 4. Verificar binário Jamf
verify_jamf_binary

# 5. Executar recon (se binário disponível)
validate_jss

# 6. Atualizar estado
update_migration_state

# 7. Conclusão
update_dialog "✅ Jamf enrollado com sucesso"

log_message "========================================="
log_message "✓ JAMF PRO ENROLLADO COM SUCESSO"
log_message "Tempo decorrido: ~$((SECONDS / 60)) minuto(s)"
log_message "========================================="

exit 0
