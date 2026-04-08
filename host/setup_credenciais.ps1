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
# ProgramData é visível para todos os usuários, mas o conteúdo está criptografado por DPAPI
$INSTALL_DIR     = "C:\ProgramData\TabelaFederadaSync"
$CREDENTIAL_FILE = Join-Path $INSTALL_DIR "credenciais.enc"

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

# --- COLETA SEGURA DO API TOKEN ---
Write-Host ""
Write-Host "--- PASSO 2: API Token ---" -ForegroundColor Yellow
Write-Host "(Fornecido pelo administrador do servidor central)"
$secureApiToken = Request-SecureInput -Prompt "Cole o API Token" -Confirmation "Confirme o API Token"

# --- COLETA SEGURA DA SENHA DO BANCO LOCAL ---
Write-Host ""
Write-Host "--- PASSO 3: Senha do MySQL Local (user relatorio) ---" -ForegroundColor Yellow
$secureDbPass = Request-SecureInput -Prompt "Digite a senha do user relatorio" -Confirmation "Confirme a senha do user relatorio"

# ============================================================
# CRIPTOGRAFIA VIA DPAPI (ConvertFrom-SecureString sem chave)
# Quando usada SEM -Key, a DPAPI usa a chave do perfil do usuário atual.
# ============================================================

Write-Host ""
Write-Host "Criptografando credenciais com DPAPI..." -ForegroundColor Green

# ConvertFrom-SecureString sem -Key usa DPAPI do Windows (vinculado ao usuário e máquina)
$encryptedApiToken = ConvertFrom-SecureString $secureApiToken
$encryptedDbPass   = ConvertFrom-SecureString $secureDbPass

# Monta o objeto JSON que será salvo no arquivo .enc
# Cada campo é uma SecureString serializada (cifrada em hex pela DPAPI)
$credObject = @{
    ApiToken   = $encryptedApiToken   # Token da API remota — criptografado
    DbPassword = $encryptedDbPass     # Senha do MySQL local — criptografado
    CriadoEm  = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")  # Metadado de auditoria
    HostOrigemSugerido = $hostOrigem  # HOST_ORIGEM para referência (não é segredo)
}

# ============================================================
# PERSISTÊNCIA: Salva o arquivo .enc em disco
# ============================================================

# Cria o diretório de instalação se não existir
if (-not (Test-Path $INSTALL_DIR)) {
    New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null
    Write-Host "Diretorio criado: $INSTALL_DIR"
}

# Salva o JSON no arquivo .enc
$credObject | ConvertTo-Json -Depth 3 | Set-Content -Path $CREDENTIAL_FILE -Encoding UTF8

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

    # Permissão 1: Apenas o usuário atual pode ler (o DPAPI já restringe, mas adicionamos NTFS também)
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $ruleUser = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $currentUser, "Read,Write", "None", "None", "Allow"
    )
    $acl.AddAccessRule($ruleUser)

    # Permissão 2: SYSTEM pode ler (necessário se o Task Scheduler rodar como SYSTEM)
    $ruleSystem = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "SYSTEM", "Read", "None", "None", "Allow"
    )
    $acl.AddAccessRule($ruleSystem)

    # Aplica a ACL no arquivo
    Set-Acl -Path $CREDENTIAL_FILE -AclObject $acl
    Write-Host "Permissoes NTFS aplicadas: acesso restrito ao usuario atual e SYSTEM." -ForegroundColor Green
} catch {
    Write-Warning "Nao foi possivel aplicar permissoes NTFS avancadas: $($_.Exception.Message)"
    Write-Warning "O arquivo ainda esta criptografado por DPAPI, mas as permissoes NTFS nao foram restringidas."
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
