#!/bin/bash

###############################################################################
# pos_migracao.sh
# Pós-migração: Limpeza e finalização
#
# Autor: Assistente de Migração Globo
# Versão: 1.0
# Data: 2025-11-12
#
# Descrição:
#   Script de finalização executado após migração bem-sucedida.
#   Realiza limpeza de arquivos temporários, atualiza inventário do Jamf
#   e registra conclusão da migração.
#
# Exit Codes:
#   0 - Sucesso (finalização concluída)
#   1 - Erro (não está rodando como root)
###############################################################################

# Variáveis
readonly BASE_DIR="/Library/Application Support/Assistente de Migracao"
readonly BIN_DIR="${BASE_DIR}/bin"
readonly LOGS_DIR="${BASE_DIR}/logs"
readonly MAIN_LOG="${LOGS_DIR}/migracao.log"
readonly STATE_FILE="${BASE_DIR}/migration_state.json"
readonly DIALOG_LOG="/var/tmp/dialog_migration.log"
readonly JAMF_BINARY="/usr/local/bin/jamf"

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
# FUNÇÃO: Atualizar Dialog (item index 4)
###############################################################################
update_dialog() {
    local statustext="$1"

    if [[ -f "${DIALOG_LOG}" ]]; then
        echo "listitem: index: 4, statustext: ${statustext}" >>"${DIALOG_LOG}"
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
log_message "PÓS-MIGRAÇÃO - FINALIZAÇÃO"
log_message "========================================="

# Verificar se está rodando como root
if [[ $EUID -ne 0 ]]; then
    log_message "✗ Este script precisa ser executado como root"
    exit 1
fi

# Detectar jq se necessário
detect_jq_if_needed

###############################################################################
# FUNÇÃO: Executar Jamf recon (atualizar inventário)
###############################################################################
run_jamf_recon() {
    log_message ""
    log_message "Atualizando inventário do Jamf..."
    update_dialog "📊 Atualizando inventário do Jamf..."

    if [[ ! -f "${JAMF_BINARY}" ]]; then
        log_message "⚠ Binário Jamf não encontrado: ${JAMF_BINARY}"
        log_message "   Inventário será atualizado automaticamente pelo Jamf"
        return 0
    fi

    # Executar recon
    if "${JAMF_BINARY}" recon 2>&1 | tee -a "${MAIN_LOG}"; then
        log_message "✓ Inventário atualizado com sucesso"
        return 0
    else
        log_message "⚠ Falha ao atualizar inventário (não crítico)"
        return 1
    fi
}

###############################################################################
# FUNÇÃO: Limpar arquivos temporários
###############################################################################
cleanup_temp_files() {
    log_message ""
    log_message "Limpando arquivos temporários..."
    update_dialog "🧹 Limpando arquivos temporários..."

    local cleaned=0

    # Remover arquivos temporários específicos
    local temp_files=(
        "/private/tmp/com.jamf*"
        "/private/tmp/InstallationCheck*"
        "/var/tmp/dialog_migration.log.json"
    )

    for pattern in "${temp_files[@]}"; do
        if compgen -G "$pattern" >/dev/null 2>&1; then
            rm -f $pattern 2>/dev/null && ((cleaned++))
            log_message "   ✓ Removido: ${pattern}"
        fi
    done

    if [[ $cleaned -gt 0 ]]; then
        log_message "✓ ${cleaned} arquivo(s) temporário(s) removido(s)"
    else
        log_message "✓ Nenhum arquivo temporário encontrado"
    fi
}

###############################################################################
# FUNÇÃO: Rotacionar logs antigos (manter últimos 7 dias)
###############################################################################
rotate_old_logs() {
    log_message ""
    log_message "Verificando logs antigos..."
    update_dialog "📋 Verificando logs..."

    # Rotacionar log principal se maior que 10MB
    if [[ -f "${MAIN_LOG}" ]]; then
        local log_size=$(stat -f%z "${MAIN_LOG}" 2>/dev/null || echo 0)
        local max_size=$((10 * 1024 * 1024)) # 10MB em bytes

        if [[ $log_size -gt $max_size ]]; then
            local timestamp=$(date '+%Y%m%d_%H%M%S')
            local archived_log="${MAIN_LOG}.${timestamp}"

            cp "${MAIN_LOG}" "${archived_log}"
            echo "" >"${MAIN_LOG}"

            log_message "✓ Log rotacionado: $(basename ${archived_log})"
        fi
    fi

    # Remover logs arquivados com mais de 7 dias
    find "${LOGS_DIR}" -name "*.log.*" -type f -mtime +7 -delete 2>/dev/null
    log_message "✓ Logs antigos verificados (mantidos últimos 7 dias)"
}

###############################################################################
# FUNÇÃO: Atualizar arquivo de estado final
###############################################################################
update_final_state() {
    if [[ ! -f "${STATE_FILE}" ]]; then
        log_message "⚠ Arquivo de estado não encontrado"
        return 0
    fi

    log_message ""
    log_message "Atualizando estado final da migração..."
    update_dialog "💾 Salvando estado..."

    # Adicionar data de conclusão e status final
    if [[ -n "${JQ_BIN}" ]] && [[ -f "${JQ_BIN}" ]]; then
        local temp_file="${STATE_FILE}.tmp"
        local completion_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)

        "${JQ_BIN}" \
            --arg date "$completion_date" \
            '.migration_status = "completed" | .completion_date = $date' \
            "${STATE_FILE}" >"${temp_file}" 2>/dev/null

        if [[ -f "${temp_file}" ]]; then
            mv "${temp_file}" "${STATE_FILE}"
            log_message "✓ Estado final atualizado"
        fi
    else
        # Fallback: sed
        sed -i '' 's/"migration_status": "[^"]*"/"migration_status": "completed"/' "${STATE_FILE}" 2>/dev/null
        log_message "✓ Estado final atualizado (via sed)"
    fi
}

###############################################################################
# FUNÇÃO: Verificar enrollment final
###############################################################################
verify_final_enrollment() {
    log_message ""
    log_message "Verificando enrollment final..."
    update_dialog "✅ Verificando enrollment..."

    # Verificar perfil MDM
    local mdm_enrollment
    mdm_enrollment=$(/usr/bin/profiles status -type enrollment 2>/dev/null)

    if echo "${mdm_enrollment}" | grep -q "MDM enrollment: Yes"; then
        local mdm_server
        mdm_server=$(echo "${mdm_enrollment}" | grep "MDM server:" | cut -d: -f2- | xargs)

        log_message "✓ Enrollment verificado:"
        log_message "   MDM ativo: Sim"
        log_message "   Servidor: ${mdm_server}"

        if echo "${mdm_server}" | grep -qi "jamf"; then
            log_message "   ✓ Confirmado: Jamf Pro"
            return 0
        else
            log_message "   ⚠ Servidor MDM não é Jamf: ${mdm_server}"
            return 1
        fi
    else
        log_message "⚠ MDM não está ativo - pode ainda estar finalizando enrollment"
        return 1
    fi
}

###############################################################################
# FUNÇÃO: Exibir resumo final
###############################################################################
show_summary() {
    log_message ""
    log_message "========================================="
    log_message "RESUMO DA MIGRAÇÃO"
    log_message "========================================="

    # Ler informações do arquivo de estado
    if [[ -f "${STATE_FILE}" ]] && [[ -n "${JQ_BIN}" ]] && [[ -f "${JQ_BIN}" ]]; then
        local os_version=$("${JQ_BIN}" -r '.os_version // "N/A"' "${STATE_FILE}")
        local validation_date=$("${JQ_BIN}" -r '.validation_date // "N/A"' "${STATE_FILE}")
        local mdm_type=$("${JQ_BIN}" -r '.mdm_type // "N/A"' "${STATE_FILE}")

        log_message "   macOS: ${os_version}"
        log_message "   Data início: ${validation_date}"
        log_message "   MDM atual: ${mdm_type}"
    fi

    # Obter informações do Mac
    local serial=$(system_profiler SPHardwareDataType | awk '/Serial/ {print $4}')
    local computer_name=$(scutil --get ComputerName 2>/dev/null || hostname)

    log_message "   Computador: ${computer_name}"
    log_message "   Serial: ${serial}"
    log_message ""
    log_message "✓ Migração concluída com sucesso!"
    log_message "   O Mac foi migrado do Intune para o Jamf Pro."
    log_message ""
    log_message "Próximos passos:"
    log_message "   1. Políticas do Jamf serão aplicadas automaticamente"
    log_message "   2. Aguarde ~10 minutos para sincronização completa"
    log_message "   3. Reinicie o Mac se solicitado por políticas"
    log_message "========================================="
}

###############################################################################
# MAIN - EXECUÇÃO PRINCIPAL
###############################################################################

# 1. Executar Jamf recon
run_jamf_recon

# 2. Limpar arquivos temporários
cleanup_temp_files

# 3. Rotacionar logs antigos
rotate_old_logs

# 4. Atualizar estado final
update_final_state

# 5. Verificar enrollment final
verify_final_enrollment

# 6. Exibir resumo
show_summary

# 7. Conclusão
update_dialog "✅ Finalização concluída"

log_message ""
log_message "Agendando autoeliminação da pasta do assistente em 10 segundos..."
update_dialog "🗑️ Agendando limpeza da pasta do assistente..."

# Notificar conclusão
"${BIN_DIR}/notificar_teams.sh" "concluido" &
sleep 5

cd "/private/tmp"
nohup "/private/tmp/limpeza_final.sh" >/dev/null 2>&1 &
sleep 5

log_message ""
log_message "========================================="
log_message "✓ PÓS-MIGRAÇÃO CONCLUÍDA"
log_message "Tempo total de migração: ~$((SECONDS / 60)) minuto(s)"
log_message "========================================="

exit 0
