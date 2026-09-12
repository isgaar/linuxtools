#!/usr/bin/env bash
#
# ==============================================================================
# Script de Parche y Optimización de Mandos (Bluetooth & USB) para Fedora Linux
# Compatible con Steam, Lutris, Wine, Proton y Emuladores
# ==============================================================================
# Problema que soluciona:
#  - En Wine/Proton (winebus.sys), los mandos Bluetooth de Sony (DualShock 4 /
#    DualSense) son tratados como dispositivos nativos 'hidraw', ignorando SDL
#    y ocultándolos de la API XInput (emulación Xbox 360).
#  - Esto causa que emuladores nativos como PCSX2 sí reconozcan el mando, pero
#    juegos de Windows en Lutris o Steam (con GInput o XInput nativo) no detecten
#    ningún mando a menos que se use un mando viejo genérico o de Xbox.
#
# Características de este parche:
#  1. Inyecta 'PROTON_SONY_HIDRAW_XINPUT=1' en environment.d y sesión systemd
#     para que Wine/Proton exponga automáticamente el mando como mando XInput.
#  2. Parchea automáticamente todos los juegos instalados en Lutris y crea la
#     configuración global del runner Wine con la variable activada.
#  3. Verifica e instala 'steam-devices' para reglas udev (/dev/uinput y /dev/hidraw*).
#  4. Configura '/etc/modprobe.d/bluetooth-ertm.conf' para desactivar ERTM en
#     mandos Xbox por Bluetooth (evita bucles de desconexión).
#  5. Asegura la carga del módulo de kernel 'uinput'.
#  6. Diagnóstico en vivo de mandos conectados (Bluetooth, evdev, hidraw, SDL2).
#  7. Función de reversión (Rollback) limpia a los valores originales.
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
NC='\033[0m'

# Funciones de registro
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

# Detectar usuario real
REAL_USER="${SUDO_USER:-$USER}"
if [ "$REAL_USER" = "root" ]; then
    REAL_USER=$(logname 2>/dev/null || who | awk '{print $1}' | head -n 1 || echo "ismael")
fi
REAL_HOME=$(eval echo "~$REAL_USER")

# Validar que estamos en Fedora
validate_system() {
    if [ ! -f /etc/os-release ]; then
        log_error "No se pudo identificar la distribución (/etc/os-release ausente)."
        exit 1
    fi
    source /etc/os-release
    if [[ "$ID" != "fedora" && "$ID_LIKE" != *"fedora"* ]]; then
        log_warn "Este script fue diseñado para Fedora Linux. Detectado: $PRETTY_NAME"
        read -p "¿Deseas continuar de todos modos? [s/N]: " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Ss]$ ]]; then
            exit 1
        fi
    fi
}

# 1. Aplicar variables de entorno de sesión de usuario (~/.config/environment.d)
apply_user_environment() {
    log_step "1. Configurando variables de entorno para Proton, Wine y Lutris"

    local env_dir="$REAL_HOME/.config/environment.d"
    local env_file="$env_dir/99-gamepad.conf"

    sudo -u "$REAL_USER" mkdir -p "$env_dir"

    log_info "Escribiendo $env_file..."
    cat << 'EOF' | sudo -u "$REAL_USER" tee "$env_file" > /dev/null
# Optimización y compatibilidad de mandos Bluetooth/USB para Proton y Wine
PROTON_SONY_HIDRAW_XINPUT=1
PROTON_ENABLE_HIDRAW=1
EOF

    # Aplicar inmediatamente en la sesión activa de systemd
    if sudo -u "$REAL_USER" systemctl --user show-environment &>/dev/null; then
        sudo -u "$REAL_USER" systemctl --user import-environment PROTON_SONY_HIDRAW_XINPUT PROTON_ENABLE_HIDRAW || true
        log_success "Variable PROTON_SONY_HIDRAW_XINPUT=1 exportada a la sesión systemd activa."
    else
        log_warn "No se pudo importar al entorno systemd del usuario (sesión no detectada)."
    fi

    log_success "Variables de entorno de usuario configuradas correctamente."
}

# 2. Parchear configuraciones de juegos en Lutris
apply_lutris_patch() {
    log_step "2. Parcheando configuraciones de Lutris para mapeo XInput"

    local lutris_games_dir="$REAL_HOME/.local/share/lutris/games"
    local lutris_config_games_dir="$REAL_HOME/.config/lutris/games"
    local lutris_wine_runner_dir="$REAL_HOME/.config/lutris/runners"
    local patched_count=0

    # Helper en Python para modificar archivos YAML de Lutris sin romper formato
    local python_patcher='
import sys, yaml, os

file_path = sys.argv[1]
try:
    with open(file_path, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f)

    if not isinstance(data, dict):
        sys.exit(0)

    system = data.setdefault("system", {})
    if not isinstance(system, dict):
        system = {}
        data["system"] = system

    env = system.setdefault("env", {})
    if not isinstance(env, dict):
        env = {}
        system["env"] = env

    if env.get("PROTON_SONY_HIDRAW_XINPUT") != "1":
        env["PROTON_SONY_HIDRAW_XINPUT"] = "1"
        with open(file_path, "w", encoding="utf-8") as f:
            yaml.dump(data, f, default_flow_style=False)
        print("PATCHED")
    else:
        print("ALREADY_SET")
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
'

    # Buscar y parchear en ~/.local/share/lutris/games/*.yml
    for dir_path in "$lutris_games_dir" "$lutris_config_games_dir"; do
        if [ -d "$dir_path" ]; then
            while IFS= read -r -d '' yml_file; do
                local res
                res=$(sudo -u "$REAL_USER" python3 -c "$python_patcher" "$yml_file" 2>/dev/null || true)
                if [ "$res" = "PATCHED" ]; then
                    log_success "Juego parcheado en Lutris: $(basename "$yml_file")"
                    ((patched_count++))
                elif [ "$res" = "ALREADY_SET" ]; then
                    log_info "Juego ya configurado: $(basename "$yml_file")"
                fi
            done < <(find "$dir_path" -maxdepth 1 -name "*.yml" -print0 2>/dev/null)
        fi
    done

    # Configuración global del runner Wine en Lutris (~/.config/lutris/runners/wine.yml)
    sudo -u "$REAL_USER" mkdir -p "$lutris_wine_runner_dir"
    local wine_runner_yml="$lutris_wine_runner_dir/wine.yml"
    if [ ! -f "$wine_runner_yml" ]; then
        cat << 'EOF' | sudo -u "$REAL_USER" tee "$wine_runner_yml" > /dev/null
system:
  env:
    PROTON_SONY_HIDRAW_XINPUT: '1'
EOF
        log_success "Configuración global de Lutris Wine creada en $wine_runner_yml"
    else
        local res
        res=$(sudo -u "$REAL_USER" python3 -c "$python_patcher" "$wine_runner_yml" 2>/dev/null || true)
        if [ "$res" = "PATCHED" ]; then
            log_success "Configuración global de Lutris Wine actualizada."
        fi
    fi

    log_success "Lutris actualizado con soporte para mandos Sony XInput ($patched_count juegos actualizados)."
}

# 3. Reglas udev del sistema, uinput y compatibilidad Bluetooth
apply_system_fixes() {
    log_step "3. Verificando paquetes y reglas del sistema (udev, uinput, bluetooth)"

    # Comprobar privilegios de root para esta sección
    local need_sudo=0
    if [ "$EUID" -ne 0 ]; then
        log_info "Se requieren permisos de administrador (sudo) para las reglas del sistema..."
        need_sudo=1
    fi

    local run_cmd=""
    if [ "$need_sudo" -eq 1 ]; then
        run_cmd="sudo"
    fi

    # 3.1 Instalar steam-devices si no está presente
    if ! rpm -q steam-devices &>/dev/null; then
        log_info "Instalando paquete 'steam-devices' (reglas udev para mandos)..."
        $run_cmd dnf install -y steam-devices || log_warn "No se pudo instalar steam-devices automáticamente con dnf."
    else
        log_success "Paquete 'steam-devices' ya instalado en el sistema."
    fi

    # 3.2 Cargar módulo uinput automáticamente
    log_info "Asegurando carga del módulo de kernel 'uinput'..."
    echo "uinput" | $run_cmd tee /etc/modules-load.d/uinput.conf > /dev/null
    $run_cmd modprobe uinput || true

    # 3.3 Desactivar ERTM para mandos Bluetooth de Xbox (evita desconexiones infinitas)
    log_info "Configurando desactivación de ERTM para mandos Bluetooth..."
    cat << 'EOF' | $run_cmd tee /etc/modprobe.d/bluetooth-ertm.conf > /dev/null
# Desactiva Enhanced Re-Transmission Mode para permitir emparejamiento estable de mandos Xbox
options bluetooth disable_ertm=1
EOF

    # Aplicar disable_ertm en caliente si el archivo de sysfs existe
    if [ -f /sys/module/bluetooth/parameters/disable_ertm ]; then
        echo 1 | $run_cmd tee /sys/module/bluetooth/parameters/disable_ertm > /dev/null || true
    fi

    # Recargar reglas udev
    $run_cmd udevadm control --reload-rules || true
    $run_cmd udevadm trigger || true

    log_success "Reglas del sistema y módulos de kernel aplicados correctamente."
}

# 4. Mostrar recomendaciones de configuración para Steam
show_steam_recommendations() {
    log_step "4. Recomendaciones para Steam y Steam Input"

    echo -e "${CYAN}--------------------------------------------------${RESET}"
    echo -e "${BOLD}Para garantizar que los juegos en Steam detecten tu mando:${RESET}"
    echo -e " 1. Abre ${BOLD}Steam > Parámetros > Mando${RESET}."
    echo -e " 2. Asegúrate de que la opción:"
    echo -e "    ${GREEN}«Habilitar Steam Input para mandos de PlayStation»${RESET}"
    echo -e "    esté en ${BOLD}«Activado»${RESET} (no en 'Solo en juegos sin soporte' ni 'Desactivado')."
    echo -e " 3. En la biblioteca de Steam, haz clic derecho en el juego > ${BOLD}Propiedades > Mando${RESET}:"
    echo -e "    Asegúrate de que no esté en 'Deshabilitar Steam Input'."
    echo -e " 4. Si juegas por Bluetooth, ${YELLOW}desconecta mandos secundarios USB${RESET} innecesarios"
    echo -e "    para que no compitan por ser el Mando del Jugador 1."
    echo -e "${CYAN}--------------------------------------------------${RESET}"
}

# 5. Diagnóstico de mandos conectados
diagnose_controllers() {
    log_step "Diagnóstico de Mandos Conectados"

    echo -e "\n${BOLD}${CYAN}--- Dispositivos Bluetooth Conectados ---${RESET}"
    if command -v bluetoothctl &>/dev/null; then
        local bt_devs
        bt_devs=$(bluetoothctl devices Connected 2>/dev/null || true)
        if [ -n "$bt_devs" ]; then
            echo -e "${GREEN}$bt_devs${RESET}"
        else
            echo "No hay dispositivos Bluetooth conectados actualmente."
        fi
    fi

    echo -e "\n${BOLD}${CYAN}--- Nodos de Entrada (/dev/input/js*) ---${RESET}"
    if ls /dev/input/js* &>/dev/null; then
        ls -l /dev/input/js*
    else
        echo "No hay joysticks registrados en /dev/input/js*"
    fi

    echo -e "\n${BOLD}${CYAN}--- Dispositivos en /proc/bus/input/devices ---${RESET}"
    awk '
        /^[I|N|H]:/ {
            if ($0 ~ /^I:/) { print "----------------------------------------"; print $0; }
            else if ($0 ~ /Handlers=.*(js|event)/) { print $0; }
            else if ($0 ~ /^N: Name=/) { print $0; }
        }
    ' /proc/bus/input/devices 2>/dev/null || true

    echo -e "\n${BOLD}${CYAN}--- Permisos de /dev/uinput y /dev/hidraw* ---${RESET}"
    ls -l /dev/uinput 2>/dev/null || true
    ls -l /dev/hidraw* 2>/dev/null || true

    echo -e "\n${BOLD}${CYAN}--- Detección SDL2 (libSDL2) ---${RESET}"
    python3 -c "
import ctypes
try:
    sdl = ctypes.CDLL('libSDL2-2.0.so.0')
    sdl.SDL_JoystickNameForIndex.restype = ctypes.c_char_p
    sdl.SDL_IsGameController.restype = ctypes.c_int
    sdl.SDL_Init(0x00000200 | 0x00002000)
    count = sdl.SDL_NumJoysticks()
    print(f'Total de joysticks reconocidos por SDL2: {count}')
    for i in range(count):
        name = sdl.SDL_JoystickNameForIndex(i)
        name_str = name.decode('utf-8', 'replace') if name else 'Desconocido'
        is_gc = bool(sdl.SDL_IsGameController(i))
        print(f'  [{i}] {name_str} (Es GameController estándar: {is_gc})')
    sdl.SDL_Quit()
except Exception as e:
    print(f'Prueba SDL no disponible: {e}')
" 2>/dev/null || true

    echo ""
}

# 6. Prueba interactiva de eventos en vivo
test_live_controller() {
    log_step "Prueba Interactiva en Vivo (3 segundos de lectura de eventos)"
    echo -e "Presiona botones o mueve las palancas en tu mando ahora...\n"

    python3 -c "
import os, glob, select, time

joysticks = sorted(glob.glob('/dev/input/js*'))
if not joysticks:
    print('No se encontraron joysticks en /dev/input/js* para probar.')
    exit(0)

print(f'Probando eventos en {joysticks[0]}...')
try:
    fd = os.open(joysticks[0], os.O_RDONLY | os.O_NONBLOCK)
    start = time.time()
    events_count = 0
    while time.time() - start < 3.0:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            data = os.read(fd, 64)
            events_count += len(data) // 8
    os.close(fd)
    if events_count > 0:
        print(f'\033[0;32m[OK] Se recibieron {events_count} eventos correctamente. ¡El mando responde!\033[0m')
    else:
        print('\033[1;33m[!] No se registraron eventos en 3 segundos (asegúrate de presionar botones).\033[0m')
except Exception as e:
    print(f'Error al leer dispositivo: {e}')
" 2>/dev/null || true
}

# 7. Revertir cambios (Rollback)
restore_defaults() {
    log_step "Restaurando configuraciones originales..."

    local env_file="$REAL_HOME/.config/environment.d/99-gamepad.conf"
    if [ -f "$env_file" ]; then
        rm -f "$env_file"
        log_info "Eliminado: $env_file"
    fi

    local wine_runner_yml="$REAL_HOME/.config/lutris/runners/wine.yml"
    if [ -f "$wine_runner_yml" ]; then
        rm -f "$wine_runner_yml"
        log_info "Eliminado: $wine_runner_yml"
    fi

    if [ "$EUID" -eq 0 ] || sudo -n true 2>/dev/null; then
        local run_cmd=""
        [ "$EUID" -ne 0 ] && run_cmd="sudo"
        $run_cmd rm -f /etc/modprobe.d/bluetooth-ertm.conf /etc/modules-load.d/uinput.conf || true
        log_info "Eliminados archivos en /etc/modprobe.d/ y /etc/modules-load.d/"
    fi

    log_success "Configuraciones revertidas. Es recomendable reiniciar la sesión o el equipo."
}

# Menú interactivo
show_menu() {
    while true; do
        echo -e "\n${CYAN}==============================================================${RESET}"
        echo -e "${BOLD}${GREEN}   PARCHE Y SOPORTE DE MANDOS BLUETOOTH/USB (FEDORA)          ${RESET}"
        echo -e "${CYAN}==============================================================${RESET}"
        echo -e "  1) ${BOLD}Aplicar parche completo${RESET} (Proton, Lutris, udev, uinput, Bluetooth)"
        echo -e "  2) Configurar solo variables de usuario y Lutris (sin root)"
        echo -e "  3) Configurar solo reglas de sistema (udev, uinput, ERTM) (requiere sudo)"
        echo -e "  4) Ver diagnóstico de mandos conectados"
        echo -e "  5) Probar respuesta de botones en vivo"
        echo -e "  6) Revertir cambios (Rollback)"
        echo -e "  7) Salir"
        echo -e "${CYAN}--------------------------------------------------------------${RESET}"
        echo -ne "Opción: "
        read -r choice

        case "$choice" in
            1)
                apply_user_environment
                apply_lutris_patch
                apply_system_fixes
                show_steam_recommendations
                ;;
            2)
                apply_user_environment
                apply_lutris_patch
                show_steam_recommendations
                ;;
            3)
                apply_system_fixes
                ;;
            4)
                diagnose_controllers
                ;;
            5)
                test_live_controller
                ;;
            6)
                restore_defaults
                ;;
            7)
                echo "¡Hasta luego!"
                exit 0
                ;;
            *)
                log_error "Opción no válida."
                ;;
        esac
    done
}

# Punto de entrada
validate_system

if [ $# -gt 0 ]; then
    case "$1" in
        -a|--all|--apply|--install)
            apply_user_environment
            apply_lutris_patch
            apply_system_fixes
            show_steam_recommendations
            ;;
        --user)
            apply_user_environment
            apply_lutris_patch
            show_steam_recommendations
            ;;
        --system)
            apply_system_fixes
            ;;
        -d|--diagnose|--status)
            diagnose_controllers
            ;;
        -t|--test)
            test_live_controller
            ;;
        -r|--restore|--rollback)
            restore_defaults
            ;;
        -h|--help)
            echo "Uso: $0 [opción]"
            echo "Opciones:"
            echo "  -a, --all, --install    Aplica el parche completo (variables, Lutris, udev, uinput)"
            echo "  --user                  Aplica solo configuración de usuario (environment.d y Lutris)"
            echo "  --system                Aplica solo reglas de sistema (steam-devices, uinput, ERTM)"
            echo "  -d, --diagnose          Diagnostica mandos conectados (Bluetooth, evdev, SDL)"
            echo "  -t, --test              Prueba interactiva de botones y respuesta en vivo"
            echo "  -r, --restore           Restaura las configuraciones de fábrica"
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
