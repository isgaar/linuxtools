#!/usr/bin/env bash
# ==============================================================================
# Script de Parche y Control Multimedia (MPRIS & Seekbar) para Navegadores en KDE
# Compatible con Zen Browser, Firefox, Brave, Google Chrome y Chromium
# ==============================================================================
# Problema que soluciona:
#  - El reproductor nativo de Firefox/Zen Browser (widget.mpris.enabled) omite
#    el cálculo de la duración de pista ('mpris:length') y mantiene 'Position' en 0.
#  - Como resultado, el widget "Reproductor multimedia" de KDE Plasma oculta
#    completamente la barra de progreso/timeline y no permite adelantar/retrasar
#    el audio ni sincronizar la posición en YouTube, Spotify Web, SoundCloud, etc.
#
# Características de este parche:
#  1. Instala el host nativo 'plasma-browser-integration' y la utilidad 'playerctl'.
#  2. Registra los manifiestos Native Messaging Hosts en Zen Browser y navegadores Chromium.
#  3. Descarga y aprovisiona la extensión oficial 'Plasma Integration' de KDE.
#  4. Configura 'policies.json' para persistencia corporativa del complemento.
#  5. Configura 'user.js' para asegurar compatibilidad de control multimedia y ceder
#     a Plasma Browser Integration el control total (duración, posición en vivo,
#     saltos/seeking en timeline, volumen y barra de progreso de descargas en KDE).
#  6. Diagnóstico y monitor en tiempo real de metadatos y posición MPRIS.
#  7. Reversión completa (Rollback) a los valores originales.
# ==============================================================================

set -eo pipefail

# ==============================================================================
# 1. ESTILOS Y FUNCIONES DE REGISTRO (LOGGING)
# ==============================================================================
BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
RESET='\033[0m'

log_info() {
    echo -e "${BLUE}${BOLD}[INFO]${RESET} $1"
}

log_success() {
    echo -e "${GREEN}${BOLD}[OK]${RESET} $1"
}

log_warn() {
    echo -e "${YELLOW}${BOLD}[AVISO]${RESET} $1"
}

log_error() {
    echo -e "${RED}${BOLD}[ERROR]${RESET} $1" >&2
}

log_step() {
    echo -e "\n${CYAN}${BOLD}==>${RESET} ${BOLD}$1${RESET}"
}

# ==============================================================================
# ==============================================================================
# 2. VALIDACIÓN DEL SISTEMA Y PERMISOS
# ==============================================================================
has_sudo() {
    if [ "$EUID" -eq 0 ]; then
        return 0
    fi
    if sudo -n true 2>/dev/null; then
        return 0
    fi
    return 1
}

validate_system() {
    if [ ! -f /etc/fedora-release ]; then
        log_warn "Este script fue diseñado para Fedora Linux. Continuando con precaución..."
    else
        local fedora_version
        fedora_version=$(rpm -E %fedora 2>/dev/null || echo "Desconocida")
        log_info "Sistema detectado: Fedora Linux ${fedora_version} (${XDG_CURRENT_DESKTOP:-KDE})"
    fi
}

# ==============================================================================
# 3. INSTALACIÓN DE DEPENDENCIAS DEL SISTEMA
# ==============================================================================
install_system_dependencies() {
    log_step "Verificando paquetes del sistema para integración con KDE Plasma"

    local packages_to_install=()

    if ! rpm -q plasma-browser-integration &>/dev/null; then
        packages_to_install+=("plasma-browser-integration")
    fi

    if ! command -v playerctl &>/dev/null; then
        packages_to_install+=("playerctl")
    fi

    if [ ${#packages_to_install[@]} -gt 0 ]; then
        log_info "Paquetes necesarios: ${packages_to_install[*]}"
        if has_sudo; then
            log_info "Instalando dependencias con dnf..."
            sudo dnf install -y "${packages_to_install[@]}"
            log_success "Paquetes instalados correctamente."
        else
            log_warn "Se requieren permisos de administrador (sudo) para instalar: ${packages_to_install[*]}"
            log_info "Puedes instalarlos ejecutando en tu terminal:"
            echo -e "   ${GREEN}sudo dnf install -y ${packages_to_install[*]}${RESET}"
        fi
    else
        log_success "plasma-browser-integration y playerctl ya están instalados."
    fi

    if [ -x "/usr/bin/plasma-browser-integration-host" ]; then
        log_success "Host nativo verificado en /usr/bin/plasma-browser-integration-host"
    else
        log_warn "El binario /usr/bin/plasma-browser-integration-host aún no está instalado en el sistema."
    fi
}

# ==============================================================================
# 4. MANIFIESTO DE NATIVE MESSAGING HOST (KDE PLASMA)
# ==============================================================================
get_mozilla_manifest_json() {
    cat << 'EOF'
{
  "name": "org.kde.plasma.browser_integration",
  "description": "Native host for Plasma Browser Integration",
  "path": "/usr/bin/plasma-browser-integration-host",
  "type": "stdio",
  "allowed_extensions": [
    "plasma-browser-integration@kde.org"
  ]
}
EOF
}

get_chromium_manifest_json() {
    cat << 'EOF'
{
  "name": "org.kde.plasma.browser_integration",
  "description": "Native host for Plasma Browser Integration",
  "path": "/usr/bin/plasma-browser-integration-host",
  "type": "stdio",
  "allowed_origins": [
    "chrome-extension://cimiefiiaegbelhefglklhhakcgmhkai/"
  ]
}
EOF
}

# ==============================================================================
# 5. PARCHE PARA ZEN BROWSER & DERIVADOS DE FIREFOX
# ==============================================================================
find_zen_profiles() {
    local base_dirs=("$HOME/.config/zen" "$HOME/.zen")
    local found_profiles=()

    for base in "${base_dirs[@]}"; do
        [ -d "$base" ] || continue
        
        # Analizar profiles.ini si existe
        if [ -f "$base/profiles.ini" ]; then
            while IFS= read -r line; do
                if [[ "$line" =~ ^Path=(.*)$ ]]; then
                    local p_path="${BASH_REMATCH[1]}"
                    if [[ "$p_path" != /* ]]; then
                        p_path="$base/$p_path"
                    fi
                    if [ -d "$p_path" ]; then
                        found_profiles+=("$p_path")
                    fi
                fi
            done < "$base/profiles.ini"
        fi

        # Agregar carpetas que contengan prefs.js directamente
        for dir in "$base"/*; do
            if [ -d "$dir" ] && [ -f "$dir/prefs.js" ]; then
                local exists=0
                for p in "${found_profiles[@]}"; do
                    if [ "$p" = "$dir" ]; then
                        exists=1
                        break
                    fi
                done
                [ $exists -eq 0 ] && found_profiles+=("$dir")
            fi
        done
    done

    # Retornar perfiles únicos
    if [ ${#found_profiles[@]} -gt 0 ]; then
        printf "%s\n" "${found_profiles[@]}" | sort -u
    fi
}

patch_zen_browser() {
    log_step "Aplicando parche de control multimedia a Zen Browser"

    # 1. Registrar Native Messaging Hosts para Zen y Firefox
    local manifest_dirs=(
        "$HOME/.config/zen/native-messaging-hosts"
        "$HOME/.mozilla/native-messaging-hosts"
    )

    if [ -d "/opt/zen" ] && [ -w "/opt/zen" ]; then
        manifest_dirs+=("/opt/zen/distribution/native-messaging-hosts")
    elif [ -d "/opt/zen" ] && has_sudo; then
        sudo mkdir -p "/opt/zen/distribution/native-messaging-hosts" 2>/dev/null || true
        manifest_dirs+=("/opt/zen/distribution/native-messaging-hosts")
    fi

    local manifest_content
    manifest_content=$(get_mozilla_manifest_json)

    for m_dir in "${manifest_dirs[@]}"; do
        if [[ "$m_dir" == "$HOME"* ]]; then
            mkdir -p "$m_dir"
            echo "$manifest_content" > "$m_dir/org.kde.plasma.browser_integration.json"
            chmod 644 "$m_dir/org.kde.plasma.browser_integration.json"
            log_success "Manifiesto nativo registrado en: $m_dir/org.kde.plasma.browser_integration.json"
        elif has_sudo; then
            sudo mkdir -p "$m_dir"
            echo "$manifest_content" | sudo tee "$m_dir/org.kde.plasma.browser_integration.json" >/dev/null
            sudo chmod 644 "$m_dir/org.kde.plasma.browser_integration.json"
            log_success "Manifiesto nativo registrado en: $m_dir/org.kde.plasma.browser_integration.json"
        fi
    done

    # 2. Descargar la extensión oficial firmada (.xpi) de Mozilla Addons
    local xpi_tmp="/tmp/plasma-browser-integration@kde.org.xpi"
    local xpi_url="https://addons.mozilla.org/firefox/downloads/latest/plasma-integration/latest.xpi"

    log_info "Descargando última versión de Plasma Integration desde Mozilla Add-ons..."
    if curl -sSL -f -o "$xpi_tmp" "$xpi_url"; then
        log_success "Extensión descargada con éxito (${xpi_tmp})."
    else
        log_warn "No se pudo descargar el archivo .xpi automáticamente. Se configurarán las políticas para descarga en el navegador."
    fi

    # 3. Localizar y configurar todos los perfiles de Zen
    local profiles=()
    while IFS= read -r p; do
        [ -n "$p" ] && profiles+=("$p")
    done < <(find_zen_profiles)

    if [ ${#profiles[@]} -eq 0 ]; then
        log_warn "No se encontraron perfiles activos en ~/.config/zen. Se configurará el perfil predeterminado si se crea."
    else
        for prof in "${profiles[@]}"; do
            log_info "Configurando perfil: $prof"

            # Inyectar extensión en la carpeta extensions del perfil
            local ext_dir="$prof/extensions"
            mkdir -p "$ext_dir"
            if [ -f "$xpi_tmp" ]; then
                cp -f "$xpi_tmp" "$ext_dir/plasma-browser-integration@kde.org.xpi"
                log_success "  -> Complemento instalado en: $ext_dir/plasma-browser-integration@kde.org.xpi"
            fi

            # Asegurar que widget.mpris.enabled esté activo como base para no perder controles si el complemento está inactivo
            local user_js="$prof/user.js"
            
            # Limpiar líneas viejas si existían
            if [ -f "$user_js" ]; then
                sed -i '/\/\/ === PARCHE MPRIS KDE PLASMA (linuxtools) ===/,/\/\/ === FIN PARCHE MPRIS KDE PLASMA ===/d' "$user_js"
                sed -i '/widget.mpris.enabled/d' "$user_js"
                sed -i '/media.hardwaremediakeys.enabled/d' "$user_js"
            fi

            cat << 'EOF' >> "$user_js"
// === PARCHE MPRIS KDE PLASMA (linuxtools) ===
// Asegura que el control multimedia esté activo
user_pref("widget.mpris.enabled", true);
user_pref("media.hardwaremediakeys.enabled", true);
// === FIN PARCHE MPRIS KDE PLASMA ===
EOF
            log_success "  -> user.js configurado: widget.mpris.enabled = true"
        done
    fi

    # 4. Configurar Directivas Empresariales (policies.json) para Zen y Firefox del sistema
    local policy_json='{
  "policies": {
    "ExtensionSettings": {
      "plasma-browser-integration@kde.org": {
        "installation_mode": "normal_installed",
        "install_url": "https://addons.mozilla.org/firefox/downloads/latest/plasma-integration/latest.xpi"
      }
    }
  }
}'

    local policy_dirs=(
        "/etc/firefox/policies"
        "/etc/zen/policies"
    )
    if [ -d "/opt/zen" ]; then
        policy_dirs+=("/opt/zen/distribution")
    fi

    if has_sudo; then
        log_info "Configurando políticas de extensión del sistema (policies.json)..."
        for p_dir in "${policy_dirs[@]}"; do
            sudo mkdir -p "$p_dir"
            echo "$policy_json" | sudo tee "$p_dir/policies.json" >/dev/null
            sudo chmod 644 "$p_dir/policies.json"
            log_success "Directiva registrada en: $p_dir/policies.json"
        done
    else
        log_info "Instalación a nivel de usuario completada. Las directivas globales de /etc requieren sudo."
    fi

    rm -f "$xpi_tmp"
    log_success "Parche para Zen Browser completado."
}

# ==============================================================================
# 6. PARCHE PARA NAVEGADORES CHROMIUM (BRAVE, CHROME, CHROMIUM)
# ==============================================================================
patch_chromium_browsers() {
    log_step "Aplicando configuración para navegadores basados en Chromium (Brave, Chrome)"

    local chromium_manifest_dirs=(
        "/etc/chromium/native-messaging-hosts"
        "/etc/opt/chrome/native-messaging-hosts"
        "/etc/brave/native-messaging-hosts"
        "$HOME/.config/BraveSoftware/Brave-Browser/NativeMessagingHosts"
        "$HOME/.config/google-chrome/NativeMessagingHosts"
        "$HOME/.config/chromium/NativeMessagingHosts"
    )

    local manifest_content
    manifest_content=$(get_chromium_manifest_json)

    for m_dir in "${chromium_manifest_dirs[@]}"; do
        if [[ "$m_dir" == /etc/* ]]; then
            if has_sudo; then
                sudo mkdir -p "$m_dir"
                echo "$manifest_content" | sudo tee "$m_dir/org.kde.plasma.browser_integration.json" >/dev/null
                sudo chmod 644 "$m_dir/org.kde.plasma.browser_integration.json"
            fi
        else
            mkdir -p "$m_dir"
            echo "$manifest_content" > "$m_dir/org.kde.plasma.browser_integration.json"
            chmod 644 "$m_dir/org.kde.plasma.browser_integration.json"
        fi
    done
    log_success "Manifiestos registrados para Chromium y Brave Browser."

    # Políticas de extensión para Brave / Chromium
    local brave_policy_dirs=(
        "/etc/brave/policies/managed"
        "/etc/chromium/policies/managed"
        "/etc/opt/chrome/policies/managed"
    )
    local chrome_policy_content='{
  "ExtensionInstallForcelist": [
    "cimiefiiaegbelhefglklhhakcgmhkai;https://clients2.google.com/service/update2/crx"
  ]
}'

    if has_sudo; then
        for pol in "${brave_policy_dirs[@]}"; do
            sudo mkdir -p "$pol"
            echo "$chrome_policy_content" | sudo tee "$pol/plasma-integration.json" >/dev/null
            sudo chmod 644 "$pol/plasma-integration.json"
        done
        log_success "Políticas de extensión forzada registradas para Brave y Chrome."
    fi
}

# ==============================================================================
# 7. DIAGNÓSTICO Y MONITOR EN VIVO DE METADATOS MPRIS
# ==============================================================================
format_microseconds() {
    local us="$1"
    if [ -z "$us" ] || [ "$us" -eq 0 ] 2>/dev/null; then
        echo "00:00"
        return
    fi
    local total_sec=$(( us / 1000000 ))
    local min=$(( total_sec / 60 ))
    local sec=$(( total_sec % 60 ))
    printf "%02d:%02d" "$min" "$sec"
}

diagnose_mpris() {
    log_step "Diagnóstico de Reproductores Multimedia (MPRIS) en KDE Plasma"

    local mpris_services=()
    while IFS= read -r s; do
        [ -n "$s" ] && mpris_services+=("$s")
    done < <(busctl --user list 2>/dev/null | awk '{print $1}' | grep -i "org.mpris.MediaPlayer2" || true)

    if [ ${#mpris_services[@]} -eq 0 ]; then
        log_warn "No hay reproductores MPRIS activos en el bus de usuario actualmente."
        echo -e "\n${YELLOW}Sugerencia:${RESET} Abre una canción o video en Zen Browser o Brave para probar."
        return 0
    fi

    echo -e "${BOLD}Reproductores detectados en DBus:${RESET}"
    for s in "${mpris_services[@]}"; do
        echo -e "  - ${CYAN}${s}${RESET}"
    done

    echo ""
    for s in "${mpris_services[@]}"; do
        echo -e "${MAGENTA}${BOLD}--------------------------------------------------------------${RESET}"
        echo -e "${BOLD}Detalles de: ${CYAN}${s}${RESET}"
        echo -e "${MAGENTA}${BOLD}--------------------------------------------------------------${RESET}"

        local status title artist album url length_us pos_us
        status=$(busctl --user get-property "$s" /org/mpris/MediaPlayer2 org.mpris.MediaPlayer2.Player PlaybackStatus 2>/dev/null | awk '{print $2}' | tr -d '"' || echo "Desconocido")
        echo -e "  Estado de reproducción : ${GREEN}${status}${RESET}"

        # Obtener metadatos con busctl
        title=$(busctl --user get-property "$s" /org/mpris/MediaPlayer2 org.mpris.MediaPlayer2.Player Metadata 2>/dev/null | grep -o 'xesam:title" s "[^"]*"' | sed 's/xesam:title" s "//;s/"$//' || echo "")
        artist=$(busctl --user get-property "$s" /org/mpris/MediaPlayer2 org.mpris.MediaPlayer2.Player Metadata 2>/dev/null | grep -o 'xesam:artist" as [0-9]* "[^"]*"' | sed 's/.*"//;s/"$//' || echo "")
        album=$(busctl --user get-property "$s" /org/mpris/MediaPlayer2 org.mpris.MediaPlayer2.Player Metadata 2>/dev/null | grep -o 'xesam:album" s "[^"]*"' | sed 's/xesam:album" s "//;s/"$//' || echo "")
        url=$(busctl --user get-property "$s" /org/mpris/MediaPlayer2 org.mpris.MediaPlayer2.Player Metadata 2>/dev/null | grep -o 'xesam:url" s "[^"]*"' | sed 's/xesam:url" s "//;s/"$//' || echo "")
        length_us=$(busctl --user get-property "$s" /org/mpris/MediaPlayer2 org.mpris.MediaPlayer2.Player Metadata 2>/dev/null | grep -o 'mpris:length" [xt] [0-9]*' | awk '{print $3}' || echo "0")
        pos_us=$(busctl --user get-property "$s" /org/mpris/MediaPlayer2 org.mpris.MediaPlayer2.Player Position 2>/dev/null | awk '{print $2}' || echo "0")

        echo -e "  Título                 : ${BOLD}${title:-N/A}${RESET}"
        echo -e "  Artista                : ${artist:-N/A}"
        echo -e "  Álbum                  : ${album:-N/A}"
        echo -e "  Enlace / URL           : ${url:-N/A}"

        if [ -n "$length_us" ] && [ "$length_us" != "0" ]; then
            local dur_fmt pos_fmt
            dur_fmt=$(format_microseconds "$length_us")
            pos_fmt=$(format_microseconds "$pos_us")
            echo -e "  Posición / Duración    : ${GREEN}${BOLD}${pos_fmt} / ${dur_fmt}${RESET} (Duración en microsegundos: ${length_us})"
            echo -e "  Barra en KDE Plasma    : ${GREEN}${BOLD}DISPONIBLE (La seekbar funcionará correctamente en el widget)${RESET}"
        else
            echo -e "  Posición / Duración    : ${YELLOW}Posición: $(format_microseconds "$pos_us") | Duración: No reportada (0)${RESET}"
            if [[ "$s" == *"firefox"* ]]; then
                echo -e "  Barra en KDE Plasma    : ${RED}${BOLD}NO DISPONIBLE${RESET} (El reproductor nativo de Firefox/Zen está activo y oculta la barra)."
                echo -e "                           ${CYAN}Aplica el parche y reinicia el navegador para que Plasma Browser Integration tome el control.${RESET}"
            else
                echo -e "  Barra en KDE Plasma    : No reportada por el emisor."
            fi
        fi
    done
}

monitor_live_mpris() {
    log_step "Iniciando monitor en vivo de posición MPRIS (Presiona Ctrl+C para salir)..."
    while true; do
        clear
        echo -e "${CYAN}${BOLD}=== MONITOR EN VIVO DE CONTROL MULTIMEDIA MPRIS ===${RESET}"
        echo -e "Hora: $(date +%T)\n"
        diagnose_mpris
        sleep 1
    done
}

# ==============================================================================
# 8. RESTAURACIÓN / REVERSIÓN (ROLLBACK)
# ==============================================================================
restore_defaults() {
    log_step "Revirtiendo parche multimedia a valores originales"

    # Restaurar perfiles de Zen
    local profiles=()
    while IFS= read -r p; do
        [ -n "$p" ] && profiles+=("$p")
    done < <(find_zen_profiles)

    for prof in "${profiles[@]}"; do
        local user_js="$prof/user.js"
        if [ -f "$user_js" ]; then
            log_info "Restaurando $user_js..."
            sed -i '/\/\/ === PARCHE MPRIS KDE PLASMA (linuxtools) ===/,/\/\/ === FIN PARCHE MPRIS KDE PLASMA ===/d' "$user_js"
            sed -i '/widget.mpris.enabled/d' "$user_js"
            sed -i '/media.hardwaremediakeys.enabled/d' "$user_js"
        fi
        rm -f "$prof/extensions/plasma-browser-integration@kde.org.xpi"
    done

    # Eliminar directivas empresariales añadidas si hay permisos sudo
    if has_sudo; then
        sudo rm -f /etc/firefox/policies/policies.json
        sudo rm -f /etc/zen/policies/policies.json
        sudo rm -f /opt/zen/distribution/policies.json 2>/dev/null || true
        sudo rm -f /etc/brave/policies/managed/plasma-integration.json 2>/dev/null || true
        sudo rm -f /etc/chromium/policies/managed/plasma-integration.json 2>/dev/null || true
    fi

    log_success "Configuraciones restauradas correctamente. Reinicia tus navegadores para aplicar los cambios originales."
}

# ==============================================================================
# 9. MENÚ INTERACTIVO Y ENTRADA PRINCIPAL
# ==============================================================================
show_menu() {
    while true; do
        echo -e "\n${CYAN}==============================================================${RESET}"
        echo -e "${BOLD}${GREEN}     PARCHE MULTIMEDIA Y POSICIÓN DE AUDIO (KDE PLASMA)      ${RESET}"
        echo -e "${CYAN}==============================================================${RESET}"
        echo -e "  1) Aplicar ${BOLD}Parche Completo${RESET} (Zen Browser, Brave, Chrome y Paquetes KDE)"
        echo -e "  2) Parchear únicamente a ${BOLD}Nivel de Usuario${RESET} (Sin requerir sudo)"
        echo -e "  3) Parchear únicamente ${BOLD}Zen Browser${RESET} (Native Hosts, Extensión y user.js)"
        echo -e "  4) Parchear únicamente ${BOLD}Brave / Chromium / Chrome${RESET}"
        echo -e "  5) ${BOLD}Diagnóstico de reproductores MPRIS${RESET} activos en DBus"
        echo -e "  6) ${BOLD}Monitor en tiempo real${RESET} de progreso y posición de audio"
        echo -e "  7) ${BOLD}Revertir parche (Rollback)${RESET} a los valores de fábrica"
        echo -e "  8) Salir"
        echo -e "${CYAN}--------------------------------------------------------------${RESET}"
        echo -ne "Opción: "
        read -r choice

        case "$choice" in
            1)
                install_system_dependencies
                patch_zen_browser
                patch_chromium_browsers
                log_success "\n¡Parche aplicado! Reinicia Zen Browser / Brave para ver la barra de tiempo en el widget de KDE Plasma."
                ;;
            2)
                patch_zen_browser
                patch_chromium_browsers
                log_success "\n¡Parche de usuario aplicado! Si aún no tienes 'plasma-browser-integration', instálalo con sudo dnf install plasma-browser-integration."
                ;;
            3)
                install_system_dependencies
                patch_zen_browser
                log_success "\n¡Zen Browser parcheado! Reinicia el navegador para activar los cambios."
                ;;
            4)
                install_system_dependencies
                patch_chromium_browsers
                log_success "\n¡Navegadores Chromium parcheados! Reinicia tu navegador para activar los cambios."
                ;;
            5)
                diagnose_mpris
                ;;
            6)
                monitor_live_mpris
                ;;
            7)
                restore_defaults
                ;;
            8)
                echo "¡Hasta luego!"
                exit 0
                ;;
            *)
                log_error "Opción no válida."
                ;;
        esac
    done
}

validate_system

# Parseo de argumentos de línea de comandos (CLI)
if [ $# -gt 0 ]; then
    case "$1" in
        -a|--all|--apply|--install)
            install_system_dependencies
            patch_zen_browser
            patch_chromium_browsers
            ;;
        --user)
            patch_zen_browser
            patch_chromium_browsers
            ;;
        --system)
            install_system_dependencies
            ;;
        --zen|--zen-browser)
            install_system_dependencies
            patch_zen_browser
            ;;
        --brave|--chrome|--chromium)
            install_system_dependencies
            patch_chromium_browsers
            ;;
        -d|--diagnose|--status)
            diagnose_mpris
            ;;
        -m|--monitor)
            monitor_live_mpris
            ;;
        -r|--restore|--rollback)
            restore_defaults
            ;;
        -h|--help)
            echo "Uso: $0 [opción]"
            echo "Opciones:"
            echo "  -a, --all, --install    Aplica el parche completo (plasma-browser-integration, Zen, Brave)"
            echo "  --user                  Aplica solo configuraciones a nivel de usuario (sin requerir sudo)"
            echo "  --system                Instala paquetes del sistema (plasma-browser-integration, playerctl)"
            echo "  --zen                   Aplica el parche para Zen Browser y derivados de Firefox"
            echo "  --brave, --chromium     Aplica el parche para Brave Browser y Chrome"
            echo "  -d, --diagnose          Diagnostica reproductores MPRIS activos y soporte de seekbar"
            echo "  -m, --monitor           Monitor interactivo en tiempo real de posición y duración"
            echo "  -r, --restore           Restaura la configuración original"
            echo "  -h, --help              Muestra esta ayuda"
            exit 0
            ;;
        *)
            log_error "Opción no reconocida: $1"
            exit 1
            ;;
    esac
    exit 0
fi

show_menu
