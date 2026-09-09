#!/usr/bin/env bash
#
# ==============================================================================
# Script de Instalación Automatizada de VirtualBox para Fedora Linux
# ==============================================================================
# Compatible con Fedora 39/40/41/42/43/44+ (KDE / GNOME / etc.)
# 
# Características:
#  - Detección y verificación de la distribución Fedora.
#  - Habilitación de repositorios RPM Fusion (Free y Non-Free) si no están activos.
#  - Instalación de kernel-devel, kernel-headers y herramientas de compilación.
#  - Gestión anticipada de Secure Boot y generación de claves MOK para akmods.
#  - Instalación de VirtualBox y el metapaquete akmod-VirtualBox.
#  - Compilación y firma forzada (--rebuild) de módulos del kernel con akmods.
#  - Adición del usuario actual al grupo vboxusers.
#  - Descarga e instalación opcional del Oracle VirtualBox Extension Pack.
# ==============================================================================

set -eo pipefail

# Colores y estilos de terminal
BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # Sin color

# Funciones de salida formateada
log_info() {
    echo -e "${BLUE}${BOLD}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}${BOLD}[OK]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}${BOLD}[AVISO]${NC} $1"
}

log_error() {
    echo -e "${RED}${BOLD}[ERROR]${NC} $1" >&2
}

log_step() {
    echo -e "\n${CYAN}${BOLD}==>${NC} ${BOLD}$1${NC}"
}

# 1. Comprobar permisos de superusuario
if [ "$EUID" -ne 0 ]; then
    log_info "Este script requiere permisos de administrador (root)."
    log_info "Re-ejecutando con sudo..."
    exec sudo "$0" "$@"
fi

# Detectar usuario real (no root si se ejecutó con sudo)
REAL_USER="${SUDO_USER:-$USER}"
if [ "$REAL_USER" = "root" ]; then
    # Si se ejecutó directamente como root, intentar buscar usuario logueado en consola/escritorio
    REAL_USER=$(logname 2>/dev/null || who | awk '{print $1}' | head -n 1)
fi

echo -e "${CYAN}======================================================${NC}"
echo -e "${BOLD}   Instalador de VirtualBox para Fedora Linux         ${NC}"
echo -e "${CYAN}======================================================${NC}"
echo -e "Usuario destino: ${BOLD}${REAL_USER}${NC}"
echo -e "Kernel actual:   ${BOLD}$(uname -r)${NC}"
echo -e "Arquitectura:    ${BOLD}$(uname -m)${NC}"

# 2. Validar distribución Fedora
log_step "Comprobando compatibilidad de la distribución..."
if [ ! -f /etc/os-release ]; then
    log_error "No se pudo identificar la distribución (/etc/os-release no existe)."
    exit 1
fi

. /etc/os-release

if [[ "$ID" != "fedora" && "$ID_LIKE" != *"fedora"* ]]; then
    log_error "Este script está optimizado para Fedora. Tu sistema es: ${NAME:-desconocido}."
    exit 1
fi
log_success "Sistema detectado: $PRETTY_NAME"

# 3. Comprobar y habilitar RPM Fusion
log_step "Verificando repositorios RPM Fusion (Free y Non-Free)..."
FEDORA_VER=$(rpm -E %fedora)

if ! dnf repolist | grep -q "rpmfusion-free"; then
    log_info "Instalando repositorios RPM Fusion Free..."
    dnf install -y "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_VER}.noarch.rpm"
else
    log_success "Repositorio RPM Fusion Free ya está configurado."
fi

if ! dnf repolist | grep -q "rpmfusion-nonfree"; then
    log_info "Instalando repositorios RPM Fusion Non-Free..."
    dnf install -y "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_VER}.noarch.rpm"
else
    log_success "Repositorio RPM Fusion Non-Free ya está configurado."
fi

# 4. Instalar dependencias del kernel y herramientas de construcción
log_step "Instalando dependencias de compilación y cabeceras del kernel..."
RUNNING_KERNEL=$(uname -r)

dnf install -y \
    gcc \
    make \
    kernel-headers \
    "kernel-devel-${RUNNING_KERNEL}" \
    akmods || {
        log_warn "No se pudo encontrar kernel-devel exacto para ${RUNNING_KERNEL}. Instalando kernel-devel genérico..."
        dnf install -y kernel-devel
    }

log_success "Dependencias del kernel y akmods instaladas correctamente."

# 5. Gestión anticipada de Secure Boot y claves MOK (ANTES de compilar kmods)
log_step "Comprobando estado de Secure Boot y claves de firma..."
SECURE_BOOT_ENABLED=false
MOK_KEY_DIR="/etc/pki/akmods/certs"
MOK_DER="${MOK_KEY_DIR}/public_key.der"
MOK_ENROLLED=false

if command -v mokutil >/dev/null 2>&1; then
    if mokutil --sb-state 2>/dev/null | grep -qi "enabled"; then
        SECURE_BOOT_ENABLED=true
        log_warn "Secure Boot está HABILITADO en este sistema."
    else
        log_info "Secure Boot está deshabilitado."
    fi
else
    log_info "mokutil no disponible. Saltando verificación de Secure Boot."
fi

if [ "$SECURE_BOOT_ENABLED" = true ]; then
    # Si no existe la clave para akmods, generarla AHORA antes de construir cualquier módulo
    if [ ! -f "$MOK_DER" ]; then
        log_info "Generando clave de firma local para akmods (kmodgenca)..."
        if [ -x /usr/sbin/kmodgenca ]; then
            /usr/sbin/kmodgenca
        else
            akmodsbuild --target-user root 2>/dev/null || true
        fi
    fi

    if [ -f "$MOK_DER" ]; then
        log_success "Clave pública de firma encontrada en: $MOK_DER"
        
        # Comprobar si ya está inscrita en MOK (UEFI)
        if mokutil --test-key "$MOK_DER" 2>&1 | grep -qi "is enrolled"; then
            MOK_ENROLLED=true
            log_success "La clave MOK ya está inscrita en UEFI. Los módulos firmados se cargarán sin problema."
        else
            log_warn "La clave MOK para akmods aún no ha sido inscrita en la UEFI (Secure Boot)."
            echo -e "${YELLOW}----------------------------------------------------------------------${NC}"
            echo -e "${BOLD}IMPORTANTE PARA SECURE BOOT:${NC}"
            echo -e "Para que los módulos del kernel de VirtualBox se puedan cargar:"
            echo -e "1. Debes inscribir la clave en MOK ejecutando:"
            echo -e "   ${CYAN}sudo mokutil --import ${MOK_DER}${NC}"
            echo -e "2. El comando te pedirá una contraseña temporal (recuérdala)."
            echo -e "3. Reinicia tu PC. En el menú azul 'Perform MOK management':"
            echo -e "   - Selecciona ${BOLD}Enroll MOK${NC}"
            echo -e "   - Selecciona ${BOLD}Continue${NC} -> ${BOLD}Yes${NC}"
            echo -e "   - Introduce la contraseña temporal que creaste."
            echo -e "${YELLOW}----------------------------------------------------------------------${NC}"
            
            read -r -p "¿Deseas importar la clave ahora en MOK con mokutil? [S/n]: " RESP_MOK || RESP_MOK="s"
            if [[ "$RESP_MOK" =~ ^([sS][iI]?|[yY][eE]?[sS]?|"")$ ]]; then
                mokutil --import "$MOK_DER" || log_warn "No se pudo registrar la clave con mokutil."
            fi
        fi
    else
        log_warn "No se pudo generar ni localizar $MOK_DER."
    fi
fi

# 6. Instalar paquetes de VirtualBox
log_step "Instalando paquetes de VirtualBox..."
dnf install -y VirtualBox akmod-VirtualBox

log_success "VirtualBox y akmod-VirtualBox instalados."

# 7. Compilar y firmar módulos del kernel con akmods (utilizando --rebuild para asegurar firma)
log_step "Compilando y firmando módulos del kernel con akmods (--rebuild)..."
akmods --rebuild --kernels "$RUNNING_KERNEL" || {
    log_warn "Fallo con akmods --rebuild para $RUNNING_KERNEL. Reintentando akmods general..."
    akmods --rebuild --force
}

log_success "Módulos de VirtualBox compilados y firmados."

# 8. Agregar usuario al grupo vboxusers
if [ -n "$REAL_USER" ] && id "$REAL_USER" >/dev/null 2>&1; then
    log_step "Agregando al usuario '${REAL_USER}' al grupo 'vboxusers'..."
    usermod -aG vboxusers "$REAL_USER"
    log_success "Usuario '${REAL_USER}' añadido al grupo vboxusers."
fi

# 9. Descargar e instalar el Extension Pack (Opcional)
log_step "¿Deseas instalar el Oracle VM VirtualBox Extension Pack?"
echo -e "El Extension Pack proporciona soporte para USB 2.0/3.0, cifrado de disco y NVMe."
read -r -p "¿Instalar Extension Pack ahora? [S/n]: " RESP_EXT || RESP_EXT="s"

if [[ "$RESP_EXT" =~ ^([sS][iI]?|[yY][eE]?[sS]?|"")$ ]]; then
    VBOX_VERSION=$(rpm -q --queryformat '%{VERSION}' VirtualBox 2>/dev/null || true)
    
    if [ -z "$VBOX_VERSION" ]; then
        VBOX_VERSION=$(VBoxManage -v 2>/dev/null | cut -d 'r' -f 1 || true)
    fi

    if [ -n "$VBOX_VERSION" ]; then
        log_info "Versión detectada de VirtualBox: $VBOX_VERSION"
        EXTPACK_FILE="/tmp/Oracle_VirtualBox_Extension_Pack-${VBOX_VERSION}.vbox-extpack"
        EXTPACK_URL="https://download.virtualbox.org/virtualbox/${VBOX_VERSION}/Oracle_VirtualBox_Extension_Pack-${VBOX_VERSION}.vbox-extpack"
        
        log_info "Descargando Extension Pack desde: $EXTPACK_URL"
        if curl -fL "$EXTPACK_URL" -o "$EXTPACK_FILE"; then
            log_info "Instalando Extension Pack..."
            echo "y" | VBoxManage extpack install --replace "$EXTPACK_FILE" && {
                log_success "Extension Pack instalado exitosamente."
                rm -f "$EXTPACK_FILE"
            } || log_warn "No se pudo instalar el Extension Pack automáticamente."
        else
            log_warn "No se pudo descargar el Extension Pack para la versión $VBOX_VERSION."
            log_info "Puedes descargarlo manualmente desde: https://www.virtualbox.org/wiki/Downloads"
        fi
    else
        log_warn "No se pudo detectar la versión de VirtualBox para descargar el Extension Pack."
    fi
fi

# 10. Descargar VBoxGuestAdditions.iso (evita fallo de descarga de certificado en GUI)
log_step "Configurando imagen ISO de Guest Additions..."
VBOX_VERSION=$(rpm -q --queryformat '%{VERSION}' VirtualBox 2>/dev/null || true)
if [ -z "$VBOX_VERSION" ]; then
    VBOX_VERSION=$(VBoxManage -v 2>/dev/null | cut -d 'r' -f 1 || true)
fi

if [ -n "$VBOX_VERSION" ]; then
    GUEST_ADD_URL="https://download.virtualbox.org/virtualbox/${VBOX_VERSION}/VBoxGuestAdditions_${VBOX_VERSION}.iso"
    mkdir -p /usr/share/virtualbox
    mkdir -p "/home/${REAL_USER}/.config/VirtualBox" 2>/dev/null || true

    if [ ! -f "/usr/share/virtualbox/VBoxGuestAdditions.iso" ]; then
        log_info "Descargando VBoxGuestAdditions_${VBOX_VERSION}.iso..."
        if curl -fL "$GUEST_ADD_URL" -o "/usr/share/virtualbox/VBoxGuestAdditions.iso"; then
            cp "/usr/share/virtualbox/VBoxGuestAdditions.iso" "/home/${REAL_USER}/.config/VirtualBox/VBoxGuestAdditions_${VBOX_VERSION}.iso" 2>/dev/null || true
            ln -sf "/usr/share/virtualbox/VBoxGuestAdditions.iso" "/home/${REAL_USER}/.config/VirtualBox/VBoxGuestAdditions.iso" 2>/dev/null || true
            chown -R "${REAL_USER}:${REAL_USER}" "/home/${REAL_USER}/.config/VirtualBox" 2>/dev/null || true
            log_success "Guest Additions ISO configurado correctamente para las máquinas virtuales."
        else
            log_warn "No se pudo descargar automáticamente el Guest Additions ISO."
        fi
    else
        log_success "Guest Additions ISO ya presente en /usr/share/virtualbox/VBoxGuestAdditions.iso."
    fi
fi

# 10. Iniciar servicio y cargar módulos
log_step "Iniciando servicio vboxdrv y cargando módulos..."
systemctl restart vboxdrv.service 2>/dev/null || true

if modprobe vboxdrv 2>/dev/null; then
    log_success "Módulo vboxdrv cargado y funcionando exitosamente."
else
    if [ "$SECURE_BOOT_ENABLED" = true ] && [ "$MOK_ENROLLED" = false ]; then
        log_warn "No se pudo cargar vboxdrv aún porque la clave MOK no ha sido confirmada en el reinicio."
        log_warn "Por favor reinicia tu PC y selecciona 'Enroll MOK' en la pantalla azul de la UEFI."
    else
        log_warn "No se pudo cargar vboxdrv de inmediato. Puede requerir reiniciar el sistema."
    fi
fi

# 11. Resumen final
echo -e "\n${GREEN}======================================================${NC}"
echo -e "${BOLD}       ¡Instalación de VirtualBox Finalizada!         ${NC}"
echo -e "${GREEN}======================================================${NC}"
echo -e "1. ${BOLD}Grupo de usuarios:${NC} El usuario '${REAL_USER}' fue añadido a 'vboxusers'."
echo -e "   Para aplicar los permisos en tu terminal actual sin cerrar sesión:"
echo -e "   ${CYAN}newgrp vboxusers${NC}"

if [ "$SECURE_BOOT_ENABLED" = true ] && [ "$MOK_ENROLLED" = false ]; then
    echo -e "2. ${BOLD}Secure Boot:${NC} Reinicia el sistema para completar la inscripción de la clave MOK."
else
    echo -e "2. ${BOLD}Módulos del Kernel:${NC} Compilados y firmados para el kernel actual."
fi

echo -e "3. Puedes iniciar VirtualBox desde el menú de aplicaciones o con:"
echo -e "   ${CYAN}VirtualBox &${NC}\n"
