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
#>

# === BLOCO 1 E 2 UNIFICADOS: LEITURA SEGURA DE CREDENCIAIS E CONFIGS ===
# Todo tráfego de dados e senhas é contido em AES (DataProtection LocalMachine).
# Não dependemos mais das variáveis de ambiente de sistema expostas.

# Forca TLS 1.2 para comunicacao HTTPS segura com o servidor.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12, [Net.SecurityProtocolType]::Tls11, [Net.SecurityProtocolType]::Tls
$ProgressPreference = 'SilentlyContinue'

$CREDENTIAL_FILE = "C:\ProgramData\TabelaFederadaSync\credenciais.enc"
Add-Type -AssemblyName System.Security

function Read-EncryptedConfig {
    param([string]$FilePath)

    if (-not (Test-Path $FilePath)) {
        Write-Error "ERRO CRITICO: Arquivo de credenciais nao encontrado em: $FilePath"
        exit 1
    }

    try {
        # Lê o Base64 gerado pelo Protect do PowerShell .NET
        $encryptedB64 = Get-Content -Path $FilePath -Raw -Encoding UTF8
        $encryptedBytes = [System.Convert]::FromBase64String($encryptedB64)

        # Descriptografa com LocalMachine (necessita permissão NTFS concedida do setup_credenciais)
        $plainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect($encryptedBytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
        $jsonString = [System.Text.Encoding]::UTF8.GetString($plainBytes)

        # O JSON resultante já contém as variáveis
        return ($jsonString | ConvertFrom-Json)
    } catch {
        Write-Error "ERRO: Falha ao descriptografar credenciais. Detalhes: $($_.Exception.Message)"
        exit 1
    }
}

# ================================================================
# BLOCO 3: CARREGAMENTO DAS CREDENCIAIS E VALIDACOES INICIAIS
# ================================================================
# Todas as variaveis de ambiente sao validadas antes de qualquer operacao.
# Se uma variavel estiver ausente, o script aborta com mensagem clara,
# evitando erros crípticos durante a execucao principal.

Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Iniciando sincronizacao do host: $HOST_ORIGEM"

# Le todas configs contidas no Json Encriptado
$configs = Read-EncryptedConfig -FilePath $CREDENTIAL_FILE

$API_URL     = $configs.ApiUrl
$API_TOKEN   = $configs.ApiToken
$MYSQL_EXE   = $configs.MysqlExe
$DB_NAME     = $configs.DbName
$DB_USER     = $configs.DbUser
$DB_PASS     = $configs.DbPassword
$HOST_ORIGEM = [System.Environment]::GetEnvironmentVariable("SYNC_HOST_ORIGEM", "Machine")
if (-not $HOST_ORIGEM) { $HOST_ORIGEM = $configs.HostOrigem }
$HTTP_TIMEOUT_SEGUNDOS = if ($configs.HttpTimeout) { [int]$configs.HttpTimeout } else { 180 }

# Valida as info basicas
if (-not $API_TOKEN -or -not $DB_PASS -or -not $API_URL) {
    Write-Error "ERRO: Credenciais ausentes. O processo sera cancelado."
    exit 1
}

# Valida que o executavel do MySQL existe no caminho configurado
if (-not (Test-Path $MYSQL_EXE)) {
    Write-Error "ERRO: mysql.exe nao encontrado em: $MYSQL_EXE"
    Write-Error "Verifique o valor da variavel SYNC_MYSQL_EXE ou reinstale o aplicativo."
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
