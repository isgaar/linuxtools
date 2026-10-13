#!/usr/bin/env bash
# ==============================================================================
# Script de Desinstalación de Bloatware para Fedora Linux
# ==============================================================================
# Compatible con Fedora 39/40/41/42/43/44+ (GNOME / KDE / etc.)
#
# Permite eliminar de forma limpia, modular y segura:
#  1. LibreOffice Suite completa (Writer, Calc, Impress, filtros, unoconv, etc.)
#  2. Firefox y sus paquetes de idiomas preinstalados
#  3. Aplicaciones accesorias de GNOME (gnome-tour, gnome-maps, gnome-weather,
#     gnome-contacts, mediawriter)
#
# Características de seguridad:
#  - Uso de '--no-autoremove' para no eliminar por error dependencias de sistema
#    críticas (como openssl o bibliotecas compartidas).
#  - Detección previa mediante RPM para operar solo sobre paquetes existentes.
#  - Limpieza de base de datos de escritorio (update-desktop-database).
#  - Detección de navegadores alternativos (Zen Browser, Chrome, Brave).
# ==============================================================================

set -eo pipefail

# Colores y estilos de terminal
BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
RESET='\033[0m'
NC='\033[0m'

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

# 1. Comprobar compatibilidad con Fedora
check_fedora() {
    if [ ! -f /etc/os-release ]; then
        log_error "No se pudo identificar la distribución (/etc/os-release no existe)."
        exit 1
    fi

    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" != "fedora" && "${ID_LIKE:-}" != *"fedora"* ]]; then
        log_error "Este script está optimizado para Fedora. Tu sistema es: ${NAME:-desconocido}."
        exit 1
    fi
}

# 2. Detección de paquetes
get_installed_libreoffice_pkgs() {
    rpm -qa --qf "%{NAME}\n" 2>/dev/null | grep -E '^(libreoffice|unoconv)' | sort || true
}

get_installed_firefox_pkgs() {
    rpm -qa --qf "%{NAME}\n" 2>/dev/null | grep -E '^firefox' | sort || true
}

get_installed_gnome_bloat_pkgs() {
    rpm -qa --qf "%{NAME}\n" 2>/dev/null | grep -E '^(gnome-tour|gnome-maps|gnome-weather|gnome-contacts|mediawriter)$' | sort || true
}

# 3. Mostrar estado detallado de bloatware
show_status() {
    check_fedora
    log_step "Diagnóstico de Bloatware preinstalado en el sistema"

    local lo_pkgs fx_pkgs gnome_pkgs
    lo_pkgs=($(get_installed_libreoffice_pkgs))
    fx_pkgs=($(get_installed_firefox_pkgs))
    gnome_pkgs=($(get_installed_gnome_bloat_pkgs))

    echo -e "\n${BOLD}1. Suite LibreOffice:${NC}"
    if [ ${#lo_pkgs[@]} -gt 0 ]; then
        echo -e "   Estado: ${RED}${BOLD}[INSTALADA]${NC} (${#lo_pkgs[@]} paquetes detectados)"
        for pkg in "${lo_pkgs[@]}"; do
            echo -e "     - $pkg"
        done
    else
        echo -e "   Estado: ${GREEN}${BOLD}[NO INSTALADA / ELIMINADA]${NC}"
    fi

    echo -e "\n${BOLD}2. Mozilla Firefox:${NC}"
    if [ ${#fx_pkgs[@]} -gt 0 ]; then
        echo -e "   Estado: ${RED}${BOLD}[INSTALADO]${NC} (${#fx_pkgs[@]} paquetes detectados)"
        for pkg in "${fx_pkgs[@]}"; do
            echo -e "     - $pkg"
        done
    else
        echo -e "   Estado: ${GREEN}${BOLD}[NO INSTALADO / ELIMINADO]${NC}"
    fi

    echo -e "\n${BOLD}3. Utilidades accesorias de GNOME:${NC}"
    if [ ${#gnome_pkgs[@]} -gt 0 ]; then
        echo -e "   Estado: ${RED}${BOLD}[INSTALADAS]${NC} (${#gnome_pkgs[@]} paquetes detectados)"
        for pkg in "${gnome_pkgs[@]}"; do
            echo -e "     - $pkg"
        done
    else
        echo -e "   Estado: ${GREEN}${BOLD}[NO INSTALADAS / ELIMINADAS]${NC}"
    fi

    echo -e "\n${BOLD}4. Navegadores alternativos disponibles:${NC}"
    local has_alt_browser=false
    if command -v zen-browser &>/dev/null || [ -x "/opt/zen/zen" ]; then
        echo -e "   - ${GREEN}Zen Browser detectado${NC} (en $(command -v zen-browser 2>/dev/null || echo '/opt/zen/zen'))"
        has_alt_browser=true
    fi
    if command -v google-chrome &>/dev/null || command -v google-chrome-stable &>/dev/null; then
        echo -e "   - ${GREEN}Google Chrome detectado${NC}"
        has_alt_browser=true
    fi
    if command -v brave-browser &>/dev/null; then
        echo -e "   - ${GREEN}Brave Browser detectado${NC}"
        has_alt_browser=true
    fi
    if command -v chromium &>/dev/null; then
        echo -e "   - ${GREEN}Chromium detectado${NC}"
        has_alt_browser=true
    fi
    if [ "$has_alt_browser" = false ]; then
        echo -e "   - ${YELLOW}No se detectaron navegadores alternativos en rutas comunes.${NC}"
    fi
    echo ""
}

# 4. Función de eliminación mediante DNF
execute_dnf_removal() {
    local category_name="$1"
    local assume_yes="$2"
    shift 2
    local pkgs=("$@")

    if [ ${#pkgs[@]} -eq 0 ]; then
        log_info "No hay paquetes de $category_name instalados. Nada que desinstalar."
        return 0
    fi

    log_step "Desinstalando $category_name (${#pkgs[@]} paquetes)..."
    echo "Paquetes a desinstalar:"
    for p in "${pkgs[@]}"; do
        echo "  - $p"
    done

    if [ "$assume_yes" != true ]; then
        echo -ne "\n¿Confirmas la desinstalación? [s/N]: "
        local resp=""
        read -r resp || resp=""
        if [[ ! "$resp" =~ ^[sSyY]$ ]]; then
            log_warn "Operación cancelada por el usuario."
            return 0
        fi
    fi

    log_info "Ejecutando desinstalación con sudo dnf..."
    if sudo dnf remove -y --no-autoremove "${pkgs[@]}"; then
        log_success "$category_name desinstalado correctamente."
    else
        log_error "Hubo un fallo al intentar desinstalar algunos paquetes de $category_name."
        return 1
    fi

    # Actualizar base de datos de lanzadores de escritorio
    if command -v update-desktop-database &>/dev/null; then
        update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
        sudo update-desktop-database "/usr/share/applications" 2>/dev/null || true
    fi
}

# 5. Desinstalar LibreOffice
remove_libreoffice() {
    local assume_yes="${1:-false}"
    local pkgs=($(get_installed_libreoffice_pkgs))
    execute_dnf_removal "LibreOffice Suite" "$assume_yes" "${pkgs[@]}"
}

# 6. Desinstalar Firefox
remove_firefox() {
    local assume_yes="${1:-false}"
    local pkgs=($(get_installed_firefox_pkgs))
    execute_dnf_removal "Mozilla Firefox" "$assume_yes" "${pkgs[@]}"

    if command -v zen-browser &>/dev/null || [ -x "/opt/zen/zen" ]; then
        log_success "Zen Browser permanece activo y disponible como tu navegador web principal."
    fi
}

# 7. Desinstalar utilidades de GNOME
remove_gnome_apps() {
    local assume_yes="${1:-false}"
    local pkgs=($(get_installed_gnome_bloat_pkgs))
    execute_dnf_removal "Utilidades Accesorias de GNOME" "$assume_yes" "${pkgs[@]}"
}

# 8. Desinstalar LibreOffice + Firefox juntos
remove_core_bloat() {
    local assume_yes="${1:-false}"
    local pkgs=($(get_installed_libreoffice_pkgs) $(get_installed_firefox_pkgs))
    execute_dnf_removal "LibreOffice y Firefox" "$assume_yes" "${pkgs[@]}"

    if command -v zen-browser &>/dev/null || [ -x "/opt/zen/zen" ]; then
        log_success "Zen Browser permanece activo y disponible como tu navegador web principal."
    fi
}

# 9. Desinstalar TODO el bloatware
remove_all_bloat() {
    local assume_yes="${1:-false}"
    local pkgs=($(get_installed_libreoffice_pkgs) $(get_installed_firefox_pkgs) $(get_installed_gnome_bloat_pkgs))
    execute_dnf_removal "Todo el Bloatware (LibreOffice + Firefox + GNOME apps)" "$assume_yes" "${pkgs[@]}"

    if command -v zen-browser &>/dev/null || [ -x "/opt/zen/zen" ]; then
        log_success "Zen Browser permanece activo y disponible como tu navegador web principal."
    fi
}

# Menú interactivo
show_bloatware_menu() {
    check_fedora
    while true; do
        local lo_count fx_count gnome_count
        lo_count=$(get_installed_libreoffice_pkgs | wc -w)
        fx_count=$(get_installed_firefox_pkgs | wc -w)
        gnome_count=$(get_installed_gnome_bloat_pkgs | wc -w)

        local lo_status fx_status gnome_status
        [ "$lo_count" -gt 0 ] && lo_status="${RED}[$lo_count pkgs]${NC}" || lo_status="${GREEN}[Limpio]${NC}"
        [ "$fx_count" -gt 0 ] && fx_status="${RED}[$fx_count pkgs]${NC}" || fx_status="${GREEN}[Limpio]${NC}"
        [ "$gnome_count" -gt 0 ] && gnome_status="${RED}[$gnome_count pkgs]${NC}" || gnome_status="${GREEN}[Limpio]${NC}"

        echo -e "\n${CYAN}==================================================${NC}"
        echo -e "${BOLD}${GREEN}        ELIMINADOR DE BLOATWARE EN FEDORA         ${NC}"
        echo -e "${CYAN}==================================================${NC}"
        echo -e "Estado actual de componentes:"
        echo -e "  - LibreOffice:           $lo_status"
        echo -e "  - Mozilla Firefox:       $fx_status"
        echo -e "  - Apps GNOME accesoria:  $gnome_status"
        echo -e "${CYAN}--------------------------------------------------${NC}"
        echo -e "  1) Desinstalar ${BOLD}LibreOffice Suite${NC} (Writer, Calc, Impress, filtros)"
        echo -e "  2) Desinstalar ${BOLD}Mozilla Firefox${NC} (y paquetes de idiomas)"
        echo -e "  3) Desinstalar ${BOLD}LibreOffice y Firefox${NC} (Recomendado)"
        echo -e "  4) Desinstalar ${BOLD}Apps accesorias GNOME${NC} (Tour, Mapas, El tiempo, Contactos, Media Writer)"
        echo -e "  5) Desinstalar ${BOLD}TODO el bloatware detectado${NC}"
        echo -e "  6) Ver diagnóstico y lista detallada de paquetes"
        echo -e "  7) Volver al menú anterior"
        echo -e "${CYAN}--------------------------------------------------${NC}"
        echo -ne "Selecciona una opción: "

        local choice=""
        read -r choice || choice=""

        case "$choice" in
            1)
                remove_libreoffice false || true
                ;;
            2)
                remove_firefox false || true
                ;;
            3)
                remove_core_bloat false || true
                ;;
            4)
                remove_gnome_apps false || true
                ;;
            5)
                remove_all_bloat false || true
                ;;
            6)
                show_status
                ;;
            7)
                return 0
                ;;
            *)
                log_error "Opción inválida. Intenta de nuevo."
                ;;
        esac
    done
}

show_help() {
    echo "Uso: $0 [opción]"
    echo "Elimina bloatware preinstalado en Fedora de forma segura y modular."
    echo ""
    echo "Opciones:"
    echo "  -c, --check, --status    Muestra el diagnóstico y paquetes detectados sin modificar el sistema"
    echo "  --libreoffice            Desinstala la suite LibreOffice completa"
    echo "  --firefox                Desinstala Mozilla Firefox y sus paquetes de idiomas"
    echo "  --core                   Desinstala LibreOffice y Firefox"
    echo "  --gnome-apps             Desinstala utilidades accesorias de GNOME"
    echo "  --all                    Desinstala todo el bloatware detectado"
    echo "  -y, --yes                Asume 'sí' a todas las confirmaciones interactivas"
    echo "  -h, --help               Muestra esta ayuda"
}

# Procesamiento de argumentos CLI
ASSUME_YES=false
ACTION=""

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes)
            ASSUME_YES=true
            ;;
        -c|--check|--status)
            ACTION="status"
            ;;
        --libreoffice)
            ACTION="libreoffice"
            ;;
        --firefox)
            ACTION="firefox"
            ;;
        --core)
            ACTION="core"
            ;;
        --gnome-apps)
            ACTION="gnome"
            ;;
        --all)
            ACTION="all"
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            log_error "Opción no reconocida: $1"
            show_help
            exit 1
            ;;
    esac
    shift
done

case "$ACTION" in
    status)
        show_status
        exit 0
        ;;
    libreoffice)
        check_fedora
        remove_libreoffice "$ASSUME_YES"
        exit 0
        ;;
    firefox)
        check_fedora
        remove_firefox "$ASSUME_YES"
        exit 0
        ;;
    core)
        check_fedora
        remove_core_bloat "$ASSUME_YES"
        exit 0
        ;;
    gnome)
        check_fedora
        remove_gnome_apps "$ASSUME_YES"
        exit 0
        ;;
    all)
        check_fedora
        remove_all_bloat "$ASSUME_YES"
        exit 0
        ;;
    "")
        show_bloatware_menu
        exit 0
        ;;
esac
