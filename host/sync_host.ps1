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

# --- CONFIGURAÇÕES DE LOG ---
$LOG_FOLDER = "C:\ProgramData\TabelaFederadaSync"
$LOG_FILE   = Join-Path $LOG_FOLDER "sync.log"

if (-not (Test-Path $LOG_FOLDER)) { New-Item -ItemType Directory -Path $LOG_FOLDER -Force | Out-Null }

function Write-SyncLog {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] [$Level] $Message"
    Write-Host $logLine
    try {
        Add-Content -Path $LOG_FILE -Value $logLine -ErrorAction SilentlyContinue
    } catch {}
}

# Forca TLS 1.2 para comunicacao HTTPS segura com o servidor.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12, [Net.SecurityProtocolType]::Tls11, [Net.SecurityProtocolType]::Tls
$ProgressPreference = 'SilentlyContinue'

$CREDENTIAL_FILE = "C:\ProgramData\TabelaFederadaSync\credenciais.enc"
Add-Type -AssemblyName System.Security

function Read-EncryptedConfig {
    param([string]$FilePath)

    if (-not (Test-Path $FilePath)) {
        $err = "ERRO CRITICO: Arquivo de credenciais nao encontrado em: $FilePath"
        Write-SyncLog $err "ERROR"
        throw $err
    }

        try {
            # Lê o Base64 gerado pelo Protect do PowerShell .NET
            $encryptedB64 = Get-Content -Path $FilePath -Raw -Encoding UTF8
            $encryptedBytes = [System.Convert]::FromBase64String($encryptedB64)

            # Descriptografa com LocalMachine
            $plainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect($encryptedBytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
            $jsonString = [System.Text.Encoding]::UTF8.GetString($plainBytes)

            return ($jsonString | ConvertFrom-Json)
        } catch {
            $err = "Falha ao descriptografar credenciais: $($_.Exception.Message)"
            Write-SyncLog $err "ERROR"
            throw $err
        }
}

# ================================================================
# BLOCO: CARREGAMENTO DAS CREDENCIAIS E VALIDACOES INICIAIS
# ================================================================
# Todas as variaveis de ambiente sao validadas antes de qualquer operacao.
# Se uma variavel estiver ausente, o script aborta com mensagem clara,
# evitando erros crípticos durante a execucao principal.

try {
    Write-SyncLog "Iniciando processo de sincronizacao..."

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
        throw "Credenciais incompletas no arquivo .enc. Rode o setup_credenciais.ps1 novamente."
    }

    # Valida que o executavel do MySQL existe
    if (-not (Test-Path $MYSQL_EXE)) {
        throw "mysql.exe nao encontrado no caminho: $MYSQL_EXE"
    }

    # --- ETAPA 1: CONSULTA AO BANCO LOCAL ---
    $query = "SELECT ID_LOGUSUARIO, ID_USUARIO, ID_EMPRESA, TEXTO, DT_LOGUSUARIO, HR_LOGUSUARIO, TIPO, TABELA, CHAVE_PRIMARIA FROM log_usuario LIMIT 1000;"
    
    Write-SyncLog "Consultando banco local ($DB_NAME)..."
    $dataRaw = & $MYSQL_EXE -u $DB_USER "-p$DB_PASS" $DB_NAME --batch --silent -e "$query" 2>$null
    $DB_PASS = $null # Segurança

    if (-not $dataRaw) {
        Write-SyncLog "Nenhum registro encontrado para sincronizar."
        return
    }

    # --- ETAPA 2: PARSE TSV ---
    $registros = New-Object System.Collections.Generic.List[PSObject]
    foreach ($line in $dataRaw) {
        $cols = $line -split "`t"
        if ($cols.Count -ge 9) {
            $registros.Add([PSCustomObject]@{
                ID_LOGUSUARIO  = [int]$cols[0]; ID_USUARIO = [int]$cols[1]; ID_EMPRESA = [int]$cols[2]
                TEXTO          = $cols[3]; DT_LOGUSUARIO = $cols[4]; HR_LOGUSUARIO = $cols[5]
                TIPO           = [int]$cols[6]; TABELA = $cols[7]; CHAVE_PRIMARIA = $cols[8]
            })
        }
    }

    if ($registros.Count -eq 0) {
        Write-SyncLog "Nenhum registro valido apos parse."
        return
    }

    # --- ETAPA 3: PAYLOAD ---
    if (-not $HOST_ORIGEM) {
        throw "ERRO: HOST_ORIGEM nao definido. Verifique variavel de ambiente SYNC_HOST_ORIGEM ou config.enc"
    }
    $payload = @{ host_origem = $HOST_ORIGEM; registros = $registros } | ConvertTo-Json -Depth 5 -Compress

    # --- ETAPA 4: JITTER ---
    $delay = Get-Random -Minimum 1 -Maximum 180
    Write-SyncLog "Aguardando $delay seg (jitter)..."
    Start-Sleep -Seconds $delay

    # --- ETAPA 5: ENVIO HTTPS ---
    # Forçamos o charset=utf-8 no Content-Type para evitar que o PowerShell use ISO-8859-1 (latin1)
    $headers = @{ "X-API-Token" = $API_TOKEN; "Content-Type" = "application/json; charset=utf-8" }
    Write-SyncLog "Enviando $($registros.Count) registros..."
    
    # IMPORTANTE: Em PS 5.1, Converter string para BYTES UTF-8 é a única forma de garantir
    # que o charset=utf-8 do header seja respeitado e não quebre no servidor.
    $payloadBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    
    $response = Invoke-RestMethod -Uri $API_URL -Method Post -Headers $headers -Body $payloadBytes -TimeoutSec $HTTP_TIMEOUT_SEGUNDOS -ErrorAction Stop
    $API_TOKEN = $null

    # --- ETAPA 6: RESPOSTA ---
    if ($response.status -eq "ok") {
        Write-SyncLog "SUCESSO! Inseridos: $($response.inseridos) | Ignorados: $($response.ignorados)"
    } else {
        throw "API retornou erro: $($response | ConvertTo-Json)"
    }

} catch {
    $err = "FALHA CRITICA: $($_.Exception.Message)"
    Write-SyncLog $err "ERROR"
    $API_TOKEN = $null; $DB_PASS = $null
} finally {
    # Se rodado manualmente (janela visivel), pausa para visualizacao
    if ([Environment]::UserInteractive) {
        Write-Host "`nExecucao finalizada. Pressione ENTER para fechar..."
        $null = Read-Host
    }
}
