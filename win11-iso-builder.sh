#!/usr/bin/env bash
# Gera ISOs do Windows 11 que instalam uma edição fixa com a chave informada
# e criam uma conta local (sem exigir conta Microsoft no OOBE).
#
# Uso: ./win11-iso-builder.sh [opções] <iso> [<iso>...]
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TEMPLATE="$SCRIPT_DIR/templates/autounattend.xml"
SPLIT_MB=3800

PRODUCT_KEY=""
EDITION="Professional"
LOCAL_USER=""
LOCAL_PASSWORD=""
OUTPUT_DIR=""

usage() {
    cat <<EOF
Uso: $(basename "$0") [opções] <iso> [<iso>...]

Opções:
  -k, --key CHAVE         chave do produto (obrigatória)
  -e, --edition ID        EditionID a instalar (padrão: Professional)
  -u, --user NOME         nome da conta local de administrador (obrigatório)
  -p, --password SENHA    senha da conta local (padrão: sem senha)
  -o, --output DIR        pasta de saída (padrão: pasta da ISO original)
  -c, --config ARQUIVO    arquivo de configuração (padrão: config.env ao lado do script)
  -h, --help              mostra esta ajuda

Os valores de config.env são lidos primeiro; as opções acima os sobrescrevem.
EOF
}

die() { echo "Erro: $*" >&2; exit 1; }
log() { echo "==> $*"; }

xml_escape() {
    local s=$1
    s=${s//&/"&amp;"}; s=${s//</"&lt;"}; s=${s//>/"&gt;"}; s=${s//\"/"&quot;"}; s=${s//\'/"&apos;"}
    printf '%s' "$s"
}

# Escapa um texto para o lado de substituição do sed (delimitador |)
sed_escape() {
    local s=$1
    # Barras dentro das aspas simples são literais (não é tentativa de escapar aspas)
    # shellcheck disable=SC1003
    s=${s//\\/'\\'}; s=${s//&/'\&'}; s=${s//|/'\|'}
    printf '%s' "$s"
}

# Carrega o config antes de interpretar as opções, para que elas tenham precedência
CONFIG="$SCRIPT_DIR/config.env"
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    case ${args[i]} in
        -c|--config) CONFIG=${args[i + 1]:-} ;;
    esac
done
if [[ -f $CONFIG ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG"
fi

ISOS=()
while (($#)); do
    case $1 in
        -k|--key)      PRODUCT_KEY=$2; shift 2 ;;
        -e|--edition)  EDITION=$2; shift 2 ;;
        -u|--user)     LOCAL_USER=$2; shift 2 ;;
        -p|--password) LOCAL_PASSWORD=$2; shift 2 ;;
        -o|--output)   OUTPUT_DIR=$2; shift 2 ;;
        -c|--config)   shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        -*)            die "opção desconhecida: $1" ;;
        *)             ISOS+=("$1"); shift ;;
    esac
done

((${#ISOS[@]})) || { usage; exit 1; }
[[ $PRODUCT_KEY =~ ^[A-Z0-9]{5}(-[A-Z0-9]{5}){4}$ ]] || die "chave do produto ausente ou inválida (-k)"
[[ -n $LOCAL_USER ]] || die "nome da conta local ausente (-u)"
[[ $LOCAL_USER =~ ^[^\"/\\\[\]:\;\|=,+*?\<\>@]{1,20}$ ]] || die "nome de conta local inválido: $LOCAL_USER"

for cmd in udisksctl wimlib-imagex xorriso rsync; do
    command -v "$cmd" > /dev/null || die "comando '$cmd' não encontrado (sudo apt install udisks2 wimtools xorriso rsync)"
done

LOOP_DEV=""
MNT=""
WORK=""
cleanup() {
    [[ -n $WORK && -d $WORK ]] && rm -rf "$WORK"
    if [[ -n $LOOP_DEV ]]; then
        udisksctl unmount -b "$LOOP_DEV" > /dev/null 2>&1 || true
        udisksctl loop-delete -b "$LOOP_DEV" > /dev/null 2>&1 || true
    fi
    LOOP_DEV=""; WORK=""
}
trap cleanup EXIT

# Monta a ISO (UDF) via loop somente leitura, sem root; define LOOP_DEV e MNT
mount_iso() {
    local iso=$1 out mnt=""
    out=$(udisksctl loop-setup -r -f "$iso")
    LOOP_DEV=$(grep -o '/dev/loop[0-9]*' <<< "$out")
    [[ -n $LOOP_DEV ]] || die "falha ao criar loop para $iso"
    for _ in {1..10}; do
        mnt=$(lsblk -no MOUNTPOINT "$LOOP_DEV" | head -1)
        [[ -n $mnt ]] && break
        sleep 1
    done
    if [[ -z $mnt ]]; then
        udisksctl mount -b "$LOOP_DEV" > /dev/null
        mnt=$(lsblk -no MOUNTPOINT "$LOOP_DEV" | head -1)
    fi
    [[ -n $mnt ]] || die "falha ao montar $iso"
    MNT=$mnt
}

build_iso() {
    local iso=$1 src label outdir name out wim
    [[ -f $iso ]] || die "arquivo não encontrado: $iso"
    iso=$(realpath "$iso")
    outdir=${OUTPUT_DIR:-$(dirname "$iso")}
    mkdir -p "$outdir"
    name=$(basename "$iso" .iso)
    if [[ $name == *_Client_* ]]; then
        name=${name/_Client_/_${EDITION}_}
    else
        name=${name}_${EDITION}
    fi
    out="$outdir/$name.iso"
    [[ $out != "$iso" ]] || die "a ISO de saída sobrescreveria a original: $out"

    log "Montando $(basename "$iso")"
    mount_iso "$iso"
    src=$MNT
    label=$(lsblk -no LABEL "$LOOP_DEV" | head -1)

    wim="$src/sources/install.wim"
    [[ -f $wim ]] || wim="$src/sources/install.esd"
    [[ -f $wim ]] || die "install.wim/install.esd não encontrado em $iso"
    wimlib-imagex info "$wim" | grep -qx "Edition ID: *$EDITION" ||
        die "a edição '$EDITION' não existe em $(basename "$iso")"

    # Trabalha no mesmo disco da saída: o conteúdo ocupa ~9 GB e não cabe em tmpfs
    WORK="$outdir/.work_$name"
    rm -rf "$WORK"
    mkdir -p "$WORK"

    log "Copiando arquivos"
    rsync -a --exclude=sources/install.wim --exclude=sources/install.esd "$src"/ "$WORK"/
    chmod -R u+w "$WORK"

    # Divide o install.wim em partes < 4 GB: a ISO sai sem arquivos grandes
    # (dispensa UDF) e o conteúdo também serve para pendrive FAT32
    log "Dividindo $(basename "$wim") em partes de $SPLIT_MB MB"
    wimlib-imagex split "$wim" "$WORK/sources/install.swm" "$SPLIT_MB" > /dev/null

    log "Gravando ei.cfg, PID.txt e autounattend.xml"
    printf '[EditionID]\r\n%s\r\n[Channel]\r\nRetail\r\n[VL]\r\n0\r\n' "$EDITION" > "$WORK/sources/ei.cfg"
    printf '[PID]\r\nValue=%s\r\n' "$PRODUCT_KEY" > "$WORK/sources/PID.txt"
    local user pass
    user=$(sed_escape "$(xml_escape "$LOCAL_USER")")
    pass=$(sed_escape "$(xml_escape "$LOCAL_PASSWORD")")
    sed -e "s|@PRODUCT_KEY@|$PRODUCT_KEY|" \
        -e "s|@LOCAL_USER@|$user|g" \
        -e "s|@LOCAL_PASSWORD@|$pass|" \
        "$TEMPLATE" > "$WORK/autounattend.xml"

    log "Gerando $out"
    xorriso -as mkisofs -quiet -iso-level 3 -J -joliet-long -r -V "${label:-WIN11}" \
        -b boot/etfsboot.com -no-emul-boot -boot-load-size 8 \
        -eltorito-alt-boot -e efi/microsoft/boot/efisys.bin -no-emul-boot \
        -o "$out" "$WORK"

    cleanup
    log "Pronta: $out"
}

for iso in "${ISOS[@]}"; do
    build_iso "$iso"
done
