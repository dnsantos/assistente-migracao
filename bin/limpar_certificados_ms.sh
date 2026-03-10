#!/bin/bash

###############################################################################
# limpar_certificados_ms.sh
# Remove certificado MS-ORGANIZATION-ACCESS do keychain do usuário
#
# Versão: 1.0
# Data: 2025-11-11
#
# Exit Codes:
#   0 - Sucesso (certificado removido ou não encontrado)
#   1 - Erro (não está rodando como root ou usuário não logado)
###############################################################################

# Variáveis
readonly BASE_DIR="/Library/Application Support/Assistente de Migracao"
readonly LOGS_DIR="${BASE_DIR}/logs"
readonly MAIN_LOG="${LOGS_DIR}/migracao.log"
readonly DIALOG_LOG="/var/tmp/dialog_migration.log"

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
# FUNÇÃO: Atualizar Dialog (opcional)
###############################################################################
update_dialog() {
    local statustext="$1"

    if [[ -f "${DIALOG_LOG}" ]]; then
        echo "listitem: index: 2, statustext: ${statustext}" >>"${DIALOG_LOG}"
    fi
}

###############################################################################
# INICIALIZAÇÃO
###############################################################################

log_message "========================================="
log_message "REMOVENDO CERTIFICADO MS-ORGANIZATION-ACCESS"
log_message "========================================="

# Verificar se está rodando como root
if [[ $EUID -ne 0 ]]; then
    log_message "✗ Este script precisa ser executado como root"
    exit 1
fi

# Obter usuário logado
LOGGED_USER=$(stat -f "%Su" /dev/console 2>/dev/null || echo "none")

if [[ "$LOGGED_USER" == "none" ]] || [[ "$LOGGED_USER" == "root" ]]; then
    log_message "⚠ Nenhum usuário logado - não é possível remover certificado"
    update_dialog "⚠ Nenhum usuário logado"
    exit 1
fi

log_message "Usuário logado: ${LOGGED_USER}"

###############################################################################
# FUNÇÃO: Remover MS-ORGANIZATION-ACCESS do keychain do usuário
###############################################################################
delete_ms_organization_access() {
    local user_keychain="/Users/${LOGGED_USER}/Library/Keychains/login.keychain-db"

    if [[ ! -f "$user_keychain" ]]; then
        log_message "✗ Keychain do usuário não encontrado: ${user_keychain}"
        update_dialog "✗ Keychain não encontrado"
        return 1
    fi

    log_message "Procurando certificado MS-ORGANIZATION-ACCESS..."
    update_dialog "🔍 Procurando MS-ORGANIZATION-ACCESS..."

    # Buscar certificado no keychain
    KEY_INFO=$(security find-certificate -a "$user_keychain" 2>/dev/null)

    sleep 1 # Opcional, para visualização

    if [[ -n "$KEY_INFO" ]]; then
        # Verificar se MS-ORGANIZATION-ACCESS existe
        if echo "$KEY_INFO" | grep -qi "MS-ORGANIZATION-ACCESS"; then
            log_message "   ✓ Certificado MS-ORGANIZATION-ACCESS encontrado"
            update_dialog "🧹 Removendo certificado..."

            # Extrair nome do certificado
            CERT_INFO=$(echo "$KEY_INFO" | grep -B 10 "MS-ORGANIZATION-ACCESS" | grep '"alis"' | cut -d'"' -f4)

            if [[ -n "$CERT_INFO" ]]; then
                log_message "   Nome do certificado: ${CERT_INFO}"

                # Remover certificado
                if /usr/bin/security delete-certificate -c "$CERT_INFO" "$user_keychain" >/dev/null 2>&1; then
                    log_message "   ✓ Certificado removido com sucesso"
                    update_dialog "✅ Certificado removido"
                    sleep 60
                    return 0
                else
                    log_message "   ✗ Falha ao remover; verifique permissões ou unicidade"
                    update_dialog "⚠ Falha ao remover certificado"
                    return 1
                fi
            else
                log_message "   ⚠ Não foi possível extrair nome do certificado"
                update_dialog "⚠ Erro ao extrair nome"
                return 1
            fi
        else
            log_message "   ✓ Certificado MS-ORGANIZATION-ACCESS não encontrado"
            update_dialog "✅ Certificado não encontrado"
            return 0
        fi
    else
        log_message "   ✓ Nenhum certificado encontrado no keychain"
        update_dialog "✅ Keychain vazio"
        return 0
    fi
}

###############################################################################
# MAIN
###############################################################################

delete_ms_organization_access

log_message "========================================="
log_message "✓ VERIFICAÇÃO CONCLUÍDA"
log_message "========================================="

exit 0
