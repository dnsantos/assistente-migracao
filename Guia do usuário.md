# Guia do Usuário — Migração Apple na Globo

> Tudo o que você precisa saber sobre a atualização do gerenciamento do seu Mac

---

## O que está acontecendo?

A Globo está migrando o gerenciamento dos Macs corporativos para uma nova plataforma: o **Jamf Pro**. Essa mudança traz mais segurança, suporte mais rápido e uma experiência mais integrada ao ambiente Apple.

A migração é **automática** — você não precisa fazer nada técnico. Este guia explica o que esperar antes, durante e depois do processo.

---

## Antes da migração

### ✅ O que você deve fazer

**1. Salve seus arquivos na nuvem**
Certifique-se de que documentos importantes estão salvos no **OneDrive** ou em outra solução de nuvem da Globo. Arquivos salvos somente no Mac podem ser perdidos em casos de formatação.

**2. Verifique sua senha Microsoft**
Após a migração, o login do Mac será sincronizado com sua senha dos serviços Microsoft (Outlook, Teams etc.).

Troque sua senha **antes** da migração se ela contiver algum destes caracteres especiais:
```
~ ` ' " ^
```
Senhas muito longas também podem causar problemas. Recomendamos uma senha forte com tamanho moderado.

> Como trocar: acesse o portal Microsoft/Office e altere sua senha nas configurações de conta.

**3. Mantenha o Mac ligado e conectado à internet**
O processo requer conexão ativa. Deixe o Mac conectado à rede e à energia durante a migração.

---

## Durante a migração

Uma janela com o progresso da migração será exibida automaticamente na sua tela. Você verá uma lista com as etapas:

| Etapa | O que acontece |
|---|---|
| 1. Validação | O sistema verifica o estado atual do seu Mac |
| 2. Instalação de dependências | Ferramentas necessárias são instaladas |
| 3. Remoção do Intune | O gerenciamento anterior é removido com segurança |
| 4. Instalação do Jamf | Seu Mac é conectado à nova plataforma |
| 5. Finalização | Limpeza e ajustes finais |

**Você pode continuar usando o Mac normalmente** enquanto a migração acontece em segundo plano. O processo leva aproximadamente **15 a 30 minutos**.

---

## Após a migração

### 🔐 Novo login com Jamf Connect

No próximo login (após reiniciar ou bloquear a tela), você verá a tela do **Jamf Connect**. Basta inserir suas credenciais da Globo/Microsoft normalmente — é o mesmo usuário e senha que você já usa no Outlook e Teams.

### 🖥️ Papel de parede Globo

Seu Mac exibirá automaticamente o papel de parede institucional da Globo. Personalização de papel de parede está desativada por política da empresa.

### 🔒 Dispositivos USB

Pendrives e HDs externos **não autorizados** serão bloqueados automaticamente. Se você precisar de acesso a um dispositivo externo, solicite à equipe de TI.

---

## Como solicitar acesso de administrador

Após a migração, você não terá permissão de administrador permanente no Mac — isso é uma medida de segurança. Quando precisar instalar um aplicativo ou alterar configurações avançadas, você pode solicitar acesso temporário:

1. Clique no ícone do **Jamf Connect** na barra de menu (topo da tela)
2. Selecione **"Request Admin Privileges"**
3. Informe o motivo da solicitação
4. Você terá acesso de administrador por **5 minutos**

> Esse processo protege seu Mac e os dados da empresa sem te impedir de fazer o que precisa.

---

## Perguntas frequentes

**Preciso estar presente durante a migração?**
Não é necessário acompanhar ativamente. Você pode continuar trabalhando normalmente. Apenas mantenha o Mac ligado e conectado.

**Vou perder meus arquivos?**
Não, desde que estejam salvos na nuvem (OneDrive). Arquivos locais não são apagados durante a migração, mas recomendamos backup preventivo.

**O que faço se esquecer minha senha após a migração?**
Sua senha do Mac é a mesma do Microsoft/Globo. Caso esqueça, redefina pelo portal de senhas Microsoft e reinicie o Mac. O Jamf Connect sincronizará automaticamente.

**E se algo der errado?**
A equipe de TI é notificada automaticamente em caso de falha. Entre em contato com o suporte informando o serial do seu Mac (Apple menu > Sobre este Mac).

**Posso instalar apps normalmente?**
Sim, usando a solicitação de acesso temporário de administrador via Jamf Connect, conforme descrito acima.

**Meu Mac vai reiniciar sozinho?**
A migração em si não reinicia o Mac. Após a conclusão, pode ser solicitado um reinício para aplicar políticas do Jamf — siga as instruções na tela.

---

## Precisa de ajuda?

Entre em contato com o suporte da Globo pelos canais habituais e informe:

- Seu nome e departamento
- O serial do Mac: **Apple menu (🍎) > Sobre este Mac > Número de série**
- Uma descrição do problema ou dúvida