#!/bin/bash

###############################################################################
# validacao_pre_migracao.sh
# Valida o estado atual do Mac e determina se precisa migrar
#
# Versão: 1.1
# Atualização: Usa jq para manipular JSON
###############################################################################

# Variáveis
readonly BASE_DIR="/Library/Application Support/Assistente de Migracao"
readonly LOGS_DIR="${BASE_DIR}/logs"
readonly MAIN_LOG="${LOGS_DIR}/migracao.log"
readonly STATE_FILE="${BASE_DIR}/migration_state.json"

# Criar diretório de logs somente se não existir
if [[ ! -d "${LOGS_DIR}" ]]; then
    mkdir -p "${LOGS_DIR}"
else
    rm -f "${MAIN_LOG}" 2>/dev/null || true
fi

# Binários
readonly PROFILES_CMD="/usr/bin/profiles"

# Variável para jq (herdada do migracao_principal.sh ou detectada localmente)
JQ_BIN="${JQ_BIN:-}"

###############################################################################
# FUNÇÃO: Detectar jq se não foi herdado
###############################################################################
detect_jq_if_needed() {
    # Se JQ_BIN já está definida (herdada do pai), não faz nada
    if [[ -n "${JQ_BIN}" ]] && [[ -f "${JQ_BIN}" ]]; then
        return 0
    fi

    # Detectar arquitetura
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

# Função de logging
log_message() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] $1" | tee -a "${MAIN_LOG}"
}

log_success() {
    log_message "✓ $1"
}

log_warning() {
    log_message "⚠ AVISO: $1"
}

###############################################################################
# VALIDAÇÕES
###############################################################################

log_message "========================================="
log_message "VALIDAÇÃO DE ESTADO DO MAC"
log_message "========================================="

# Detectar jq se necessário
detect_jq_if_needed

# 1. Verificar se está rodando como root
log_message "1. Verificando permissões..."
if [[ $EUID -ne 0 ]]; then
    log_message "✗ Este script precisa ser executado como root"
    exit 1
fi
log_success "Script executando como root"

# 2. Verificar versão do macOS
log_message "2. Verificando versão do macOS..."
OS_VERSION=$(sw_vers -productVersion)
OS_MAJOR=$(echo "$OS_VERSION" | cut -d. -f1)

log_message "   Versão do macOS: ${OS_VERSION}"

if [[ $OS_MAJOR -lt 11 ]]; then
    log_message "✗ macOS deve ser 11.0 (Big Sur) ou superior. Versão atual: ${OS_VERSION}"
    exit 1
else
    log_success "Versão do macOS compatível"
fi

# 3. Detectar MDM através do profiles status
log_message "3. Verificando enrollment MDM..."

# Obter status completo do MDM
MDM_ENROLLMENT=$("${PROFILES_CMD}" status -type enrollment 2>/dev/null)

# Variáveis de controle
MDM_ENROLLED=false
MDM_SERVER=""
MDM_TYPE="none"

# Verificar se há enrollment MDM ativo
if echo "${MDM_ENROLLMENT}" | grep -q "MDM enrollment: Yes"; then
    MDM_ENROLLED=true

    # Extrair servidor MDM
    MDM_SERVER=$(echo "${MDM_ENROLLMENT}" | grep "MDM server:" | cut -d: -f2- | xargs)

    log_message "   MDM Enrollment: Sim"
    log_message "   Servidor MDM: ${MDM_SERVER}"

    # Identificar tipo de MDM baseado no servidor
    if echo "${MDM_SERVER}" | grep -qi "jamf"; then
        MDM_TYPE="jamf"
        log_success "Detectado: Jamf Pro"
    elif echo "${MDM_SERVER}" | grep -qi "microsoft\|intune\|manage.microsoft.com"; then
        MDM_TYPE="intune"
        log_success "Detectado: Microsoft Intune"
    else
        MDM_TYPE="unknown"
        log_warning "MDM desconhecido: ${MDM_SERVER}"
    fi

    # Verificar se é User Approved
    if echo "${MDM_ENROLLMENT}" | grep -q "User Approved"; then
        log_message "   User Approved: Sim"
    else
        log_warning "MDM não é User Approved - pode ser necessária interação do usuário"
    fi
else
    log_message "   MDM Enrollment: Não"
fi

# 4. Criar arquivo de estado
log_message "4. Criando arquivo de estado..."

CURRENT_USER=$(stat -f "%Su" /dev/console 2>/dev/null || echo "none")
AVAILABLE_SPACE=$(df -g / 2>/dev/null | awk 'NR==2 {print $4}')

cat >"${STATE_FILE}" <<EOF
{
    "validation_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "os_version": "${OS_VERSION}",
    "current_user": "${CURRENT_USER}",
    "disk_space_gb": ${AVAILABLE_SPACE:-0},
    "mdm_enrolled": ${MDM_ENROLLED},
    "mdm_server": "${MDM_SERVER}",
    "mdm_type": "${MDM_TYPE}",
    "needs_migration": false,
    "migration_status": ""
}
EOF

log_success "Arquivo de estado criado: ${STATE_FILE}"

###############################################################################
# FUNÇÃO: Atualizar estado usando jq (mais seguro que sed)
###############################################################################
update_state_with_jq() {
    local field="$1"
    local value="$2"

    if [[ -n "${JQ_BIN}" ]] && [[ -f "${JQ_BIN}" ]]; then
        local temp_file="${STATE_FILE}.tmp"
        "${JQ_BIN}" ".${field} = \"${value}\"" "${STATE_FILE}" >"${temp_file}" 2>/dev/null
        if [[ -f "${temp_file}" ]]; then
            mv "${temp_file}" "${STATE_FILE}"
            return 0
        fi
    fi

    # Fallback: usar sed se jq falhar
    sed -i '' "s/\"${field}\": \"[^\"]*\"/\"${field}\": \"${value}\"/" "${STATE_FILE}" 2>/dev/null || true
}

###############################################################################
# LÓGICA DE DECISÃO
###############################################################################

log_message "========================================="

# CASO 1: Já está no Jamf - SUCESSO, não faz nada
if [[ "${MDM_TYPE}" == "jamf" ]]; then
    log_message "✓ VALIDAÇÃO CONCLUÍDA COM SUCESSO"
    log_message "  Mac já está enrollado no Jamf Pro"
    log_message "  Servidor: ${MDM_SERVER}"
    log_message "  Nenhuma ação necessária"
    log_message "========================================="

    # Atualizar estado
    update_state_with_jq "migration_status" "already_in_jamf"

    exit 0
fi

# CASO 2: Está no Intune - PRECISA MIGRAR
if [[ "${MDM_TYPE}" == "intune" ]]; then
    log_message "✓ VALIDAÇÃO CONCLUÍDA COM SUCESSO"
    log_message "  Mac está enrollado no Intune"
    log_message "  Servidor: ${MDM_SERVER}"
    log_message "  Migração necessária para Jamf Pro"
    log_message "========================================="

    # Atualizar estado usando jq (mais complexo - múltiplos campos)
    if [[ -n "${JQ_BIN}" ]] && [[ -f "${JQ_BIN}" ]]; then
        temp_file="${STATE_FILE}.tmp"
        "${JQ_BIN}" '.needs_migration = true | .migration_status = "needs_migration"' \
            "${STATE_FILE}" >"${temp_file}" 2>/dev/null
        if [[ -f "${temp_file}" ]]; then
            mv "${temp_file}" "${STATE_FILE}"
        fi
    else
        # Fallback: usar sed
        sed -i '' 's/"needs_migration": false/"needs_migration": true/' "${STATE_FILE}" 2>/dev/null || true
        sed -i '' 's/"migration_status": ""/"migration_status": "needs_migration"/' "${STATE_FILE}" 2>/dev/null || true
    fi

    # Código 10 = precisa migrar
    exit 10
fi

# CASO 3: Não está em nenhum MDM - ENROLLAR NO JAMF
if [[ "${MDM_TYPE}" == "unknown" ]]; then
    log_message "✗ VALIDAÇÃO FALHOU"
    log_message "  Mac está gerenciado por MDM desconhecido"
    log_message "  Servidor: ${MDM_SERVER}"
    log_message "  Não é possível realizar migração"
    log_message "========================================="

    update_state_with_jq "migration_status" "unknown_mdm"
    exit 1
else
    # SEM MDM - Enrollar direto no Jamf
    log_message "⚠ VALIDAÇÃO - SEM MDM ATIVO"
    log_message "  Mac não está gerenciado por nenhum MDM"
    log_message "  Será enrollado diretamente no Jamf Pro"
    log_message "========================================="

    update_state_with_jq "migration_status" "no_mdm_enroll_jamf"

    # Código 20 = sem MDM, enrollar direto no Jamf
    exit 20
fi
log_message "========================================="

# Atualizar estado
update_state_with_jq "migration_status" "not_managed"

exit 1
