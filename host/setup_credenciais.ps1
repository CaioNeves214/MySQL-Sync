<#
    ============================================================
    SETUP DE CREDENCIAIS - SISTEMA TABELA FEDERADA
    ============================================================
    Função   : Solicita as credenciais sensíveis (API Token e senha do DB),
               criptografa via DPAPI do Windows e salva em um arquivo .enc.
    
    QUANDO EXECUTAR: Uma única vez por host, após a instalação do sistema.
    QUEM EXECUTA   : O mesmo usuário/conta que irá executar o sync_host.ps1
                     (ex: conta de serviço ou SYSTEM). Isto é obrigatório porque
                     a DPAPI vincula o arquivo à identidade do usuário e da máquina.
    
    COMO EXECUTAR  :
        powershell.exe -ExecutionPolicy Bypass -File "setup_credenciais.ps1"
    
    ============================================================
    SOBRE A SEGURANÇA DPAPI:
    
    A Windows Data Protection API (DPAPI) criptografa dados usando uma chave mestre
    derivada das credenciais do usuário Windows + segredos da máquina.
    
    Resultado prático:
    ✅ O arquivo .enc só pode ser lido pelo MESMO usuário na MESMA máquina.
    ✅ Copiar o .enc para outro PC é inútil — a descriptografia vai falhar.
    ✅ Nem o Administrador local consegue ler o conteúdo sem a chave do usuário.
    ❌ Se o perfil do usuário for corrompido, o arquivo também não pode ser lido.
       (Mantenha o token original anotado em local seguro — ex: cofre de senhas da empresa)
    ============================================================
#>

# --- CONFIGURAÇÕES DO SETUP ---
# Diretório onde o arquivo de credenciais será salvo
# ProgramData é visível para todos os usuários, mas o conteúdo será criptografado por DPAPI
$INSTALL_DIR     = "C:\ProgramData\TabelaFederadaSync"
$CREDENTIAL_FILE = Join-Path $INSTALL_DIR "credenciais.enc"

# Necessário carregar o assembly de criptografia avançada (.NET)
Add-Type -AssemblyName System.Security

# ============================================================
# FUNÇÃO: Solicita senha de forma segura (sem exibir no terminal)
# ============================================================
function Request-SecureInput {
    param(
        [string]$Prompt,
        [string]$Confirmation = $null
    )

    while ($true) {
        # Read-Host -AsSecureString evita que a senha apareça na tela e nos logs
        $secure = Read-Host -Prompt $Prompt -AsSecureString

        if ($Confirmation) {
            $secureConfirm = Read-Host -Prompt $Confirmation -AsSecureString

            # Converte ambos para string apenas para comparar (em memória — descartado após)
            $plain1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
            $plain2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureConfirm))

            if ($plain1 -ne $plain2) {
                Write-Warning "Os valores nao coincidem. Tente novamente."
                $plain1 = $null; $plain2 = $null # Limpa da memória
                continue
            }
            $plain1 = $null; $plain2 = $null # Limpa da memória
        }

        # Retorna o objeto SecureString — nunca a string limpa
        return $secure
    }
}

# ============================================================
# INÍCIO DO SETUP
# ============================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  SETUP DE CREDENCIAIS - Tabela Federada Sync" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Este script vai criptografar e salvar suas credenciais"
Write-Host "usando a DPAPI do Windows (vinculado a este usuario/maquina)."
Write-Host ""

# Aviso se não está rodando como Administrador (necessário para escrever em ProgramData)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Warning "Recomendado executar como Administrador para salvar em C:\ProgramData."
    Write-Warning "Pressione Ctrl+C para cancelar e re-executar como Admin, ou Enter para continuar assim mesmo."
    Read-Host | Out-Null
}

# --- COLETA SEGURA DO HOST_ORIGEM ---
Write-Host "--- PASSO 1: Identificação do Host ---" -ForegroundColor Yellow
$hostOrigem = Read-Host "Digite o nome unico deste host (ex: FILIAL_SP_01)"
if (-not $hostOrigem) {
    Write-Error "Nome do host nao pode ser vazio."
    exit 1
}

# --- COLETA SEGURA DE INFORMACOES DE AMBIENTE ---
Write-Host "--- PASSO 2: URL e Configurações API ---" -ForegroundColor Yellow
$apiUrl = Read-Host "URL completa da API (ex: https://api.dominio.com/federated/sincronizar)"
$secureApiToken = Request-SecureInput -Prompt "Cole o API Token confidencial" -Confirmation "Confirme o API Token"

Write-Host ""
Write-Host "--- PASSO 3: Configuracoes MySQL ---" -ForegroundColor Yellow
$mysqlExe = Read-Host "Caminho do mysql.exe [Pressione ENTER para default: C:\MySQL\bin\mysql.exe]"
if (-not $mysqlExe) { $mysqlExe = "C:\MySQL\bin\mysql.exe" }

$dbName = Read-Host "Nome do banco de dados [Pressione ENTER para default: bdsia]"
if (-not $dbName) { $dbName = "bdsia" }

$dbUser = Read-Host "Usuario MySQL (leitura) [Pressione ENTER para default: relatorio]"
if (-not $dbUser) { $dbUser = "relatorio" }

$secureDbPass = Request-SecureInput -Prompt "Digite a senha do banco MySQL" -Confirmation "Confirme a senha do banco MySQL"

$httpTimeout = "180" # Default 180 sec para HttpTimeout
Write-Host ""

# ============================================================
# CRIPTOGRAFIA VIA DPAPI (Escopo LocalMachine)
# Utilizando a classe .NET direta permite que qualquer usuário 
# SYSTEM do mesmo OS descriptografe, essencial para o schtasks.
# ============================================================

Write-Host "Criptografando credenciais com DPAPI e envelopando JSON..." -ForegroundColor Green

# Converte SecureStrings para PlainText para o JSON (em memoria)
$plainApiToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureApiToken))
$plainDbPass   = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureDbPass))

# Monta o objeto JSON que ficará integralmente dentro do arquivo protegido
$credObject = @{
    ApiUrl     = $apiUrl
    ApiToken   = $plainApiToken
    MysqlExe   = $mysqlExe
    DbName     = $dbName
    DbUser     = $dbUser
    DbPassword = $plainDbPass
    HttpTimeout= $httpTimeout
    HostOrigem = $hostOrigem
    CriadoEm   = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
}

# Limpa strings sensíveis assim que colocadas no Hash
$plainApiToken = $null
$plainDbPass   = $null

$jsonPayload = $credObject | ConvertTo-Json -Depth 3
$plainBytes  = [System.Text.Encoding]::UTF8.GetBytes($jsonPayload)

# Usa a DPAPI com *LocalMachine* - Vinculado APENAS à máquina atual. Ninguém consegue ler de fora.
$encryptedBytes = [System.Security.Cryptography.ProtectedData]::Protect($plainBytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)


# ============================================================
# PERSISTÊNCIA: Salva o arquivo .enc em disco
# ============================================================

# Cria o diretório de instalação se não existir
if (-not (Test-Path $INSTALL_DIR)) {
    New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null
    Write-Host "Diretorio criado: $INSTALL_DIR"
}

# Salva o arquivo em Base64
[System.Convert]::ToBase64String($encryptedBytes) | Set-Content -Path $CREDENTIAL_FILE -Encoding UTF8

# ============================================================
# HARDENING: Aplica permissões NTFS restritas no arquivo
# Apenas o usuário atual e SYSTEM podem ler o arquivo.
# ============================================================

try {
    # Obtém a ACL atual
    $acl = Get-Acl $CREDENTIAL_FILE

    # Remove a herança de permissões do diretório pai (isola o arquivo)
    $acl.SetAccessRuleProtection($true, $false) # (isProtected, preserveInheritance)

    # Remove todas as permissões atuais (para começar de zero)
    $acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }

    # Permissão 1: Administradores Locais
    $ruleAdmins = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "Administrators", "Read,Write", "None", "None", "Allow"
    )
    $acl.AddAccessRule($ruleAdmins)

    # Permissão 2: SYSTEM pode ler (necessário se o Task Scheduler rodar como SYSTEM)
    $ruleSystem = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "SYSTEM", "Read", "None", "None", "Allow"
    )
    $acl.AddAccessRule($ruleSystem)

    # Aplica a ACL no arquivo
    Set-Acl -Path $CREDENTIAL_FILE -AclObject $acl
    Write-Host "Permissoes NTFS aplicadas: acesso restrito a Administrators e SYSTEM." -ForegroundColor Green
} catch {
    Write-Warning "Nao foi possivel aplicar permissoes NTFS avancadas: $($_.Exception.Message)"
}

# ============================================================
# CONFIGURAÇÃO DA VARIÁVEL DE AMBIENTE (host_origem — NÃO é segredo)
# Note: Somente o host_origem (identificador) vai para variável de ambiente.
# Senhas e tokens ficam NO arquivo .enc.
# ============================================================

Write-Host ""
Write-Host "Configurando variavel de ambiente SYNC_HOST_ORIGEM..." -ForegroundColor Green
[System.Environment]::SetEnvironmentVariable("SYNC_HOST_ORIGEM", $hostOrigem, "Machine")

# ============================================================
# FINALIZAÇÃO
# ============================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  SETUP CONCLUIDO COM SUCESSO!" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Arquivo de credenciais: $CREDENTIAL_FILE"
Write-Host "  Host de origem definido: $hostOrigem"
Write-Host ""
Write-Host " IMPORTANTE: Guarde o API Token original em um cofre de senhas" -ForegroundColor Yellow
Write-Host " corporativo. Se o perfil do usuario Windows for perdido, voce" -ForegroundColor Yellow
Write-Host " precisara rodar este setup novamente com o token original." -ForegroundColor Yellow
Write-Host ""
