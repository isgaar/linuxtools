#!/bin/bash
# ==============================================================================
# Script para aplicar el tema de Zorin OS al GRUB de forma segura.
# Compatible con Zorin OS, Ubuntu, Debian, Fedora, Arch Linux y derivadas.
# ==============================================================================

set -eo pipefail

# Asegurar que se ejecute con privilegios de root (auto-escalación si es necesario)
if [ "$EUID" -ne 0 ]; then
    echo "Este script necesita privilegios de root para modificar la configuración de GRUB."
    echo "Re-ejecutando con sudo..."
    exec sudo "$0" "$@"
fi

# Obtener de forma dinámica la carpeta donde se encuentra el script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

THEME_NAME="zorin"
BACKUP_DIR="$SCRIPT_DIR/tema_grub_extraido"
BACKUP_TAR="$SCRIPT_DIR/tema_grub_extraido.tar.gz"

# Detectar distribución
DISTRO_NAME="GNU/Linux"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO_NAME="${PRETTY_NAME:-${NAME:-GNU/Linux}}"
fi

echo "=================================================="
echo "   Aplicador de Tema de GRUB (Zorin OS)          "
echo "=================================================="
echo "Sistema detectado: $DISTRO_NAME"

# 1. Determinar el destino óptimo del tema según la distribución y particiones
# En Fedora / RHEL y sistemas con partición /boot separada o cifrado LUKS,
# el tema debe residir en /boot/grub2/themes/ para que GRUB pueda cargarlo antes
# de desbloquear la raíz.
if [ -d "/boot/grub2" ]; then
    DEST_THEME_DIR="/boot/grub2/themes/$THEME_NAME"
elif [ -d "/boot/grub" ]; then
    DEST_THEME_DIR="/boot/grub/themes/$THEME_NAME"
else
    DEST_THEME_DIR="/usr/share/grub/themes/$THEME_NAME"
fi

# 2. Determinar el origen del tema
SOURCE_PATH=""
if [ -d "$BACKUP_DIR" ] && [ -f "$BACKUP_DIR/theme.txt" ]; then
    SOURCE_PATH="$BACKUP_DIR"
    SOURCE_TYPE="dir"
    echo "Se detectó la carpeta del tema extraído en: $SOURCE_PATH"
elif [ -f "$BACKUP_TAR" ]; then
    SOURCE_PATH="$BACKUP_TAR"
    SOURCE_TYPE="tar"
    echo "Se detectó el archivo comprimido del tema extraído en: $SOURCE_PATH"
else
    echo "Error: No se encontró la carpeta del tema ($BACKUP_DIR) ni el archivo comprimido ($BACKUP_TAR)."
    echo "Asegúrate de ejecutar primero el script 'extraer_tema.sh' o verificar los archivos."
    exit 1
fi

# 3. Crear el directorio de destino
echo "Directorio de destino del tema: $DEST_THEME_DIR"
mkdir -p "$DEST_THEME_DIR"

# 4. Copiar o extraer los archivos del tema al destino
if [ "$SOURCE_TYPE" = "dir" ]; then
    echo "Copiando archivos del tema..."
    cp -r "$SOURCE_PATH"/* "$DEST_THEME_DIR"/
else
    echo "Extrayendo archivos del tema..."
    tar -xzf "$SOURCE_PATH" -C "$DEST_THEME_DIR"/
fi

# Verificar que el archivo theme.txt esté en su lugar
if [ ! -f "$DEST_THEME_DIR/theme.txt" ]; then
    echo "Error: El archivo theme.txt no se encuentra en el destino. La estructura del tema es incorrecta."
    exit 1
fi

# Enlace simbólico en /usr/share/grub/themes para compatibilidad con herramientas de sistema
if [ "$DEST_THEME_DIR" != "/usr/share/grub/themes/$THEME_NAME" ]; then
    mkdir -p "/usr/share/grub/themes" 2>/dev/null || true
    ln -sfn "$DEST_THEME_DIR" "/usr/share/grub/themes/$THEME_NAME" 2>/dev/null || true
fi

# 5. Modificar /etc/default/grub de manera segura
GRUB_CONFIG="/etc/default/grub"
if [ ! -f "$GRUB_CONFIG" ]; then
    echo "Error: No se encontró el archivo de configuración de GRUB en $GRUB_CONFIG."
    exit 1
fi

# Respaldar la configuración actual de GRUB con fecha y hora
BACKUP_FILE="${GRUB_CONFIG}.backup_$(date +%Y%m%d_%H%M%S)"
echo "Creando respaldo de seguridad de GRUB en: $BACKUP_FILE"
cp "$GRUB_CONFIG" "$BACKUP_FILE"

echo "Configurando /etc/default/grub para habilitar la interfaz gráfica..."

# En Fedora es común 'GRUB_TERMINAL_OUTPUT="console"', y en Debian/Ubuntu 'GRUB_TERMINAL=console'.
# Deshabilitar cualquier salida de consola en modo texto para habilitar 'gfxterm'
if grep -qE '^GRUB_TERMINAL(_OUTPUT)?="?console"?' "$GRUB_CONFIG"; then
    echo "Habilitando modo gráfico (comentando líneas que fuerzan modo texto console)..."
    sed -i -E 's/^(GRUB_TERMINAL(_OUTPUT)?="?console"?)/#\1/g' "$GRUB_CONFIG"
fi

# Asegurar resolución gráfica si no está definida
if ! grep -q "^GRUB_GFXMODE=" "$GRUB_CONFIG"; then
    echo "Añadiendo GRUB_GFXMODE=\"auto\" para modo de pantalla óptimo..."
    echo 'GRUB_GFXMODE="auto"' >> "$GRUB_CONFIG"
fi

# Asegurar salto de línea final
sed -i -e '$a\' "$GRUB_CONFIG"

# Eliminar líneas anteriores de GRUB_THEME para evitar duplicados
sed -i '/^GRUB_THEME=/d' "$GRUB_CONFIG"

# Añadir la nueva línea del tema
echo "GRUB_THEME=\"$DEST_THEME_DIR/theme.txt\"" >> "$GRUB_CONFIG"
echo "Configurado: GRUB_THEME=\"$DEST_THEME_DIR/theme.txt\""

# 6. Actualizar la configuración de GRUB según la distribución
echo "Actualizando la configuración generada de GRUB..."
if command -v update-grub &> /dev/null; then
    echo "Ejecutando: update-grub"
    update-grub
elif command -v grub2-mkconfig &> /dev/null; then
    # En Fedora moderno (34+), /boot/efi/EFI/fedora/grub.cfg es solo un stub;
    # el archivo canónico donde se debe generar siempre es /boot/grub2/grub.cfg.
    if [ -f /boot/grub2/grub.cfg ] || [ -d /boot/grub2 ]; then
        echo "Ejecutando: grub2-mkconfig -o /boot/grub2/grub.cfg"
        grub2-mkconfig -o /boot/grub2/grub.cfg
    elif [ -f /boot/grub/grub.cfg ] || [ -d /boot/grub ]; then
        echo "Ejecutando: grub2-mkconfig -o /boot/grub/grub.cfg"
        grub2-mkconfig -o /boot/grub/grub.cfg
    elif [ -f /etc/grub2.cfg ]; then
        echo "Ejecutando: grub2-mkconfig -o /etc/grub2.cfg"
        grub2-mkconfig -o /etc/grub2.cfg
    else
        echo "Ejecutando: grub2-mkconfig -o /boot/grub2/grub.cfg"
        grub2-mkconfig -o /boot/grub2/grub.cfg
    fi
elif command -v grub-mkconfig &> /dev/null; then
    if [ -f /boot/grub2/grub.cfg ] || [ -d /boot/grub2 ]; then
        echo "Ejecutando: grub-mkconfig -o /boot/grub2/grub.cfg"
        grub-mkconfig -o /boot/grub2/grub.cfg
    else
        echo "Ejecutando: grub-mkconfig -o /boot/grub/grub.cfg"
        grub-mkconfig -o /boot/grub/grub.cfg
    fi
else
    echo "¡ATENCIÓN! No se encontró el comando estándar de actualización (update-grub, grub2-mkconfig o grub-mkconfig)."
    echo "Por favor, ejecuta la actualización de GRUB manualmente para tu distribución."
    exit 1
fi

echo ""
echo "=================================================="
echo "¡Tema de GRUB aplicado con éxito!"
echo "Ubicación del tema: $DEST_THEME_DIR"
echo "Al reiniciar, tu pantalla de GRUB lucirá el tema."
echo "=================================================="
