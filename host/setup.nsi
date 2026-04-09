; -----------------------------------------------------------------------
; INSTALADOR NSIS - SISTEMA DE SINCRONIZACAO TABELA FEDERADA
; -----------------------------------------------------------------------
; RESPONSABILIDADE DESTE INSTALADOR:
;   1. Copiar os scripts PowerShell para o diretorio de instalacao.
;   2. Coletar TODAS as configuracoes do ambiente via telas de instalacao.
;   3. Gravar cada configuracao como variavel de ambiente de sistema (Machine).
;   4. Agendar as 3 tarefas no Windows Task Scheduler.
;   5. Instruir o tecnico a executar setup_credenciais.ps1 apos a instalacao.
;
; NÃO E RESPONSABILIDADE DESTE INSTALADOR:
;   - Definir o API Token ou a senha do banco (feito pelo setup_credenciais.ps1
;     usando DPAPI, que criptografa para a maquina local).
;
; VARIAVEIS DE AMBIENTE DEFINIDAS AQUI:
;   SYNC_API_URL        - URL completa da API (dominio + porta + endpoint)
;   SYNC_HOST_ORIGEM    - Identificador unico deste host no sistema central
;   SYNC_MYSQL_EXE      - Caminho completo do executavel mysql.exe
;   SYNC_DB_NAME        - Nome do banco de dados local de origem
;   SYNC_DB_USER        - Usuario MySQL de leitura (somente SELECT)
;   SYNC_CREDENTIAL_FILE- Caminho do arquivo .enc gerado pelo DPAPI
;   SYNC_HTTP_TIMEOUT   - Timeout em segundos para a requisicao HTTP
; -----------------------------------------------------------------------

!define APP_NAME        "TabelaFederadaSync"
!define COMP_NAME       "Inoveh"
!define INSTALL_DIR     "$PROGRAMFILES64\${APP_NAME}"
!define PS_SYNC_SCRIPT  "sync_host.ps1"
!define PS_SETUP_SCRIPT "setup_credenciais.ps1"

; Valores padrao pre-preenchidos nas telas de instalacao (alteraveis pelo tecnico)
!define DEFAULT_MYSQL_EXE       "C:\MySQL\bin\mysql.exe"
!define DEFAULT_DB_NAME         "bdsia"
!define DEFAULT_DB_USER         "relatorio"
!define DEFAULT_CREDENTIAL_FILE "C:\ProgramData\TabelaFederadaSync\credenciais.enc"
!define DEFAULT_HTTP_TIMEOUT    "180"

; Plugins necessarios para as paginas de dialogo customizadas
!include "nsDialogs.nsh"
!include "LogicLib.nsh"

; -------------------------------------------------------
; Variaveis globais que armazerao os valores digitados
; pelo tecnico em cada pagina de instalacao.
; -------------------------------------------------------
Var VAR_API_URL
Var VAR_HOST_ORIGEM
Var VAR_MYSQL_EXE
Var VAR_DB_NAME
Var VAR_DB_USER
Var VAR_CREDENTIAL_FILE
Var VAR_HTTP_TIMEOUT

; Handles dos controles de texto (necessarios para leitura apos dialogo)
Var CTRL_API_URL
Var CTRL_HOST_ORIGEM
Var CTRL_MYSQL_EXE
Var CTRL_DB_NAME
Var CTRL_DB_USER
Var CTRL_CREDENTIAL_FILE
Var CTRL_HTTP_TIMEOUT

Name    "${APP_NAME}"
OutFile "Instalador_Sync_Host.exe"
InstallDir "${INSTALL_DIR}"

; Requer elevacao de administrador: necessario para gravar em Program Files,
; definir variaveis de ambiente de maquina (HKLM) e agendar tarefas SYSTEM.
RequestExecutionLevel admin

; Ordem das paginas: apenas pasta e instalacao, garantindo que o NSIS
; atue apenas como distribuidor dos arquivos sem reter valores.
Page directory
Page instfiles

; =======================================================================
; SECAO PRINCIPAL: Copia arquivos, define env vars e agenda tarefas
; =======================================================================
Section "Instalar"

    ; -------------------------------------------------------
    ; PASSO 1: Criar diretorio e copiar os scripts PowerShell
    ; -------------------------------------------------------
    DetailPrint "Copiando scripts de sincronizacao..."
    SetOutPath "${INSTALL_DIR}"

    ; Script principal de sincronizacao (executado pelas tarefas agendadas)
    File "host\${PS_SYNC_SCRIPT}"

    ; Script de setup de credenciais DPAPI (executado manualmente pelo admin)
    File "host\${PS_SETUP_SCRIPT}"

    ; (Removida a configuracao de variaveis de ambiente sensiveis.
    ; Toda a responsabilidade passou para o setup_credenciais.ps1)

    ; -------------------------------------------------------
    ; PASSO 3: Agendar as 3 tarefas diarias de sincronizacao
    ; /RL HIGHEST : Privilegio maximo disponivel para a conta
    ; /SC DAILY   : Recorrencia diaria
    ; /F          : Sobrescreve tarefa existente (reinstalacao segura)
    ; -------------------------------------------------------
    DetailPrint "Agendando tarefas de sincronizacao (08:00, 12:00, 18:00)..."

    ; Comando PowerShell executado em cada horario agendado
    StrCpy $0 'powershell.exe -ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File "${INSTALL_DIR}\${PS_SYNC_SCRIPT}"'

    ; Remove tarefas anteriores para evitar duplicatas em caso de reinstalacao
    nsExec::ExecToLog 'schtasks /Delete /TN "${APP_NAME}_08" /F'
    nsExec::ExecToLog 'schtasks /Delete /TN "${APP_NAME}_12" /F'
    nsExec::ExecToLog 'schtasks /Delete /TN "${APP_NAME}_18" /F'

    ; Cria as 3 tarefas com horarios distintos
    nsExec::ExecToLog 'schtasks /Create /TN "${APP_NAME}_08" /TR "$0" /SC DAILY /ST 08:00 /RU SYSTEM /F /RL HIGHEST'
    nsExec::ExecToLog 'schtasks /Create /TN "${APP_NAME}_12" /TR "$0" /SC DAILY /ST 12:00 /RU SYSTEM /F /RL HIGHEST'
    nsExec::ExecToLog 'schtasks /Create /TN "${APP_NAME}_18" /TR "$0" /SC DAILY /ST 18:00 /RU SYSTEM /F /RL HIGHEST'

    ; -------------------------------------------------------
    ; PASSO 4: Instrucao final ao tecnico
    ; O API Token e a senha do banco NAO sao definidos aqui.
    ; Esses segredos sao tratados pelo setup_credenciais.ps1 via DPAPI.
    ; -------------------------------------------------------
    DetailPrint "-----------------------------------------------------"
    DetailPrint "ACAO NECESSARIA APOS A INSTALACAO:"
    DetailPrint "Execute o script de credenciais como Administrador:"
    DetailPrint "Ele solicitara TODAS as configuracoes (API URL, Tokens, etc.),"
    DetailPrint "criptografando-os com DPAPI (vinculado a esta maquina)."
    DetailPrint "O script se auto-deletara no final por motivos de seguranca."
    DetailPrint "-----------------------------------------------------"

    DetailPrint "Instalacao concluida com sucesso."

SectionEnd
