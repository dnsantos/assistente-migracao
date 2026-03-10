#!/bin/bash

###############################################################################
# remover_intune.sh
# Remove o Mac do gerenciamento do Microsoft Intune via Graph API
#
# Versão: 1.2
# Atualização: Usa migration_config.json e jq para parsing
###############################################################################

# Variáveis
readonly BASE_DIR="/Library/Application Support/Assistente de Migracao"
readonly LOGS_DIR="${BASE_DIR}/logs"
readonly MAIN_LOG="${LOGS_DIR}/migracao.log"
readonly STATE_FILE="${BASE_DIR}/migration_state.json"
readonly CONFIG_FILE="${BASE_DIR}/resources/config/migration_config.json"
readonly DIALOG_LOG="/var/tmp/dialog_migration.log"
readonly PROFILES_CMD="/usr/bin/profiles"
readonly SERVICE_NAME="GloboMigrationService"
readonly ACCOUNT_NAME="IntuneAuth"

# Obter serial number da máquina
readonly MACHINE_SERIAL=$(system_profiler SPHardwareDataType | awk '/Serial/ {print $4}')

# Variável para jq (será definida por detect_jq_binary)
JQ_BIN=""

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
# FUNÇÃO: Atualizar Dialog (item index 2)
###############################################################################
update_dialog() {
    local statustext="$1"

    if [[ -f "${DIALOG_LOG}" ]]; then
        echo "listitem: index: 2, statustext: ${statustext}" >>"${DIALOG_LOG}"
    fi
}

###############################################################################
# FUNÇÃO: Detectar arquitetura e definir binário jq
###############################################################################
detect_jq_binary() {
    local arch=$(uname -m)

    log_message "Detectando arquitetura do sistema..."

    if [[ "$arch" == "arm64" ]]; then
        JQ_BIN="${BASE_DIR}/bin/jq-macos-arm64"
        log_message "✓ Arquitetura: Apple Silicon (arm64)"
    elif [[ "$arch" == "x86_64" ]]; then
        JQ_BIN="${BASE_DIR}/bin/jq-macos-amd64"
        log_message "✓ Arquitetura: Intel (x86_64)"
    else
        log_message "✗ Arquitetura não suportada: ${arch}"
        return 1
    fi

    if [[ ! -f "${JQ_BIN}" ]]; then
        log_message "✗ Binário jq não encontrado: ${JQ_BIN}"
        return 1
    fi

    # Garantir permissão de execução
    chmod +x "${JQ_BIN}" 2>/dev/null || true

    log_message "✓ Binário jq: ${JQ_BIN}"
    return 0
}

###############################################################################
# INICIALIZAÇÃO
###############################################################################

log_message "========================================="
log_message "REMOVENDO ENROLLMENT DO INTUNE"
log_message "Serial do Mac: ${MACHINE_SERIAL}"
log_message "========================================="

# Verificar se está rodando como root
if [[ $EUID -ne 0 ]]; then
    log_message "✗ Este script precisa ser executado como root"
    exit 1
fi

# Detectar e configurar jq
if ! detect_jq_binary; then
    log_message "✗ Falha ao configurar binário jq"
    update_dialog "✗ Erro de configuração (jq não encontrado)"
    exit 1
fi

###############################################################################
# FUNÇÃO: Carregar credenciais do arquivo de configuração JSON
###############################################################################
load_intune_credentials() {
    log_message "Carregando credenciais do Intune..."
    update_dialog "🔑 Carregando credenciais..."

    if [[ ! -f "${CONFIG_FILE}" ]]; then
        log_message "✗ Arquivo de configuração não encontrado: ${CONFIG_FILE}"
        update_dialog "✗ Arquivo de configuração não encontrado"
        return 1
    fi

    # Validar formato JSON
    if ! "${JQ_BIN}" . "${CONFIG_FILE}" >/dev/null 2>&1; then
        log_message "✗ Arquivo de configuração com formato JSON inválido"
        update_dialog "✗ Formato JSON inválido"
        return 1
    fi

    # Ler valores usando jq
    INTUNE_TENANT_ID=$("${JQ_BIN}" -r '.intune.tenant_id // empty' "${CONFIG_FILE}" 2>/dev/null)
    INTUNE_CLIENT_ID=$("${JQ_BIN}" -r '.intune.client_id // empty' "${CONFIG_FILE}" 2>/dev/null)
    #INTUNE_CLIENT_SECRET=$("${JQ_BIN}" -r '.intune.client_secret // empty' "${CONFIG_FILE}" 2>/dev/null)
    INTUNE_CLIENT_SECRET=$(/usr/bin/security find-generic-password -s "$SERVICE_NAME" -a "$ACCOUNT_NAME" -w /Library/Keychains/System.keychain 2>/dev/null)

    if [[ -z "${INTUNE_TENANT_ID}" ]] || [[ -z "${INTUNE_CLIENT_ID}" ]] || [[ -z "${INTUNE_CLIENT_SECRET}" ]]; then
        log_message "✗ Credenciais do Intune não configuradas no arquivo"
        update_dialog "✗ Credenciais não configuradas"
        return 1
    fi

    log_message "✓ Credenciais carregadas com sucesso"
    log_message "   Tenant ID: ${INTUNE_TENANT_ID}"
    log_message "   Client ID: ${INTUNE_CLIENT_ID}"
    return 0
}

###############################################################################
# FUNÇÃO: Obter token de acesso do Microsoft Graph
###############################################################################
get_graph_token() {
    log_message "Obtendo token de acesso do Microsoft Graph..."
    update_dialog "🔐 Autenticando no Microsoft Graph..."

    token=$(curl --silent --location --request POST \
        "https://login.microsoftonline.com/${INTUNE_TENANT_ID}/oauth2/v2.0/token" \
        --header "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "client_id=${INTUNE_CLIENT_ID}" \
        --data-urlencode "scope=https://graph.microsoft.com/.default" \
        --data-urlencode "client_secret=${INTUNE_CLIENT_SECRET}" \
        --data-urlencode "grant_type=client_credentials" |
        "${JQ_BIN}" -r '.access_token // empty')

    if [[ -z "$token" ]]; then
        log_message "✗ Falha ao obter token de acesso"
        update_dialog "✗ Falha na autenticação"
        return 1
    fi

    log_message "✓ Token obtido com sucesso"
    return 0
}

###############################################################################
# FUNÇÃO: Buscar dispositivo no Intune por serial number
###############################################################################
find_device_in_intune() {
    log_message "Buscando dispositivo no Intune..."
    log_message "   Serial number: ${MACHINE_SERIAL}"
    update_dialog "🔍 Buscando ${MACHINE_SERIAL} no Intune..."

    local response
    response=$(curl --silent \
        "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?\$filter=serialNumber%20eq%20%27${MACHINE_SERIAL}%27" \
        -H "Authorization: Bearer ${token}" \
        -H "Accept: application/json")

    if [[ -z "$response" ]]; then
        log_message "✗ Erro ao consultar API do Intune"
        update_dialog "✗ Erro na consulta do Intune"
        return 1
    fi

    # Extrair device ID e serial usando jq
    device_id=$(echo "$response" | "${JQ_BIN}" -r '.value[0].id // empty')

    local serial_found
    serial_found=$(echo "$response" | "${JQ_BIN}" -r '.value[0].serialNumber // empty')

    if [[ -n "$device_id" ]] && [[ -n "$serial_found" ]]; then
        log_message "✓ Dispositivo encontrado no Intune"
        log_message "   Serial: ${serial_found}"
        log_message "   Device ID: ${device_id}"
        update_dialog "✓ Dispositivo localizado (${serial_found})"
        return 0
    else
        log_message "✗ Dispositivo não encontrado no Intune"
        log_message "   Serial procurado: ${MACHINE_SERIAL}"
        update_dialog "✗ Dispositivo não encontrado no Intune"
        return 1
    fi
}

###############################################################################
# FUNÇÃO: Executar retire do dispositivo via API
###############################################################################
retire_device() {
    log_message "Executando retire do dispositivo..."
    log_message "   Device ID: ${device_id}"
    update_dialog "🔄 Executando retire do dispositivo..."

    local response
    response=$(curl --silent --write-out "\n%{http_code}" \
        -X POST "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/${device_id}/retire" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        --data-raw '')

    local http_code=$(echo "$response" | tail -n1)

    if [[ "$http_code" == "200" ]] || [[ "$http_code" == "204" ]]; then
        log_message "✓ Comando retire executado com sucesso (HTTP ${http_code})"
        update_dialog "✓ Retire executado com sucesso"
        return 0
    else
        log_message "✗ Falha ao executar retire (HTTP ${http_code})"
        log_message "   Resposta: $(echo "$response" | head -n -1)"
        update_dialog "✗ Falha ao executar retire"
        return 1
    fi
}

# ###############################################################################
# # FUNÇÃO: Monitorar remoção do perfil MDM
# ###############################################################################
# monitor_mdm_removal() {
#     local checks=120
#     local interval=30
#     local max_time=$((checks * interval))

#     log_message "Monitorando remoção do perfil MDM..."
#     log_message "   Máximo de tentativas: ${checks}"
#     log_message "   Intervalo: ${interval}s"
#     log_message "   Tempo máximo: $((max_time / 60)) minutos"

#     for ((i = 1; i <= checks; i++)); do
#         update_dialog "⏳ Aguardando remoção do MDM (${i}/${checks})..."

#         log_message "Tentativa ${i}/${checks}: Verificando perfil MDM..."
#         sleep $interval

#         # Verificar se MDM ainda está ativo
#         local mdm_enrollment
#         mdm_enrollment=$("${PROFILES_CMD}" status -type enrollment 2>/dev/null | grep "MDM enrollment" || true)

#         if [[ "$mdm_enrollment" != *"Yes"* ]]; then
#             log_message "✓ Perfil MDM removido com sucesso (tentativa ${i}/${checks})"
#             update_dialog "✅ Perfil MDM removido com sucesso"
#             return 0
#         else
#             log_message "   MDM ainda ativo - aguardando..."
#         fi
#     done

#     # Timeout
#     log_message "✗ Timeout: Perfil MDM não foi removido após ${checks} tentativas ($((max_time / 60)) minutos)"
#     update_dialog "✗ Timeout na remoção do MDM"
#     return 1
# }

###############################################################################
# FUNÇÃO: Monitorar remoção do perfil MDM (Modo Espera Infinita)
###############################################################################
monitor_mdm_removal() {
    local interval=30
    local counter=1
    local elapsed_minutes=0

    log_message "Iniciando monitoramento contínuo da remoção do perfil MDM..."
    log_message "   Intervalo de checagem: ${interval}s"
    log_message "   Modo: Espera infinita até a remoção"

    # Loop infinito: só sai quando o comando 'return 0' for executado
    while true; do
        # Calcula tempo decorrido aproximado para exibição
        elapsed_minutes=$(((counter * interval) / 60))

        # Atualiza a interface visual com o tempo decorrido
        if [[ $elapsed_minutes -eq 0 ]]; then
            update_dialog "⏳ Aguardando remoção do MDM..."
        else
            update_dialog "⏳ Aguardando remoção do MDM... (${elapsed_minutes} min)"
        fi

        log_message "Checagem #${counter} (${elapsed_minutes}m decorridos): Verificando perfil MDM..."

        # Verificar se MDM ainda está ativo
        local mdm_enrollment
        mdm_enrollment=$("${PROFILES_CMD}" status -type enrollment 2>/dev/null | grep "MDM enrollment" || true)

        if [[ "$mdm_enrollment" != *"Yes"* ]]; then
            log_message "✓ Perfil MDM removido com sucesso após ~${elapsed_minutes} minutos."
            update_dialog "✅ Perfil MDM removido com sucesso"
            return 0
        else
            log_message "   MDM ainda ativo - aguardando mais ${interval}s..."
        fi

        # Aguarda o intervalo antes da próxima tentativa
        sleep $interval
        ((counter++))
    done
}

###############################################################################
# FUNÇÃO: Limpeza adicional de componentes do Intune
###############################################################################
cleanup_intune_components() {
    log_message "Limpando componentes adicionais do Intune..."
    update_dialog "🧹 Limpando componentes do Intune..."

    local cleaned=0

    # Remover preferências do Company Portal
    if [[ -f "/Library/Preferences/com.microsoft.CompanyPortal.plist" ]]; then
        rm -f "/Library/Preferences/com.microsoft.CompanyPortal.plist" 2>/dev/null && ((cleaned++))
        log_message "✓ Removidas preferências do Company Portal"
    fi

    # Remover caches do Intune
    if [[ -d "/Library/Application Support/Microsoft/Intune" ]]; then
        rm -rf "/Library/Application Support/Microsoft/Intune" 2>/dev/null && ((cleaned++))
        log_message "✓ Removido cache do Intune"
    fi

    # Remover LaunchDaemons/Agents do Intune
    for daemon in /Library/LaunchDaemons/com.microsoft.intune.* /Library/LaunchAgents/com.microsoft.intune.*; do
        if [[ -f "${daemon}" ]]; then
            launchctl unload "${daemon}" 2>/dev/null
            rm -f "${daemon}" 2>/dev/null && ((cleaned++))
            log_message "✓ Removido: $(basename ${daemon})"
        fi
    done

    if [[ $cleaned -gt 0 ]]; then
        log_message "✓ Limpeza concluída (${cleaned} itens removidos)"
    else
        log_message "✓ Nenhum componente adicional encontrado para limpeza"
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

    # Atualizar usando jq (mais seguro que sed para JSON)
    local temp_file="${STATE_FILE}.tmp"

    "${JQ_BIN}" \
        '.mdm_type = "none" | .migration_status = "intune_removed"' \
        "${STATE_FILE}" >"${temp_file}" 2>/dev/null

    if [[ -f "${temp_file}" ]]; then
        mv "${temp_file}" "${STATE_FILE}"
        log_message "✓ Arquivo de estado atualizado"
    else
        log_message "⚠ Falha ao atualizar arquivo de estado"
    fi
}

###############################################################################
# MAIN - EXECUÇÃO PRINCIPAL
###############################################################################

# 1. Carregar credenciais
if ! load_intune_credentials; then
    log_message "✗ Falha ao carregar credenciais do Intune"
    exit 1
fi

# 2. Obter token de acesso
if ! get_graph_token; then
    log_message "✗ Falha ao obter token de autenticação"
    exit 1
fi

# 3. Buscar dispositivo no Intune
if ! find_device_in_intune; then
    log_message "✗ Dispositivo não encontrado no Intune"
    exit 2
fi

# 4. Executar retire
if ! retire_device; then
    log_message "✗ Falha ao executar retire do dispositivo"
    exit 3
fi

# 5. Monitorar remoção do MDM
if ! monitor_mdm_removal; then
    log_message "✗ Timeout na remoção do perfil MDM"
    exit 4
fi

# 6. Limpeza adicional
cleanup_intune_components

# 7. Atualizar arquivo de estado
update_migration_state

# 8. Conclusão
update_dialog "✅ Intune removido com sucesso"

log_message "========================================="
log_message "✓ INTUNE REMOVIDO COM SUCESSO"
log_message "Tempo decorrido: ~$((SECONDS / 60)) minuto(s)"
log_message "========================================="

exit 0
