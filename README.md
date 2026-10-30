# win11-iso-builder

Gera, a partir das ISOs oficiais do Windows 11, ISOs que:

- instalam **uma edição fixa** (padrão: Professional) já com a **chave do produto** informada;
- criam uma **conta local de administrador**, sem exigir conta Microsoft nem internet no OOBE;
- aceitam a EULA automaticamente.

O particionamento continua **manual**: o instalador pergunta em qual disco instalar, nada é
apagado sem confirmação. Idioma, região, teclado e telas de privacidade também seguem
interativos.

Roda no Linux, sem root (`win11-iso-builder.sh`), ou no Windows, como administrador
(`win11-iso-builder.ps1` — veja [Windows](#windows)).

## Requisitos

```bash
sudo apt install udisks2 wimtools xorriso rsync
```

Espaço livre: cerca de 2× o tamanho da ISO (~18 GB) no disco da pasta de saída — o conteúdo é
copiado para uma pasta temporária `.work_*` e a nova ISO é gerada em `.<nome>.iso.tmp`, ambos
ao lado do destino e removidos no final. Não use `/tmp` como saída se ele for tmpfs.

## Uso

```bash
# usa a chave, a edição e o usuário definidos em config.env
./win11-iso-builder.sh ~/Downloads/Windows11_Client_x64_pt-pt_26300_9457.iso
```

Ou tudo pela linha de comando (as opções têm precedência sobre o `config.env`):

```bash
./win11-iso-builder.sh -k XXXXX-XXXXX-XXXXX-XXXXX-XXXXX -u Paulo \
    ~/Downloads/Windows11_Client_x64_en-us_*.iso ~/Downloads/Windows11_Client_x64_pt-pt_*.iso
```

| Opção | Descrição |
|---|---|
| `-k`, `--key` | Chave do produto (obrigatória) |
| `-e`, `--edition` | EditionID a instalar — `Professional`, `Core`, `Education`, `ProfessionalWorkstation`… (padrão `Professional`) |
| `-u`, `--user` | Nome da conta local de administrador (obrigatório, até 20 caracteres) |
| `-p`, `--password` | Senha da conta local (padrão: sem senha) |
| `-o`, `--output` | Grava a ISO gerada em outra pasta (padrão: substitui a original) |
| `-c`, `--config` | Arquivo de configuração (padrão: `config.env` ao lado do script) |

A ISO gerada **mantém o nome da original**. Sem `-o`, ela **substitui a original** — guarde uma
cópia se quiser preservá-la, ou use `-o <pasta>` para gravar em outro lugar. A troca só
acontece depois que a nova ISO foi gerada por completo; se algo falhar no meio, a original
fica intacta.

Uma ISO já processada não pode ser processada de novo (o `install.wim` virou `.swm`); para
mudar chave, edição ou usuário, parta da ISO oficial.

Para listar as edições de uma ISO: monte-a e rode `wimlib-imagex info <montagem>/sources/install.wim`.

## Windows

`win11-iso-builder.ps1` faz o mesmo no Windows 10/11, com PowerShell 5.1 ou 7, e usa o mesmo
`config.env` e o mesmo template. Precisa de:

- PowerShell **como administrador** (o DISM exige);
- `oscdimg.exe`, do [Windows ADK](https://learn.microsoft.com/windows-hardware/get-started/adk-install)
  — basta o componente **Deployment Tools**.

Antes de mexer em qualquer ISO o script confere as dependências: privilégio de administrador,
cmdlets do DISM e de montagem (`Get-WindowsImage`, `Split-WindowsImage`, `Mount-DiskImage`…),
`robocopy`, o template e o espaço livre (~2× o tamanho da ISO). Se o `oscdimg.exe` não estiver
no `PATH` nem na pasta padrão do ADK, ele **oferece instalar só o Deployment Tools** — pelo
`winget` (`Microsoft.WindowsADK`) ou, sem ele, baixando o `adksetup.exe` oficial da Microsoft e
conferindo a assinatura digital antes de executá-lo. Com `-y` instala sem perguntar.

```powershell
powershell -ExecutionPolicy Bypass -File .\win11-iso-builder.ps1 $HOME\Downloads\Windows11_Client_x64_pt-pt_26300_9457.iso

# opções equivalentes às do script bash (-k, -e, -u, -p, -o, -c), aceita curingas;
# -y instala o Windows ADK sem perguntar, se faltar
.\win11-iso-builder.ps1 -k XXXXX-XXXXX-XXXXX-XXXXX-XXXXX -u Paulo $HOME\Downloads\Windows11_*.iso
```

Diferenças em relação à versão Linux:

- monta a ISO com `Mount-DiskImage` (ela não pode estar montada antes), copia com `robocopy` e
  divide o `install.wim` com `Split-WindowsImage` (DISM);
- se a ISO tiver `install.esd`, que o DISM não divide, só a edição escolhida é exportada para
  `.wim` antes da divisão;
- a ISO é gerada pelo `oscdimg` em UDF 1.02, também bootável em BIOS e UEFI.

## O que o script faz

1. Monta a ISO via loop somente leitura com `udisksctl` (as ISOs da Microsoft são UDF; a parte
   ISO 9660 só contém um `README.TXT`, então `xorriso -indev` não serve para ler o conteúdo).
2. Copia tudo menos o `install.wim` para a pasta de trabalho.
3. Divide o `install.wim` em `install.swm`, `install2.swm`… de 3800 MB. O instalador do Windows
   lê `.swm` nativamente; assim nenhum arquivo passa de 4 GB, a ISO dispensa UDF e o conteúdo
   pode ser copiado para um pendrive FAT32.
4. Grava:
   - `sources/ei.cfg` — fixa a edição (`[EditionID]`, canal Retail);
   - `sources/PID.txt` — chave do produto, para o instalador não perguntar;
   - `autounattend.xml` na raiz — gerado de [`templates/autounattend.xml`](templates/autounattend.xml).
5. Gera a ISO com `xorriso` (ISO 9660 nível 3 + Joliet), bootável em BIOS
   (`boot/etfsboot.com`) e UEFI (`efi/microsoft/boot/efisys.bin`), num arquivo temporário que
   então substitui o destino.

## Conta local

A partir dos builds 26xxx a Microsoft removeu os atalhos usados no OOBE
(`oobe\bypassnro`, `start ms-cxh:localonly`). O método que continua funcionando é o
`autounattend.xml` declarar a conta em `UserAccounts/LocalAccounts` no passo `oobeSystem` —
o OOBE então pula a tela de conta. O template ainda grava `BypassNRO=1` no registro (passo
`specialize`) para não exigir rede, nos builds em que isso ainda vale.

Se a conta for criada sem senha, o Windows entra direto nela; defina a senha depois em
**Configurações → Contas → Opções de entrada**.

## Arquivos

| Arquivo | Conteúdo |
|---|---|
| `win11-iso-builder.sh` | Script principal (Linux) |
| `win11-iso-builder.ps1` | Versão para Windows (PowerShell) |
| `templates/autounattend.xml` | Modelo do arquivo de resposta (`@PRODUCT_KEY@`, `@LOCAL_USER@`, `@LOCAL_PASSWORD@`) |
| `config.env` | Configuração padrão: chave do produto, edição, conta local e pasta de saída |
