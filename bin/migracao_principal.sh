#!/bin/bash

###############################################################################
# migracao_principal.sh
# Orquestra todo o processo de migração Intune → Jamf
#
# Autor: Assistente de Migração Globo
# Versão: 1.1
# Data: 2025-11-12
#
# Descrição:
#   Script orquestrador que executa a migração completa de Macs do Microsoft
#   Intune para o Jamf Pro. Inicia em modo texto e carrega interface visual
#   após instalar o swiftDialog no Passo 2.
#
# Fluxo:
#   1. Validação (sem Dialog)
#   2. Instalação de Dependências → instala Dialog
#   3. Remoção do Intune (com Dialog)
#   4. Instalação do Jamf (com Dialog)
#   5. Finalização (com Dialog)
#
# Exit Codes:
#   0 - Sucesso (migração concluída ou já no Jamf)
#   1 - Falha na validação
#   2 - Falha nas dependências
#   3 - Falha ao remover Intune
#   4 - Falha ao instalar Jamf
#
###############################################################################

# Variáveis
readonly BASE_DIR="/Library/Application Support/Assistente de Migracao"
readonly BIN_DIR="${BASE_DIR}/bin"
readonly LOGS_DIR="${BASE_DIR}/logs"
readonly MAIN_LOG="${LOGS_DIR}/migracao.log"
readonly DIALOG_BIN="/usr/local/bin/dialog"
readonly DIALOG_LOG="/var/tmp/dialog_migration.log"
readonly JSON_TEMPLATE="${BASE_DIR}/resources/config"
readonly STATE_FILE="${BASE_DIR}/migration_state.json"

# Flag para controlar se Dialog está disponível
DIALOG_AVAILABLE=false

# Variável para jq (será detectada e exportada)
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
# FUNÇÃO: Atualizar valor no arquivo de estado JSON
###############################################################################
update_state_with_jq() {
    local key="$1"
    local value="$2"

    if [[ -z "${JQ_BIN}" ]] || [[ ! -f "${JQ_BIN}" ]]; then
        log_message "⚠ JQ não encontrado, não é possível atualizar o estado: ${key}=${value}"
        return 1
    fi

    if [[ ! -f "${STATE_FILE}" ]]; then
        # Se o arquivo não existir, cria um novo com a chave/valor
        echo "{}" >"${STATE_FILE}"
    fi

    # Usar um arquivo temporário para evitar corrupção
    local temp_file="${STATE_FILE}.tmp"

    # Atualizar o JSON
    "${JQ_BIN}" --arg key "$key" --arg value "$value" '.[$key] = $value' "${STATE_FILE}" >"${temp_file}" 2>/dev/null

    if [[ -f "${temp_file}" ]] && [[ -s "${temp_file}" ]]; then
        mv "${temp_file}" "${STATE_FILE}"
        return 0
    else
        log_message "✗ Falha ao atualizar o estado JSON para: ${key}=${value}"
        rm -f "${temp_file}" 2>/dev/null
        return 1
    fi
}

###############################################################################
# INICIALIZAÇÃO
###############################################################################
log_message "========================================="
log_message "ASSISTENTE DE MIGRAÇÃO GLOBO"
log_message "Intune → Jamf Pro"
log_message "========================================="

# Verificar se está rodando como root
if [[ $EUID -ne 0 ]]; then
    log_message "✗ Este script precisa ser executado como root"
    exit 1
fi

log_message "✓ Executando como root"

###############################################################################
# FUNÇÃO: Detectar arquitetura e configurar jq
###############################################################################
detect_and_setup_jq() {
    local arch=$(uname -m)

    log_message "Detectando arquitetura: ${arch}"

    if [[ "$arch" == "arm64" ]]; then
        JQ_BIN="${BIN_DIR}/jq-macos-arm64"
    elif [[ "$arch" == "x86_64" ]]; then
        JQ_BIN="${BIN_DIR}/jq-macos-amd64"
    else
        log_message "⚠ Arquitetura não suportada: ${arch}"
        return 1
    fi

    if [[ -f "${JQ_BIN}" ]]; then
        chmod +x "${JQ_BIN}" 2>/dev/null || true
        # Exportar para scripts filhos
        export JQ_BIN
        log_message "✓ jq configurado: ${JQ_BIN}"
        return 0
    else
        log_message "⚠ jq não encontrado: ${JQ_BIN}"
        return 1
    fi
}

###############################################################################
# FUNÇÃO: Verificar se Dialog está disponível
###############################################################################
check_dialog() {
    if [[ -f "${DIALOG_BIN}" ]]; then
        DIALOG_AVAILABLE=true
        log_message "✓ swiftDialog disponível"
        return 0
    else
        DIALOG_AVAILABLE=false
        log_message "⚠ swiftDialog não disponível ainda"
        return 1
    fi
}

###############################################################################
# FUNÇÃO: Iniciar Dialog com Lista
###############################################################################
start_migration_dialog() {
    if [[ "$DIALOG_AVAILABLE" != true ]]; then
        log_message "⚠ Dialog não disponível - pulando interface visual"
        return 1
    fi

    rm -f "${DIALOG_LOG}"

    log_message "Iniciando interface visual..."

    # Obter informações do Mac
    local machine_name=$(scutil --get ComputerName 2>/dev/null || hostname)
    local serial_number=$(system_profiler SPHardwareDataType | awk '/Serial/ {print $4}')

    "${DIALOG_BIN}" \
        --title "Assistente de Migração Globo" \
        --message "### Migração Intune → Jamf Pro<br><br>**Computador:** ${machine_name}<br>**Serial:** ${serial_number}<br><br>Acompanhe abaixo o progresso da migração, enquanto isso você pode utilizar sua máquina normalmente..." \
        --messagefont "size=13" \
        --icon "https://parsefiles.back4app.com/JPaQcFfEEQ1ePBxbf6wvzkPMEqKYHhPYv8boI1Rc/271fb25094f9a719db329f7b2a568d91_YoLKy0FGog.png" \
        --button1text "none" \
        --width 750 \
        --height 550 \
        --position "center" \
        --ontop \
        --moveable \
        --jsonfile "$JSON_TEMPLATE/dialog_list.json" \
        --commandfile "${DIALOG_LOG}" &

    sleep 2
    log_message "✓ Interface visual iniciada"
    return 0
}

###############################################################################
# FUNÇÃO: Atualizar item da lista
###############################################################################
update_list_item() {
    local index="$1"
    local status="$2" # wait, success, fail, error, pending
    local statustext="$3"

    if [[ "$DIALOG_AVAILABLE" == true ]] && [[ -f "${DIALOG_LOG}" ]]; then
        echo "listitem: index: ${index}, status: ${status}, statustext: ${statustext}" >>"${DIALOG_LOG}"
    fi
}

###############################################################################
# FUNÇÃO: Finalizar Dialog
###############################################################################
finish_migration_dialog() {
    local success="$1"
    local message="$2"

    if [[ "$DIALOG_AVAILABLE" != true ]] || [[ ! -f "${DIALOG_LOG}" ]]; then
        return 0
    fi

    if [[ $success -eq 0 ]]; then
        echo "icon: SF=checkmark.circle.fill,color=green" >>"${DIALOG_LOG}"
        echo "message: ### ✅ Migração Concluída!\n\n${message}\n\nO Mac foi migrado com sucesso do Intune para o Jamf Pro." >>"${DIALOG_LOG}"
        echo "button1text: Concluir" >>"${DIALOG_LOG}"
    else
        echo "icon: SF=xmark.circle.fill,color=red" >>"${DIALOG_LOG}"
        echo "message: ### ✗ Falha na Migração\n\n${message}\n\nVerifique os logs para mais detalhes." >>"${DIALOG_LOG}"
        echo "button1text: Fechar" >>"${DIALOG_LOG}"
    fi

    sleep 5
    echo "quit:" >>"${DIALOG_LOG}"
    rm -f "${DIALOG_LOG}"
}

###############################################################################
# Setup inicial
###############################################################################

# Detectar e configurar jq
detect_and_setup_jq

# Verificar Dialog inicial
check_dialog

# *** CORREÇÃO: Iniciar Dialog AGORA se disponível ***
if [[ "$DIALOG_AVAILABLE" == true ]]; then
    log_message "✓ swiftDialog disponível - iniciando interface visual"
    "$DIALOG_BIN" \
        --title "Globo Assist" \
        --icon "$BASE_DIR/html/images/new_logo_globo.png" \
        --overlayicon "$BASE_DIR/html/images/apple_logo.svg" \
        --messagefont "size=13" \
        --message 'Assim como a **Globo celebra 100 anos de criatividade e inovação**, seu Mac está entrando em um novo capítulo: _mais conectado, seguro e preparado para as próximas décadas_.<br><br>Para fortalecer nossa cultura digital e garantir ainda mais proteção aos dados e produtividade de todos, implementaremos uma _**nova ferramenta de gestão para o ambiente Apple**_.<br><br>Essa migração não é apenas tecnológica — ela é parte de um conjunto de iniciativas que visam um futuro mais **digital** e **colaborativo**, onde tecnologia, segurança e experiência do usuário caminham juntos.<br><br>Nosso compromisso é conectar e potencializar talentos, histórias e inovação.<br><br>**Bem-vindo à próxima geração Apple na Globo!**' \
        --button1text "Iniciar migração" \
        --infobuttontext "Saber mais" \
        --infobuttonaction "file://$BASE_DIR/html/index.html" \
        --hidedefaultkeyboardaction

    start_migration_dialog
    sleep 2 # Aguardar Dialog inicializar
else
    log_message "========================================="
    log_message "MODO TEXTO - Interface visual será carregada após instalar dependências"
    log_message "Acompanhe o progresso nos logs: ${MAIN_LOG}"
    log_message "========================================="
fi

###############################################################################
# PASSO 1: VALIDAÇÃO
###############################################################################

log_message ""
log_message "Passo 1/5: Validando estado do Mac..."
update_list_item 0 "wait" "Validando estado do Mac..."

if [[ ! -f "${BIN_DIR}/validacao_pre_migracao.sh" ]]; then
    log_message "✗ Script não encontrado: validacao_pre_migracao.sh"
    update_list_item 0 "error" "Script não encontrado"
    finish_migration_dialog 1 "Script de validação não encontrado"
    "${BIN_DIR}/notificar_teams.sh" "falha" "Script de validação não encontrado" &
    exit 1
fi

"${BIN_DIR}/validacao_pre_migracao.sh"
VALIDATION_RESULT=$?

# Verificar resultado da validação
if [[ $VALIDATION_RESULT -eq 0 ]]; then
    # CASO 1: Mac já está no Jamf - SUCESSO
    log_message "Mac já está no Jamf - nenhuma ação necessária"
    update_list_item 0 "success" "Mac já está no Jamf"

    # Marcar todos os outros como não necessários
    update_list_item 1 "success" "Não necessário"
    update_list_item 2 "success" "Não necessário"
    update_list_item 3 "success" "Não necessário"

    log_message ""
    log_message "Passo 5/5: Finalizando migração..."
    update_list_item 4 "wait" "Executando limpeza final..."

    if [[ -f "${BIN_DIR}/pos_migracao.sh" ]]; then
        "${BIN_DIR}/pos_migracao.sh"
        log_message "✓ Pós-migração concluída"
        update_list_item 4 "success" "Finalização concluída"
    else
        log_message "⚠ Script pos_migracao.sh não encontrado (pulando)"
        update_list_item 4 "success" "Não necessário"
    fi

    finish_migration_dialog 0 "Este Mac já está configurado corretamente no Jamf Pro."
    "${BIN_DIR}/notificar_teams.sh" "concluido" &
    exit 0

elif [[ $VALIDATION_RESULT -eq 10 ]]; then
    # CASO 2: Mac está no Intune - MIGRAÇÃO COMPLETA
    log_message "✓ Validação concluída - Mac está no Intune"
    update_list_item 0 "success" "Mac encontrado no Intune"

    # Continua para Passo 2 (Dependências) → Passo 3 (Remover Intune) → Passo 4 (Jamf)

elif [[ $VALIDATION_RESULT -eq 20 ]]; then
    # CASO 3: Sem MDM - ENROLLAR DIRETO NO JAMF
    log_message "✓ Validação concluída - Mac sem MDM, enrollar no Jamf"
    update_list_item 0 "success" "Sem MDM - enrollar no Jamf"

    # Marcar Passo 2 como não necessário
    log_message ""
    log_message "Passo 2/5: Instalando dependências..."
    update_list_item 1 "success" "Não necessário"

    # NOVO: Executar limpeza de certificados Microsoft mesmo sem MDM ativo
    log_message ""
    log_message "Passo 3/5: Limpando certificados Microsoft residuais..."
    update_list_item 2 "wait" "Removendo certificados Microsoft..."

    if [[ -f "${BIN_DIR}/limpar_certificados_ms.sh" ]]; then
        "${BIN_DIR}/limpar_certificados_ms.sh"
        if [[ $? -eq 0 ]]; then
            log_message "✓ Certificados Microsoft verificados/removidos"
            update_list_item 2 "success" "Certificados Microsoft removidos"
        else
            log_message "⚠ Falha ao limpar certificados (não crítico)"
            update_list_item 2 "success" "Verificado (com avisos)"
        fi
    else
        log_message "⚠ Script limpar_certificados_ms.sh não encontrado (pulando)"
        update_list_item 2 "success" "Não disponível"
    fi

    # IR DIRETO PARA PASSO 4

else
    # ERRO na validação (MDM desconhecido ou outro erro)
    log_message "✗ Falha na validação (código: ${VALIDATION_RESULT})"
    update_list_item 0 "fail" "Falha na validação"

    local error_message="Erro durante a validação.\n\nVerifique os logs para mais detalhes."
    if [[ $VALIDATION_RESULT -eq 1 ]]; then
        error_message="Mac está gerenciado por MDM desconhecido.\n\nEste assistente só funciona para Intune ou sem MDM."
    fi

    finish_migration_dialog 1 "${error_message}"
    "${BIN_DIR}/notificar_teams.sh" "falha" "${error_message}" &
    exit 1
fi

###############################################################################
# PASSO 2: DEPENDÊNCIAS (só executar se não for exit code 20)
###############################################################################

if [[ $VALIDATION_RESULT -ne 20 ]]; then
    log_message ""
    log_message "Passo 2/5: Instalando dependências..."
    update_list_item 1 "wait" "Instalando swiftDialog..."

    if [[ -f "${BIN_DIR}/instalar_dependencias.sh" ]]; then
        "${BIN_DIR}/instalar_dependencias.sh"
        if [[ $? -ne 0 ]]; then
            log_message "✗ Falha ao instalar dependências"
            update_list_item 1 "fail" "Falha ao instalar dependências"
            finish_migration_dialog 1 "Erro ao instalar dependências necessárias"
            "${BIN_DIR}/notificar_teams.sh" "falha" "Erro ao instalar dependências necessárias" &
            exit 2
        fi
        log_message "✓ Dependências instaladas"
        update_list_item 1 "success" "Dependências instaladas"

        # Iniciar Dialog se foi instalado agora
        if [[ "$DIALOG_AVAILABLE" == false ]]; then
            check_dialog
            if [[ "$DIALOG_AVAILABLE" == true ]]; then
                start_migration_dialog
                sleep 3
                update_list_item 0 "success" "Mac encontrado no Intune"
                update_list_item 1 "success" "Dependências instaladas"
            fi
        fi
    else
        log_message "⚠ Script de dependências não encontrado (pulando)"
        update_list_item 1 "success" "Não necessário"
    fi
fi

###############################################################################
# PASSO 3: REMOVER INTUNE E LIMPAR CERTIFICADOS (continuação)
###############################################################################

if [[ $VALIDATION_RESULT -eq 10 ]]; then
    # CASO: Mac no Intune - remover enrollment

    log_message ""
    log_message "Passo 3/5: Removendo enrollment do Intune..."
    update_list_item 2 "wait" "Conectando ao Intune..."

    if [[ -f "${BIN_DIR}/remover_intune.sh" ]]; then
        "${BIN_DIR}/remover_intune.sh"
        if [[ $? -ne 0 ]]; then
            log_message "✗ Falha ao remover Intune"
            update_list_item 2 "fail" "Falha ao remover Intune"
            finish_migration_dialog 1 "Não foi possível remover o gerenciamento do Intune"
            "${BIN_DIR}/notificar_teams.sh" "falha" "Não foi possível remover o gerenciamento do Intune" &
            exit 3
        fi
        log_message "✓ Intune removido com sucesso"

        # Após remover Intune, limpar certificados Microsoft
        update_list_item 2 "wait" "Removendo certificados Microsoft..."

        if [[ -f "${BIN_DIR}/limpar_certificados_ms.sh" ]]; then
            "${BIN_DIR}/limpar_certificados_ms.sh"
            log_message "✓ Certificados Microsoft removidos"
        fi

        update_list_item 2 "success" "Intune removido com sucesso"
    else
        log_message "✗ Script remover_intune.sh não encontrado"
        update_list_item 2 "error" "Script não encontrado"
        finish_migration_dialog 1 "Script de remoção do Intune não encontrado"
        "${BIN_DIR}/notificar_teams.sh" "falha" "Script de remoção do Intune não encontrado" &
        exit 3
    fi

elif [[ $VALIDATION_RESULT -eq 20 ]]; then
    # CASO: Sem MDM - apenas limpar certificados residuais

    log_message ""
    log_message "Passo 3/5: Limpando certificados Microsoft residuais..."
    update_list_item 2 "wait" "Removendo certificados Microsoft..."

    if [[ -f "${BIN_DIR}/limpar_certificados_ms.sh" ]]; then
        "${BIN_DIR}/limpar_certificados_ms.sh"
        log_message "✓ Certificados Microsoft verificados/removidos"
        update_list_item 2 "success" "Certificados Microsoft removidos"
    else
        log_message "⚠ Script limpar_certificados_ms.sh não encontrado (pulando)"
        update_list_item 2 "success" "Não disponível"
    fi
fi

###############################################################################
# PASSO 4: INSTALAR JAMF (SEMPRE executar)
###############################################################################

log_message ""
log_message "Passo 4/5: Instalando e enrollando no Jamf..."
update_list_item 3 "wait" "Preparando enrollment no Jamf..."

if [[ -f "${BIN_DIR}/instalar_jamf.sh" ]]; then
    "${BIN_DIR}/instalar_jamf.sh"
    if [[ $? -ne 0 ]]; then
        log_message "✗ Falha ao enrollar no Jamf"
        update_list_item 3 "fail" "Falha ao enrollar no Jamf"
        finish_migration_dialog 1 "Não foi possível enrollar no Jamf Pro"
        "${BIN_DIR}/notificar_teams.sh" "falha" "Não foi possível enrollar no Jamf Pro" &
        exit 4
    fi
    log_message "✓ Jamf enrollado com sucesso"
    update_list_item 3 "success" "Jamf enrollado com sucesso"
else
    log_message "✗ Script instalar_jamf.sh não encontrado"
    update_list_item 3 "error" "Script não encontrado"
    finish_migration_dialog 1 "Script de enrollment do Jamf não encontrado"
    "${BIN_DIR}/notificar_teams.sh" "falha" "Script de enrollment do Jamf não encontrado" &
    exit 4
fi

###############################################################################
# PASSO 5: PÓS-MIGRAÇÃO
###############################################################################

log_message ""
log_message "Passo 5/5: Finalizando migração..."
update_list_item 4 "wait" "Executando limpeza final..."

if [[ -f "${BIN_DIR}/pos_migracao.sh" ]]; then
    "${BIN_DIR}/pos_migracao.sh"
    log_message "✓ Pós-migração concluída"
    update_list_item 4 "success" "Finalização concluída"
else
    log_message "⚠ Script pos_migracao.sh não encontrado (pulando)"
    update_list_item 4 "success" "Não necessário"
fi

###############################################################################
# CONCLUSÃO
###############################################################################

log_message ""
log_message "========================================="
log_message "✓ MIGRAÇÃO CONCLUÍDA COM SUCESSO"
log_message "Tempo total: ~$((SECONDS / 60)) minuto(s)"
log_message "========================================="

finish_migration_dialog 0 "Todas as etapas foram concluídas com sucesso!"

exit 0
