#Requires -Version 5.1
<#
.SYNOPSIS
    Reconstrói ISOs do Windows 11, mantendo o nome do arquivo, para instalarem uma
    edição fixa com a chave informada e criarem uma conta local (sem conta Microsoft no OOBE).

.DESCRIPTION
    Versão para Windows do win11-iso-builder.sh. Usa o DISM (nativo) e o oscdimg.exe
    (Windows ADK, componente "Deployment Tools"). Precisa rodar como administrador.

    Antes de começar, confere as dependências. Se o oscdimg.exe não estiver instalado,
    oferece instalar o Deployment Tools do Windows ADK (pelo winget ou baixando o
    instalador oficial da Microsoft); com -y, instala sem perguntar.

    Os valores de config.env são lidos primeiro; as opções da linha de comando os sobrescrevem.

.EXAMPLE
    .\win11-iso-builder.ps1 $HOME\Downloads\Windows11_Client_x64_pt-pt_26300_9457.iso

.EXAMPLE
    .\win11-iso-builder.ps1 -k XXXXX-XXXXX-XXXXX-XXXXX-XXXXX -u Paulo $HOME\Downloads\Windows11_*.iso
#>
param(
    # Chave do produto (obrigatória)
    [Alias('k')] [string]$Key = '',
    # EditionID a instalar (padrão: Professional)
    [Alias('e')] [string]$Edition = 'Professional',
    # Nome da conta local de administrador (obrigatório)
    [Alias('u')] [string]$User = '',
    # Senha da conta local (padrão: sem senha)
    [Alias('p')] [string]$Password = '',
    # Grava em outra pasta (padrão: substitui a ISO original)
    [Alias('o')] [string]$Output = '',
    # Arquivo de configuração (padrão: config.env ao lado do script)
    [Alias('c')] [string]$Config = (Join-Path $PSScriptRoot 'config.env'),
    # Instala as dependências que faltarem sem perguntar
    [Alias('y')] [switch]$Yes,
    [Alias('h')] [switch]$Help,
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)] [string[]]$Iso
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Template = Join-Path $PSScriptRoot 'templates\autounattend.xml'
$SplitMB = 3800
# Instalador oficial do Windows ADK (redireciona para download.microsoft.com)
$AdkUrl = 'https://go.microsoft.com/fwlink/?linkid=2289980'

function Show-Usage {
    $me = Split-Path -Leaf $PSCommandPath
    Write-Host @"
Uso: .\$me [opções] <iso> [<iso>...]

Opções:
  -k, -Key CHAVE          chave do produto (obrigatória)
  -e, -Edition ID         EditionID a instalar (padrão: Professional)
  -u, -User NOME          nome da conta local de administrador (obrigatório)
  -p, -Password SENHA     senha da conta local (padrão: sem senha)
  -o, -Output DIR         grava em outra pasta (padrão: substitui a ISO original)
  -c, -Config ARQUIVO     arquivo de configuração (padrão: config.env ao lado do script)
  -y, -Yes                instala as dependências que faltarem sem perguntar
  -h, -Help               mostra esta ajuda

Os valores de config.env são lidos primeiro; as opções acima os sobrescrevem.
"@
}

function Fail([string]$Message) { throw $Message }
function Log([string]$Message) { Write-Host "==> $Message" }

# Lê o config.env (sintaxe de shell: NOME="valor"), sem executá-lo
function Read-Config([string]$Path) {
    $cfg = @{}
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
            $name = $Matches[1]
            $value = $Matches[2]
            if ($value -match '^"(.*)"$' -or $value -match "^'(.*)'$") { $value = $Matches[1] }
            $cfg[$name] = $value
        }
    }
    $cfg
}

# Procura o oscdimg.exe no PATH e na instalação padrão do Windows ADK
function Find-Oscdimg {
    $cmd = Get-Command oscdimg.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $arch = switch ($env:PROCESSOR_ARCHITECTURE) { 'ARM64' { 'arm64' } 'x86' { 'x86' } default { 'amd64' } }
    $programFiles = ${env:ProgramFiles(x86)}
    if (-not $programFiles) { $programFiles = $env:ProgramFiles }
    $tools = Join-Path $programFiles 'Windows Kits\10\Assessment and Deployment Kit\Deployment Tools'
    foreach ($a in @($arch, 'amd64', 'x86') | Select-Object -Unique) {
        $path = Join-Path $tools "$a\Oscdimg\oscdimg.exe"
        if (Test-Path -LiteralPath $path) { return $path }
    }
    $null
}

function Confirm-Install([string]$What) {
    if ($Yes) { return $true }
    $answer = Read-Host "$What não encontrado. Instalar agora? [S/n]"
    $answer -eq '' -or $answer -match '^[sSyY]'
}

# Instala só o componente Deployment Tools do Windows ADK (onde fica o oscdimg.exe):
# pelo winget, se houver, ou baixando o instalador oficial da Microsoft
function Install-Adk {
    $adkArgs = '/quiet /norestart /ceip off /features OptionId.DeploymentTools'
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($winget) {
        Log 'Instalando o Windows ADK (Deployment Tools) pelo winget'
        & $winget.Source install --id Microsoft.WindowsADK --exact --silent `
            --accept-package-agreements --accept-source-agreements --override $adkArgs
        if ($LASTEXITCODE -eq 0 -and (Find-Oscdimg)) { return }
        # Também cai aqui quando o ADK já está instalado, mas sem o Deployment Tools
        Write-Warning "o winget não instalou o oscdimg (código $LASTEXITCODE); usando o instalador da Microsoft"
    }

    $setup = Join-Path $env:TEMP 'adksetup.exe'
    $script:TmpFiles += $setup
    Log 'Baixando o instalador do Windows ADK'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $progress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try { Invoke-WebRequest -Uri $AdkUrl -OutFile $setup -UseBasicParsing }
    finally { $ProgressPreference = $progress }

    $sig = Get-AuthenticodeSignature -LiteralPath $setup
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
        Fail "o instalador baixado não tem assinatura válida da Microsoft ($($sig.Status))"
    }
    # O adksetup baixa o componente pedido da internet; 3010 = instalado, requer reinício
    Log 'Instalando o Windows ADK (Deployment Tools)'
    $proc = Start-Process -FilePath $setup -ArgumentList $adkArgs -Wait -PassThru
    if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
        Fail "a instalação do Windows ADK falhou (código $($proc.ExitCode))"
    }
}

# Confere tudo de que o script precisa antes de mexer em qualquer ISO; define $Oscdimg
function Assert-Dependencies {
    $principal = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Fail 'execute o PowerShell como administrador (o DISM e a montagem da ISO exigem)'
    }
    if (-not (Test-Path -LiteralPath $Template)) { Fail "template não encontrado: $Template" }

    # Fazem parte do Windows (módulos Dism e Storage); não há o que baixar se faltarem
    $missing = @()
    foreach ($cmd in 'Get-WindowsImage', 'Export-WindowsImage', 'Split-WindowsImage',
                     'Get-DiskImage', 'Mount-DiskImage', 'Dismount-DiskImage', 'Get-Volume', 'robocopy.exe') {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { $missing += $cmd }
    }
    if ($missing) {
        Fail "componentes do Windows ausentes: $($missing -join ', ') (o script exige Windows 10/11 com os módulos Dism e Storage)"
    }

    $script:Oscdimg = Find-Oscdimg
    if (-not $script:Oscdimg) {
        if (-not (Confirm-Install 'oscdimg.exe (Windows ADK, Deployment Tools)')) {
            Fail "oscdimg.exe não encontrado; instale o Deployment Tools do Windows ADK: $AdkUrl"
        }
        Install-Adk
        $script:Oscdimg = Find-Oscdimg
        if (-not $script:Oscdimg) { Fail 'oscdimg.exe não encontrado mesmo após instalar o Windows ADK' }
    }
    Log "oscdimg: $script:Oscdimg"
}

$script:MountedIso = $null
$script:Work = $null
$script:TmpFiles = @()
function Clear-Work {
    if ($script:Work -and (Test-Path -LiteralPath $script:Work)) {
        Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue
    }
    foreach ($f in $script:TmpFiles) {
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }
    if ($script:MountedIso) {
        Dismount-DiskImage -ImagePath $script:MountedIso -ErrorAction SilentlyContinue | Out-Null
    }
    $script:MountedIso = $null; $script:Work = $null; $script:TmpFiles = @()
}

# Monta a ISO somente leitura e devolve o volume (letra de unidade e rótulo)
function Mount-Iso([string]$Path) {
    if ((Get-DiskImage -ImagePath $Path).Attached) {
        Fail "$(Split-Path -Leaf $Path) já está montada; ejete-a antes de continuar"
    }
    $img = Mount-DiskImage -ImagePath $Path -Access ReadOnly -StorageType ISO -PassThru
    $script:MountedIso = $Path
    $vol = $null
    foreach ($attempt in 1..10) {
        $vol = $img | Get-Volume -ErrorAction SilentlyContinue
        if ($vol -and $vol.DriveLetter) { break }
        Start-Sleep -Seconds 1
    }
    if (-not ($vol -and $vol.DriveLetter)) { Fail "falha ao montar $Path" }
    $vol
}

# Índice da imagem com o EditionID pedido, ou $null se a ISO não tiver essa edição
function Find-EditionIndex([string]$Wim) {
    foreach ($image in Get-WindowsImage -ImagePath $Wim) {
        if ((Get-WindowsImage -ImagePath $Wim -Index $image.ImageIndex).EditionId -eq $Edition) {
            return $image.ImageIndex
        }
    }
    $null
}

function Build-Iso([string]$IsoPath) {
    $outdir = Split-Path -Parent $IsoPath
    if ($Output) { $outdir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Output) }
    New-Item -ItemType Directory -Force -Path $outdir | Out-Null
    # A ISO gerada mantém o nome da original; sem -o, ela substitui a original
    $name = [IO.Path]::GetFileNameWithoutExtension($IsoPath)
    $out = Join-Path $outdir "$name.iso"

    # Cópia do conteúdo + ISO nova ficam no disco da saída ao mesmo tempo: ~2x o tamanho da ISO
    $need = 2 * (Get-Item -LiteralPath $IsoPath).Length + 1GB
    $root = [IO.Path]::GetPathRoot($outdir)
    if ($root -match '^[A-Za-z]:\\$') {
        $free = (New-Object IO.DriveInfo $root).AvailableFreeSpace
        if ($free -lt $need) {
            Fail ("espaço insuficiente em {0}: livres {1:N1} GB, necessários ~{2:N1} GB" -f $root, ($free / 1GB), ($need / 1GB))
        }
    }

    Log "Montando $(Split-Path -Leaf $IsoPath)"
    $vol = Mount-Iso $IsoPath
    $src = "$($vol.DriveLetter):\"
    $label = $vol.FileSystemLabel
    if (-not $label) { $label = 'WIN11' }
    if ($label.Length -gt 32) { $label = $label.Substring(0, 32) }

    $wim = Join-Path $src 'sources\install.wim'
    if (-not (Test-Path -LiteralPath $wim)) { $wim = Join-Path $src 'sources\install.esd' }
    if (-not (Test-Path -LiteralPath $wim)) {
        Fail "install.wim/install.esd não encontrado em $IsoPath (ISO já processada?)"
    }
    $index = Find-EditionIndex $wim
    if ($null -eq $index) { Fail "a edição '$Edition' não existe em $(Split-Path -Leaf $IsoPath)" }

    # Trabalha no mesmo disco da saída: o conteúdo ocupa ~9 GB
    $script:Work = Join-Path $outdir ".work_$name"
    if (Test-Path -LiteralPath $script:Work) { Remove-Item -LiteralPath $script:Work -Recurse -Force }
    New-Item -ItemType Directory -Path $script:Work | Out-Null

    Log 'Copiando arquivos'
    & robocopy.exe $src $script:Work /E /A-:R /XF install.wim install.esd /NFL /NDL /NJH /NJS /NP | Out-Null
    # robocopy: códigos abaixo de 8 indicam sucesso
    if ($LASTEXITCODE -ge 8) { Fail "robocopy falhou (código $LASTEXITCODE)" }

    # O DISM não divide .esd (compressão sólida): exporta antes a edição escolhida para .wim
    if ($wim.EndsWith('.esd')) {
        $tmpWim = Join-Path $outdir ".$name.install.wim"
        $script:TmpFiles += $tmpWim
        Log "Exportando a edição $Edition do install.esd para .wim"
        Export-WindowsImage -SourceImagePath $wim -SourceIndex $index -DestinationImagePath $tmpWim -CompressionType Max | Out-Null
        $wim = $tmpWim
    }

    # Divide o install.wim em partes < 4 GB: a ISO sai sem arquivos grandes
    # e o conteúdo também serve para pendrive FAT32
    Log "Dividindo $(Split-Path -Leaf $wim) em partes de $SplitMB MB"
    Split-WindowsImage -ImagePath $wim -SplitImagePath (Join-Path $script:Work 'sources\install.swm') -FileSize $SplitMB | Out-Null

    Log 'Gravando ei.cfg, PID.txt e autounattend.xml'
    $ascii = [Text.Encoding]::ASCII
    [IO.File]::WriteAllText((Join-Path $script:Work 'sources\ei.cfg'),
        "[EditionID]`r`n$Edition`r`n[Channel]`r`nRetail`r`n[VL]`r`n0`r`n", $ascii)
    [IO.File]::WriteAllText((Join-Path $script:Work 'sources\PID.txt'), "[PID]`r`nValue=$Key`r`n", $ascii)
    $xml = [IO.File]::ReadAllText($Template)
    $xml = $xml.Replace('@PRODUCT_KEY@', $Key)
    $xml = $xml.Replace('@LOCAL_USER@', [Security.SecurityElement]::Escape($User))
    $xml = $xml.Replace('@LOCAL_PASSWORD@', [Security.SecurityElement]::Escape($Password))
    [IO.File]::WriteAllText((Join-Path $script:Work 'autounattend.xml'), $xml, (New-Object Text.UTF8Encoding $false))

    # Gera num arquivo temporário e só troca pelo destino no final, para que
    # uma falha no meio do caminho nunca deixe a ISO original corrompida
    $tmpIso = Join-Path $outdir ".$name.iso.tmp"
    $script:TmpFiles += $tmpIso
    Log "Gerando $out"
    # Os caminhos de boot são relativos à pasta de trabalho: o -bootdata não aceita espaços
    Push-Location -LiteralPath $script:Work
    try {
        & $Oscdimg "-l$label" -m -o -u2 -udfver102 `
            '-bootdata:2#p0,e,bboot\etfsboot.com#pEF,e,befi\microsoft\boot\efisys.bin' `
            $script:Work $tmpIso | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail "oscdimg falhou (código $LASTEXITCODE)" }
    } finally {
        Pop-Location
    }

    # A ISO montada fica bloqueada: desmonta antes de substituí-la
    Dismount-DiskImage -ImagePath $script:MountedIso | Out-Null
    $script:MountedIso = $null
    Move-Item -LiteralPath $tmpIso -Destination $out -Force

    Clear-Work
    Log "Pronta: $out"
}

if ($Help) { Show-Usage; exit 0 }
if (-not $Iso) { Show-Usage; exit 1 }

$exitCode = 0
try {
    # O config é lido primeiro; as opções passadas na linha de comando têm precedência
    if (Test-Path -LiteralPath $Config) {
        $cfg = Read-Config $Config
        $map = @{ Key = 'PRODUCT_KEY'; Edition = 'EDITION'; User = 'LOCAL_USER'; Password = 'LOCAL_PASSWORD'; Output = 'OUTPUT_DIR' }
        foreach ($param in $map.Keys) {
            if (-not $PSBoundParameters.ContainsKey($param) -and $cfg.ContainsKey($map[$param])) {
                Set-Variable -Name $param -Value $cfg[$map[$param]]
            }
        }
    }

    if ($Key -cnotmatch '^[A-Z0-9]{5}(-[A-Z0-9]{5}){4}$') { Fail 'chave do produto ausente ou inválida (-k)' }
    if (-not $User) { Fail 'nome da conta local ausente (-u)' }
    if ($User -notmatch '^[^"/\\\[\]:;|=,+*?<>@]{1,20}$') { Fail "nome de conta local inválido: $User" }

    # Expande curingas (*.iso) e resolve para caminhos absolutos
    $isoPaths = foreach ($p in $Iso) {
        if (-not (Test-Path -Path $p -PathType Leaf)) { Fail "arquivo não encontrado: $p" }
        (Resolve-Path -Path $p).ProviderPath
    }
    Assert-Dependencies
    foreach ($path in $isoPaths) { Build-Iso $path }
} catch {
    [Console]::Error.WriteLine("Erro: $($_.Exception.Message)")
    $exitCode = 1
} finally {
    Clear-Work
}
exit $exitCode
