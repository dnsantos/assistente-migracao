# Assistente de Migração Globo

> Migração automatizada de Macs corporativos do **Microsoft Intune** para o **Jamf Pro**

![macOS](https://img.shields.io/badge/macOS-11%2B-blue?logo=apple) ![Shell](https://img.shields.io/badge/Shell-Bash-green?logo=gnubash) ![Versão](https://img.shields.io/badge/versão-1.1-lightgrey) ![Equipe](https://img.shields.io/badge/equipe-Modern%20Workplace%20Globo-blue)

---

## Sumário

- [Visão Geral](#visão-geral)
- [Cenários Suportados](#cenários-suportados)
- [Pré-requisitos](#pré-requisitos)
- [Estrutura do Projeto](#estrutura-do-projeto)
- [Configuração](#configuração)
- [Como Executar](#como-executar)
- [Fluxo de Execução](#fluxo-de-execução)
- [Documentação](#documentação)
- [Dependências](#dependências)

---

## Visão Geral

O **Assistente de Migração Globo** é um conjunto de scripts Bash que orquestra a migração completa de Macs corporativos do Microsoft Intune para o Jamf Pro. O processo é totalmente automatizado, com interface visual via [swiftDialog](https://github.com/swiftDialog/swiftDialog) e notificações em tempo real para um canal do **Microsoft Teams**.

O script principal (`migracao_principal.sh`) detecta automaticamente o estado do Mac e executa apenas os passos necessários, sem intervenção manual.

---

## Cenários Suportados

| Estado do Mac | Ação executada | Código de saída |
|---|---|---|
| Já está no Jamf Pro | Executa pós-migração e encerra | `0` |
| Gerenciado pelo Intune | Fluxo completo: remove Intune → enrola no Jamf | `exit 10` (validação) |
| Sem MDM ativo | Limpa certificados MS residuais → enrola no Jamf | `exit 20` (validação) |
| MDM desconhecido | Aborta — requer intervenção manual | `1` |

---

## Pré-requisitos

- macOS 11 (Big Sur) ou superior
- Execução como **root** (via Jamf Policy, ARD ou similar)
- Mac registrado no **Apple Business Manager (ABM)**
- Mac atribuído a um **PreStage de Enrollment** no Jamf Pro
- **App Registration** no Azure AD com permissão `DeviceManagementManagedDevices.ReadWrite.All`
- `client_secret` provisionado no System Keychain antes da execução
- Conectividade com:
  - `login.microsoftonline.com`
  - `graph.microsoft.com`
  - `api.github.com`
  - Servidor MDM do Jamf Pro

---

## Estrutura do Projeto

```
assistente-migracao/
├── bin/
│   ├── migracao_principal.sh        # Orquestrador — único ponto de entrada
│   ├── validacao_pre_migracao.sh    # Passo 1 — valida estado e detecta MDM
│   ├── instalar_dependencias.sh     # Passo 2 — instala swiftDialog
│   ├── remover_intune.sh            # Passo 3 — remove dispositivo via Graph API
│   ├── limpar_certificados_ms.sh    # Passo 3b — remove MS-ORGANIZATION-ACCESS
│   ├── instalar_jamf.sh             # Passo 4 — enrollment no Jamf via ABM
│   ├── pos_migracao.sh              # Passo 5 — recon, limpeza e logs
│   ├── notificar_teams.sh           # Envia Adaptive Cards ao Teams
│   ├── jq-macos-arm64               # Binário jq para Apple Silicon
│   └── jq-macos-amd64               # Binário jq para Intel
├── html/
│   ├── index.html                   # Portal informativo — boas-vindas
│   ├── novidades.html               # O que vai mudar
│   ├── beneficios.html              # Benefícios da migração
│   ├── faq.html                     # Perguntas frequentes
│   └── css/app-globo.css
└── resources/
    └── config/
        ├── migration_config.json    # Credenciais e configurações
        └── dialog_list.json         # Estrutura da lista do swiftDialog
```

---

## Configuração

### 1. Edite o arquivo de configuração

Antes de distribuir o pacote, preencha `resources/config/migration_config.json`:

```json
{
  "intune": {
    "tenant_id":         "SEU_TENANT_ID",
    "client_id":         "SEU_CLIENT_ID",
    "teams_webhook_url": "https://outlook.office.com/webhook/...",
    "removal_timeout":   300
  },
  "organization": {
    "name":               "Globo",
    "notification_email": "suporte@globo.com"
  }
}
```

### 2. Provisione o Client Secret no Keychain

O `client_secret` **não** é armazenado no JSON. Adicione-o ao System Keychain do Mac antes de executar:

```bash
security add-generic-password \
  -s "GloboMigrationService" \
  -a "IntuneAuth" \
  -w "SEU_CLIENT_SECRET" \
  /Library/Keychains/System.keychain
```

> ⚠️ Nunca versione o `client_secret` no repositório.

---

## Como Executar

O script deve ser executado como root. Em produção, distribua via **Jamf Policy** ou **Apple Remote Desktop**:

```bash
sudo bash "/Library/Application Support/Assistente de Migracao/bin/migracao_principal.sh"
```

### Códigos de saída do orquestrador

| Código | Significado |
|---|---|
| `0` | Migração concluída com sucesso |
| `1` | Falha na validação |
| `2` | Falha ao instalar dependências |
| `3` | Falha ao remover Intune |
| `4` | Falha ao enrolar no Jamf |

---

## Fluxo de Execução

```
migracao_principal.sh
│
├── [Passo 1] validacao_pre_migracao.sh
│     ├── exit 0  → Mac já no Jamf  ──────────────────────────► pós-migração → fim
│     ├── exit 10 → Mac no Intune   → continua fluxo completo
│     ├── exit 20 → Sem MDM         → pula remoção, enrola no Jamf
│     └── exit 1  → Erro            → aborta
│
├── [Passo 2] instalar_dependencias.sh
│     └── Baixa swiftDialog (GitHub Releases)
│         Verifica assinatura PKG (Team ID: PWA5E9TQ59)
│
├── [Passo 3] remover_intune.sh
│     ├── OAuth 2.0 → Microsoft Graph API
│     ├── Localiza dispositivo por serial number
│     ├── POST /managedDevices/{id}/retire
│     └── Monitora remoção do perfil MDM (loop até confirmação)
│         └── limpar_certificados_ms.sh
│               └── Remove MS-ORGANIZATION-ACCESS do keychain do usuário
│
├── [Passo 4] instalar_jamf.sh
│     ├── profiles renew -type enrollment
│     └── Monitora enrollment (20 tentativas × 30s = até 10 min)
│
└── [Passo 5] pos_migracao.sh
      ├── jamf recon
      ├── Limpeza de arquivos temporários
      ├── Rotação de logs (máx. 10 MB / 7 dias)
      └── Agenda autoeliminação da pasta do assistente
```

---

## Documentação

| Documento | Público-alvo | Formato |
|---|---|---|
| [Guia Técnico](docs/Guia_Tecnico.docx) | Equipe de TI e administradores | .docx |
| [Guia do Usuário](docs/Guia_Usuario.docx) | Colaboradores com Mac | .docx |

Logs de execução em `/Library/Application Support/Assistente de Migracao/logs/migracao.log`.

---

## Dependências

| Dependência | Origem | Observação |
|---|---|---|
| swiftDialog | GitHub Releases (download automático) | Interface visual |
| jq | Incluído no repositório (`bin/`) | arm64 e amd64 |
| curl | Nativo macOS | Chamadas à API |
| profiles | Nativo macOS | Gerenciamento MDM |
| security | Nativo macOS | Acesso ao Keychain |