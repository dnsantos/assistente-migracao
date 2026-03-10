# Assistente de Migração Globo — Documentação Técnica

> Migração automatizada de Macs do **Microsoft Intune** para o **Jamf Pro**

---

## Sumário

1. [Visão Geral](#visão-geral)
2. [Pré-requisitos](#pré-requisitos)
3. [Estrutura do Projeto](#estrutura-do-projeto)
4. [Configuração](#configuração)
5. [Fluxo de Execução](#fluxo-de-execução)
6. [Scripts — Referência](#scripts--referência)
7. [Códigos de Saída](#códigos-de-saída)
8. [Arquivo de Estado](#arquivo-de-estado)
9. [Logs](#logs)
10. [Notificações Teams](#notificações-teams)
11. [Interface Visual (swiftDialog)](#interface-visual-swiftdialog)
12. [Dependências Externas](#dependências-externas)
13. [Segurança e Credenciais](#segurança-e-credenciais)
14. [Troubleshooting](#troubleshooting)

---

## Visão Geral

O **Assistente de Migração Globo** é um conjunto de scripts Bash que orquestra a migração completa de Macs corporativos do Microsoft Intune para o Jamf Pro. O processo é automatizado, com interface visual via **swiftDialog** e notificações em tempo real para um canal do **Microsoft Teams**.

### Casos suportados

| Cenário | Comportamento |
|---|---|
| Mac já no Jamf Pro | Executa pós-migração e encerra sem alterações |
| Mac no Microsoft Intune | Fluxo completo: remove Intune → enrola no Jamf |
| Mac sem MDM ativo | Remove certificados residuais → enrola direto no Jamf |
| MDM desconhecido | Aborta com erro — requer intervenção manual |

---

## Pré-requisitos

- macOS 11 (Big Sur) ou superior
- Execução como **root** (via Jamf Policy, ARD ou similar)
- Mac registrado no **Apple Business Manager (ABM)**
- Mac atribuído ao **PreStage de Enrollment** no Jamf Pro
- Credenciais de **App Registration** no Azure AD com permissão `DeviceManagementManagedDevices.ReadWrite.All`
- Conectividade com:
  - `login.microsoftonline.com` — autenticação OAuth
  - `graph.microsoft.com` — API do Intune
  - `api.github.com` — download do swiftDialog
  - Servidor MDM do Jamf Pro

---

## Estrutura do Projeto

```
assistente-migracao/
├── bin/
│   ├── migracao_principal.sh        # Orquestrador principal
│   ├── validacao_pre_migracao.sh    # Passo 1 — Validação de estado
│   ├── instalar_dependencias.sh     # Passo 2 — Instalação do swiftDialog
│   ├── remover_intune.sh            # Passo 3 — Remoção do Intune via Graph API
│   ├── limpar_certificados_ms.sh    # Passo 3b — Limpeza de certificados MS
│   ├── instalar_jamf.sh             # Passo 4 — Enrollment no Jamf Pro
│   ├── pos_migracao.sh              # Passo 5 — Finalização e limpeza
│   ├── notificar_teams.sh           # Envio de notificações ao Teams
│   ├── jq-macos-arm64               # Binário jq para Apple Silicon
│   └── jq-macos-amd64               # Binário jq para Intel
├── html/
│   ├── index.html                   # Página de boas-vindas
│   ├── novidades.html               # O que vai mudar
│   ├── beneficios.html              # Benefícios da migração
│   ├── faq.html                     # Perguntas frequentes
│   └── css/app-globo.css
└── resources/
    └── config/
        ├── migration_config.json    # Configurações e credenciais
        └── dialog_list.json         # Estrutura da lista do swiftDialog
```

---

## Configuração

Antes de distribuir o pacote, edite o arquivo `resources/config/migration_config.json`:

```json
{
  "intune": {
    "tenant_id": "SEU_TENANT_ID",
    "client_id": "SEU_CLIENT_ID",
    "teams_webhook_url": "https://outlook.office.com/webhook/...",
    "removal_timeout": 300
  },
  "organization": {
    "name": "Globo",
    "notification_email": "suporte@globo.com"
  },
  "settings": {
    "debug_mode": false,
    "log_level": "info"
  }
}
```

### Client Secret

O `client_secret` **não** é armazenado no JSON por segurança. Ele deve ser provisionado no Keychain do sistema antes da execução:

```bash
security add-generic-password \
  -s "GloboMigrationService" \
  -a "IntuneAuth" \
  -w "SEU_CLIENT_SECRET" \
  /Library/Keychains/System.keychain
```

---

## Fluxo de Execução

```
migracao_principal.sh
│
├── [Passo 1] validacao_pre_migracao.sh
│     ├── exit 0  → Mac já no Jamf  → pós-migração → fim
│     ├── exit 10 → Mac no Intune   → continua fluxo completo
│     ├── exit 20 → Sem MDM         → pula remoção, enrola no Jamf
│     └── exit 1  → Erro/MDM desconhecido → aborta
│
├── [Passo 2] instalar_dependencias.sh
│     └── Baixa e instala swiftDialog via GitHub Releases
│         Verifica assinatura (Team ID: PWA5E9TQ59)
│
├── [Passo 3] remover_intune.sh  (somente se exit 10)
│     ├── Obtém token OAuth do Azure AD
│     ├── Localiza dispositivo por serial na Graph API
│     ├── Executa retire via POST /managedDevices/{id}/retire
│     └── Monitora remoção do perfil MDM (loop infinito até confirmação)
│         └── limpar_certificados_ms.sh
│               └── Remove MS-ORGANIZATION-ACCESS do keychain do usuário
│
├── [Passo 4] instalar_jamf.sh
│     ├── Executa `profiles renew -type enrollment`
│     ├── Monitora enrollment (20 tentativas × 30s = 10 min)
│     └── Executa `jamf startup` para validar JSS
│
└── [Passo 5] pos_migracao.sh
      ├── jamf recon
      ├── Limpeza de arquivos temporários
      ├── Rotação de logs (máx. 10 MB / 7 dias)
      ├── Atualiza migration_state.json com status "completed"
      └── Agenda autoeliminação da pasta do assistente
```

---

## Scripts — Referência

### `migracao_principal.sh`
Script orquestrador. Deve ser o único ponto de entrada.

- Detecta arquitetura e configura `JQ_BIN` (exportado para scripts filhos)
- Inicia interface swiftDialog se já disponível; caso contrário, aguarda instalação no Passo 2
- Gerencia atualizações da lista visual (`update_list_item index status statustext`)

### `validacao_pre_migracao.sh`
Valida o estado atual e cria `migration_state.json`.

- Verifica macOS ≥ 11
- Detecta MDM via `profiles status -type enrollment`
- Identifica Jamf, Intune ou ausência de MDM pelo campo `MDM server`

### `instalar_dependencias.sh`
Instala o swiftDialog a partir da última release do GitHub.

- Usa `jq` para parsear resposta da API `github.com/repos/swiftDialog/swiftDialog/releases/latest`
- Verifica Team ID do PKG antes de instalar (`PWA5E9TQ59`)

### `remover_intune.sh`
Remove o dispositivo do Intune via Microsoft Graph API.

- Autenticação OAuth 2.0 com `client_credentials`
- Busca dispositivo por `serialNumber`
- Executa `POST /retire` e aguarda a remoção do perfil MDM em loop

### `limpar_certificados_ms.sh`
Remove o certificado `MS-ORGANIZATION-ACCESS` do keychain do usuário logado.

- Usa `security find-certificate` e `security delete-certificate`
- Requer usuário ativo na sessão (não executa se nenhum usuário estiver logado)

### `instalar_jamf.sh`
Enrola o Mac no Jamf Pro via ABM PreStage.

- Executa `profiles renew -type enrollment`
- Monitora enrollment por até 10 minutos (20 × 30s)
- Verifica presença do binário `/usr/local/bin/jamf`

### `pos_migracao.sh`
Finalização e limpeza.

- Executa `jamf recon` para atualizar inventário
- Remove arquivos temporários em `/private/tmp`
- Rotaciona logs maiores que 10 MB
- Agenda limpeza da pasta do assistente via `nohup`

### `notificar_teams.sh`
Envia Adaptive Cards para o webhook do Microsoft Teams.

**Parâmetros:**
```bash
notificar_teams.sh "inicio"
notificar_teams.sh "concluido"
notificar_teams.sh "falha" "Mensagem de erro detalhada"
```

---

## Códigos de Saída

### `validacao_pre_migracao.sh`
| Código | Significado |
|---|---|
| `0` | Mac já está no Jamf Pro |
| `1` | Erro (sem root, macOS incompatível, MDM desconhecido) |
| `10` | Mac no Intune — migração necessária |
| `20` | Sem MDM — enrolar direto no Jamf |

### `migracao_principal.sh`
| Código | Significado |
|---|---|
| `0` | Migração concluída com sucesso |
| `1` | Falha na validação |
| `2` | Falha ao instalar dependências |
| `3` | Falha ao remover Intune |
| `4` | Falha ao enrolar no Jamf |

---

## Arquivo de Estado

Gerado em `/Library/Application Support/Assistente de Migracao/migration_state.json`:

```json
{
  "validation_date": "2025-11-12T14:30:00Z",
  "os_version": "14.6.1",
  "current_user": "joao.silva",
  "disk_space_gb": 120,
  "mdm_enrolled": true,
  "mdm_server": "https://empresa.jamfcloud.com",
  "mdm_type": "jamf",
  "needs_migration": false,
  "migration_status": "completed",
  "completion_date": "2025-11-12T14:45:00Z"
}
```

**Valores possíveis de `migration_status`:**

| Valor | Descrição |
|---|---|
| `already_in_jamf` | Mac já estava no Jamf ao iniciar |
| `needs_migration` | Migração necessária (Intune detectado) |
| `no_mdm_enroll_jamf` | Sem MDM, aguardando enrollment |
| `intune_removed` | Intune removido com sucesso |
| `jamf_enrolled` | Enrolled no Jamf com sucesso |
| `completed` | Pós-migração finalizada |
| `unknown_mdm` | MDM não reconhecido |

---

## Logs

Todos os scripts escrevem no log principal:

```
/Library/Application Support/Assistente de Migracao/logs/migracao.log
```

- Rotação automática quando o arquivo supera **10 MB**
- Arquivos rotacionados mantidos por **7 dias**
- Formato: `[YYYY-MM-DD HH:MM:SS] mensagem`

---

## Notificações Teams

O webhook deve ser configurado em `migration_config.json`. As notificações são enviadas nos seguintes momentos:

| Evento | Script chamador |
|---|---|
| Início da migração | `migracao_principal.sh` (implícito via fluxo) |
| Migração concluída | `pos_migracao.sh` |
| Falha em qualquer etapa | `migracao_principal.sh` |

O payload usa **Adaptive Cards v1.4** com FactSet contendo: nome da máquina, serial, usuário, horário de início/fim e duração.

---

## Interface Visual (swiftDialog)

A interface exibe uma lista de 5 itens com status em tempo real. A comunicação é feita via arquivo de comandos:

```
/var/tmp/dialog_migration.log
```

**Comandos suportados:**
```bash
# Atualizar item da lista
echo "listitem: index: 2, status: success, statustext: Concluído" >> $DIALOG_LOG

# Atualizar ícone
echo "icon: SF=checkmark.circle.fill,color=green" >> $DIALOG_LOG

# Atualizar mensagem principal
echo "message: Novo texto da mensagem" >> $DIALOG_LOG

# Encerrar o dialog
echo "quit:" >> $DIALOG_LOG
```

**Status disponíveis:** `pending`, `wait`, `success`, `fail`, `error`

---

## Dependências Externas

| Dependência | Versão | Fonte |
|---|---|---|
| swiftDialog | latest | GitHub Releases |
| jq | 1.7+ | Incluído no pacote (arm64 e amd64) |
| curl | nativo macOS | — |
| profiles | nativo macOS | — |
| security | nativo macOS | — |

---

## Segurança e Credenciais

- O `client_secret` é lido exclusivamente do **System Keychain** via `security find-generic-password`
- Nunca armazene segredos no `migration_config.json` em produção
- O PKG do swiftDialog é verificado por **Team ID** antes da instalação
- Logs não registram tokens de acesso ou segredos

---

## Troubleshooting

**swiftDialog não instala**
- Verificar conectividade com `api.github.com`
- Verificar se o Team ID `PWA5E9TQ59` está na allowlist do Gatekeeper/MDM

**Token OAuth falha**
- Confirmar que `tenant_id` e `client_id` estão corretos no config
- Verificar se o `client_secret` está no Keychain: `security find-generic-password -s GloboMigrationService -a IntuneAuth`
- Confirmar que a permissão `DeviceManagementManagedDevices.ReadWrite.All` está concedida no Azure AD

**Dispositivo não encontrado no Intune**
- Verificar se o serial number retornado por `system_profiler` bate com o registrado no Intune
- Confirmar que o dispositivo não foi já retirado manualmente

**Enrollment no Jamf não conclui**
- Verificar se o Mac está no ABM e associado ao PreStage correto
- Verificar conectividade com o servidor MDM do Jamf
- Aumentar o número de tentativas em `instalar_jamf.sh` (variável `checks`)

**Certificado MS-ORGANIZATION-ACCESS não é removido**
- Confirmar que há um usuário ativo na sessão (não funciona em contexto headless sem usuário)
- Verificar permissões do keychain: `security list-keychains -d user`