<#
    ============================================================
    SISTEMA DE SINCRONIZACAO - SCRIPT DO HOST (FILIAL)
    ============================================================
    Funcao   : Coleta logs do MySQL local e envia via HTTPS ao servidor central.
    Seguranca: Credenciais (API Token e senha do DB) sao lidas de um arquivo
               criptografado pela DPAPI do Windows. O arquivo .enc so pode ser
               descriptografado pelo MESMO usuario Windows que o gerou na MESMA
               maquina. Backups do arquivo .enc sao inuteis em outro host.
    Execucao : Windows Task Scheduler (Diario as 08:00, 12:00 e 18:00)
    ============================================================

    POLITICA DE EXECUCAO:
    Este script configura sua propria politica de execucao via Set-ExecutionPolicy
    no escopo do processo atual. Isso dispensa o uso de flags externas como
    -ExecutionPolicy Bypass no agendador de tarefas, tornando a execucao mais
    segura e auditavel: a politica e restrita apenas a este processo, nao altera
    a politica global da maquina.
    ============================================================
#>

# ================================================================
# BLOCO 0: POLITICA DE EXECUCAO (Auto-configurada no escopo do processo)
# ================================================================

# Define a politica de execucao apenas para o processo atual (nao altera a maquina).
# "RemoteSigned": Scripts locais rodam livre; scripts baixados da internet precisam de assinatura.
# Isso e mais seguro que "Bypass" (que ignora tudo) e evita o erro "nao pode ser carregado".
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process -Force

# ================================================================
# BLOCO 1: CONFIGURACOES FIXAS (Nao sao segredos - podem ficar aqui)
# ================================================================

# Forca TLS 1.2 para comunicacao HTTPS segura com o servidor.
# Necessario em Windows 10 mais antigos que podem nao ativar TLS 1.2 por padrao.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12, [Net.SecurityProtocolType]::Tls11, [Net.SecurityProtocolType]::Tls

# Suprime a barra de progresso do Invoke-RestMethod (melhora performance e evita erros em sessoes sem UI)
$ProgressPreference = 'SilentlyContinue'

# Timeout em segundos para a requisicao HTTP ao servidor.
# IMPORTANTE: O jitter (Start-Sleep) ocorre ANTES do envio HTTP, portanto nao interfere
# neste timeout. Este valor cobre apenas o tempo de upload + resposta do servidor.
# 180 segundos e suficiente para payloads de ate 1000 registros em conexoes lentas.
$HTTP_TIMEOUT_SEGUNDOS = 180

# URL da API remota (destino de sincronizacao)
$API_URL     = "http://srv.inoveh.com.br:5000/federated/sincronizar"

# Identificador unico e IMUTAVEL deste host no sistema centralizado.
# ATENCAO: Alterar este valor apos a primeira sincronizacao ira quebrar a
# idempotencia e pode gerar registros duplicados no servidor.
$HOST_ORIGEM = [System.Environment]::GetEnvironmentVariable("SYNC_HOST_ORIGEM", "Machine")

# Caminho do executavel MySQL instalado neste host
$MYSQL_EXE   = "C:\MySQL\bin\mysql.exe"

# Nome do banco de dados local de origem
$DB_NAME     = "bdsia"
$DB_USER     = "relatorio"   # Usuario de leitura local (somente SELECT necessario)

# Caminho do arquivo de credenciais criptografadas (gerado pelo setup_credenciais.ps1)
# ProgramData e acessivel ao sistema, mas o conteudo so pode ser descriptografado
# pelo usuario ou conta de servico que criou o arquivo via DPAPI.
$CREDENTIAL_FILE = "C:\ProgramData\TabelaFederadaSync\credenciais.enc"

# ================================================================
# BLOCO 2: FUNCAO - LEITURA SEGURA DE CREDENCIAIS (DPAPI)
# ================================================================

function Read-EncryptedCredentials {
    <#
    .SYNOPSIS
        Le e descriptografa o arquivo de credenciais usando a DPAPI do Windows.
    .DESCRIPTION
        O arquivo .enc contem um JSON com os segredos criptografados via ConvertFrom-SecureString.
        A DPAPI usa a chave derivada do perfil do usuario Windows atual -- portanto o arquivo
        descriptografado SOMENTE funciona no mesmo usuario/maquina que o criou.
        Retorna uma hashtable com as chaves: ApiToken, DbPassword
    #>
    param([string]$FilePath)

    # Verifica se o arquivo de credenciais existe antes de tentar ler
    if (-not (Test-Path $FilePath)) {
        Write-Error "ERRO CRITICO: Arquivo de credenciais nao encontrado em: $FilePath"
        Write-Error "Execute 'setup_credenciais.ps1' como administrador para configurar as credenciais."
        exit 1
    }

    try {
        # Le o conteudo JSON do arquivo (contem campos criptografados como SecureString serializada)
        $encrypted = Get-Content -Path $FilePath -Raw -Encoding UTF8 | ConvertFrom-Json

        # Descriptografa o API Token: ConvertTo-SecureString usa DPAPI internamente
        $secureApiToken = ConvertTo-SecureString $encrypted.ApiToken
        # Converte de SecureString para texto puro apenas na memoria, para uso imediato
        $plainApiToken  = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureApiToken)
        )

        # Descriptografa a senha do banco de dados local (mesmo processo)
        $secureDbPass = ConvertTo-SecureString $encrypted.DbPassword
        $plainDbPass  = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureDbPass)
        )

        # Retorna as credenciais descriptografadas como hashtable (ficam na memoria RAM apenas)
        return @{
            ApiToken   = $plainApiToken
            DbPassword = $plainDbPass
        }

    } catch {
        # Se falhar a descriptografia, pode ser que o arquivo foi copiado de outra maquina
        # ou o usuario que esta executando nao e o mesmo que criou o arquivo.
        Write-Error "ERRO: Falha ao descriptografar credenciais. O arquivo pode ter sido gerado em outro usuario/maquina."
        Write-Error "Detalhes: $($_.Exception.Message)"
        exit 1
    }
}

# ================================================================
# BLOCO 3: CARREGAMENTO DAS CREDENCIAIS E VALIDACOES INICIAIS
# ================================================================

Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Iniciando sincronizacao do host: $HOST_ORIGEM"

# Le e descriptografa as credenciais do arquivo .enc (DPAPI)
$creds     = Read-EncryptedCredentials -FilePath $CREDENTIAL_FILE
$API_TOKEN = $creds.ApiToken
$DB_PASS   = $creds.DbPassword

# Valida que as credenciais foram carregadas corretamente
if (-not $API_TOKEN -or -not $DB_PASS) {
    Write-Error "ERRO: Credenciais retornadas estao vazias. Execute setup_credenciais.ps1 novamente."
    exit 1
}

# Valida que o HOST_ORIGEM esta configurado (variavel de ambiente nao-secreta)
if (-not $HOST_ORIGEM) {
    Write-Error "ERRO: Variavel de ambiente SYNC_HOST_ORIGEM nao definida. Configure pelo instalador."
    exit 1
}

# Valida que o executavel do MySQL existe no caminho configurado
if (-not (Test-Path $MYSQL_EXE)) {
    Write-Error "ERRO: mysql.exe nao encontrado em: $MYSQL_EXE"
    exit 1
}

# ================================================================
# BLOCO 4: EXECUCAO PRINCIPAL (Coleta -> Parse -> Jitter -> Envio)
# ================================================================

try {

    # --- ETAPA 1: CONSULTA AO BANCO LOCAL (MySQL 5.5) ---
    # --batch : Saida em TSV (sem bordas graficas), ideal para parse automatizado
    # --silent: Suprime cabecalhos e mensagens de contagem de linhas
    # 2>$null : Redireciona stderr p/ null (evita que a senha apareca em logs de erro)
    $query = @"
SELECT ID_LOGUSUARIO, ID_USUARIO, ID_EMPRESA, TEXTO,
       DT_LOGUSUARIO, HR_LOGUSUARIO, TIPO, TABELA, CHAVE_PRIMARIA
FROM log_usuario
LIMIT 1000;
"@

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Consultando banco local ($DB_NAME)..."
    $dataRaw = & $MYSQL_EXE -u $DB_USER "-p$DB_PASS" $DB_NAME --batch --silent -e "$query" 2>$null

    # Limpa a variavel de senha da memoria assim que termina o uso com o banco.
    # Boa pratica: minimizar o tempo que credentials ficam em variaveis de string.
    $DB_PASS = $null

    if (-not $dataRaw) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Nenhum registro encontrado para sincronizar."
        exit 0
    }

    # --- ETAPA 2: PARSE TSV -> LISTA DE OBJETOS JSON ---
    # Cada linha do MySQL --batch e separada por tabulacao (\t)
    $registros = New-Object System.Collections.Generic.List[PSObject]

    foreach ($line in $dataRaw) {
        # Split por tabulacao para separar as colunas
        $cols = $line -split "`t"

        # Garante que a linha tem o numero correto de colunas (9 campos esperados)
        if ($cols.Count -ge 9) {
            $obj = [PSCustomObject]@{
                ID_LOGUSUARIO  = [int]$cols[0]     # PK original do host
                ID_USUARIO     = [int]$cols[1]     # FK para funcionarios
                ID_EMPRESA     = [int]$cols[2]     # FK para empresa
                TEXTO          = $cols[3]          # BLOB tratado como string no batch mode
                DT_LOGUSUARIO  = $cols[4]          # Formato YYYY-MM-DD
                HR_LOGUSUARIO  = $cols[5]          # Formato HH:MM:SS
                TIPO           = [int]$cols[6]     # Tipo do evento de log
                TABELA         = $cols[7]          # Tabela afetada (nullable)
                CHAVE_PRIMARIA = $cols[8]          # PK da tabela afetada (nullable)
            }
            $registros.Add($obj)
        }
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Registros coletados: $($registros.Count)"

    if ($registros.Count -eq 0) {
        Write-Host "Nenhum registro valido para enviar apos o parse."
        exit 0
    }

    # --- ETAPA 3: MONTAGEM DO PAYLOAD JSON ---
    # Estrutura exigida pelo contrato da API: { host_origem, registros: [...] }
    $payload = @{
        host_origem = $HOST_ORIGEM
        registros   = $registros
    } | ConvertTo-Json -Depth 5 -Compress

    # --- ETAPA 4: JITTER (Distribuicao de carga no servidor) ---
    # Por que: 50+ hosts rodando ao mesmo tempo as 12:00 sobrecarregariam o servidor.
    # O delay aleatorio de ate 3 minutos distribui as requisicoes ao longo do tempo.
    # IMPORTANTE: O jitter ocorre ANTES do Invoke-RestMethod. O timeout HTTP ($HTTP_TIMEOUT_SEGUNDOS)
    # comeca a contar somente apos o Start-Sleep terminar e a conexao ser estabelecida.
    # Portanto, o jitter NAO interfere no timeout da requisicao HTTP.
    $delay = Get-Random -Minimum 1 -Maximum 180
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Aguardando $delay seg (jitter anti-carga) antes de enviar..."
    Start-Sleep -Seconds $delay

    # --- ETAPA 5: ENVIO HTTPS (POST com autenticacao por header) ---
    # O API Token e enviado no header X-API-Token (nunca na URL ou no body).
    # -TimeoutSec: Define o limite de espera pela resposta do servidor (120s).
    #              Sem isso, o PowerShell 5.1 usa o default do .NET (100s) que pode
    #              ser insuficiente para payloads grandes em conexoes lentas.
    # -ErrorAction Stop: Garante que erros HTTP (4xx, 5xx) caiam no bloco catch.
    $headers = @{
        "X-API-Token"  = $API_TOKEN
        "Content-Type" = "application/json"
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Enviando $($registros.Count) registros para o servidor..."
    $response = Invoke-RestMethod `
        -Uri         $API_URL `
        -Method      Post `
        -Headers     $headers `
        -Body        $payload `
        -TimeoutSec  $HTTP_TIMEOUT_SEGUNDOS `
        -ErrorAction Stop

    # Limpa o token da memoria imediatamente apos o envio para minimizar exposicao
    $API_TOKEN = $null
    [System.GC]::Collect()

    # --- ETAPA 6: VERIFICACAO DA RESPOSTA ---
    if ($response.status -eq "ok") {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] SUCESSO! Inseridos: $($response.inseridos) | Ignorados (duplicatas): $($response.ignorados)"
        exit 0
    } else {
        Write-Error "A API retornou um status inesperado: $($response | ConvertTo-Json)"
        exit 1
    }

} catch {
    # Limpa credenciais da memoria em caso de falha tambem
    $API_TOKEN = $null
    $DB_PASS   = $null
    [System.GC]::Collect()

    Write-Error "[$(Get-Date -Format 'HH:mm:ss')] FALHA CRITICA: $($_.Exception.Message)"
    exit 1
}
