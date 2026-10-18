#!/usr/bin/env bash
# ==============================================================================
# Script de Parche y Optimización de Mandos (Bluetooth & USB) para Fedora Linux
# Compatible con Steam, Lutris, Wine, Proton y Emuladores
# ==============================================================================
# Problema que soluciona:
#  - Steam Input puede crear un «Steam Virtual Gamepad». Si un juego externo se
#    inicia desde Lutris mientras Steam está abierto, algunos juegos XInput
#    (por ejemplo GTA SA con GInput) eligen ese dispositivo sin eventos en vez
#    del mando físico.
#  - Forzar HIDRAW/XInput de Sony globalmente no soluciona ese conflicto y
#    afecta innecesariamente a Steam y a todos los juegos de Lutris.
#
# Características de este parche:
#  1. Migra y elimina las variables globales heredadas de HIDRAW/XInput.
#  2. Permite configurar de forma explícita cada juego externo de Lutris con
#     PROTON_PREFER_SDL=1. Proton entonces usa SDL, desactiva Steam Input solo
#     para ese proceso y no toma el mando virtual de Steam.
#  3. Verifica e instala 'steam-devices' para reglas udev (/dev/uinput y /dev/hidraw*).
#  4. Configura ERTM únicamente si hay un mando Xbox Bluetooth conectado
#     (evita bucles de desconexión sin alterar DualSense/DualShock).
#  5. Asegura la carga del módulo de kernel 'uinput'.
#  6. Diagnóstico en vivo de mandos conectados (Bluetooth, evdev, hidraw, SDL2).
#  7. Función de reversión (Rollback) que restaura únicamente los juegos que
#     este script haya modificado.
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
NC='\033[0m'

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
# 2. DETECCIÓN DE USUARIO Y VALIDACIÓN DE ENTORNO
# ==============================================================================
REAL_USER="${SUDO_USER:-$USER}"
if [ "$REAL_USER" = "root" ]; then
    REAL_USER=$(logname 2>/dev/null || who | awk '{print $1}' | head -n 1 || echo "ismael")
fi
REAL_HOME=$(eval echo "~$REAL_USER")

# Ejecuta una orden como el usuario de sesión sin pedir sudo cuando el script ya
# se ejecuta como ese mismo usuario.
as_real_user() {
    if [ "$EUID" -eq 0 ] && [ "$REAL_USER" != "root" ]; then
        sudo -u "$REAL_USER" "$@"
    else
        "$@"
    fi
}

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

# ==============================================================================
# 3. PARCHES A NIVEL DE USUARIO (SESIÓN Y PROTON/WINE)
# ==============================================================================
# 3.1 Migración de variables globales heredadas
# Steam y Proton ya eligen el backend de entrada apropiado por título. No se
# debe forzar HIDRAW ni XInput de Sony globalmente: el ajuste SDL se aplica solo
# al juego externo de Lutris que lo necesita.
remove_legacy_environment() {
    local env_file="$REAL_HOME/.config/environment.d/99-gamepad.conf"

    if [ -f "$env_file" ]; then
        python3 - "$env_file" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
legacy = ("PROTON_SONY_HIDRAW_XINPUT=", "PROTON_ENABLE_HIDRAW=")
lines = path.read_text(encoding="utf-8").splitlines()
kept = [line for line in lines if not line.startswith(legacy)]

# No dejamos un archivo vacío creado exclusivamente por la versión anterior.
if any(line.strip() and not line.lstrip().startswith("#") for line in kept):
    path.write_text("\n".join(kept) + "\n", encoding="utf-8")
else:
    path.unlink()
PY
        log_info "Variables globales heredadas eliminadas de $env_file"
    fi

    # environment.d se aplica al iniciar sesión. Esta llamada retira también
    # los valores de una sesión systemd que hubiera sido modificada antes.
    if as_real_user systemctl --user show-environment &>/dev/null; then
        as_real_user systemctl --user unset-environment \
            PROTON_SONY_HIDRAW_XINPUT PROTON_ENABLE_HIDRAW || true
        log_info "Los procesos de la sesión ya abiertos conservarán sus variables hasta reiniciar sesión."
    fi
}

apply_user_environment() {
    log_step "1. Limpiando variables globales de entrada heredadas"
    remove_legacy_environment
    log_success "Steam y Proton usarán su configuración normal por título."
}

# 3.2 Configuración selectiva para juegos externos de Lutris
# Uso: apply_lutris_patch [texto-del-slug-o-nombre]
apply_lutris_patch() {
    local selector="${1:-}"
    log_step "2. Configurando entrada de Lutris"

    local lutris_games_dir="$REAL_HOME/.local/share/lutris/games"
    local lutris_config_games_dir="$REAL_HOME/.config/lutris/games"
    local state_dir="$REAL_HOME/.config/linuxtools"
    local state_file="$state_dir/gamepad-lutris-state.json"

    as_real_user mkdir -p "$state_dir"
    as_real_user python3 - "$selector" "$state_file" "$lutris_games_dir" "$lutris_config_games_dir" <<'PY'
from pathlib import Path
import json
import sys
import yaml

selector, state_name, *directories = sys.argv[1:]
selector = selector.casefold().strip()
state_path = Path(state_name)
try:
    state = json.loads(state_path.read_text(encoding="utf-8"))
except (FileNotFoundError, json.JSONDecodeError):
    state = {"lutris_games": {}}
entries = state.setdefault("lutris_games", {})

def environment_mappings(data):
    """Yield active and installer system.env mappings without touching others."""
    if not isinstance(data, dict):
        return
    system = data.get("system")
    if isinstance(system, dict) and isinstance(system.get("env"), dict):
        yield system["env"]
    script = data.get("script")
    if isinstance(script, dict):
        installer_system = script.get("system")
        if isinstance(installer_system, dict) and isinstance(installer_system.get("env"), dict):
            yield installer_system["env"]

cleaned = configured = 0
for directory in map(Path, directories):
    if not directory.is_dir():
        continue
    for path in directory.glob("*.yml"):
        try:
            data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        except yaml.YAMLError as error:
            print(f"AVISO: no se pudo leer {path.name}: {error}")
            continue
        if not isinstance(data, dict):
            continue
        changed = False
        for candidate in environment_mappings(data):
            for key in ("PROTON_SONY_HIDRAW_XINPUT", "PROTON_ENABLE_HIDRAW"):
                if key in candidate:
                    del candidate[key]
                    cleaned += 1
                    changed = True
        identifiers = " ".join(str(data.get(key, "")) for key in ("name", "slug", "game_slug"))
        if selector and (selector in identifiers.casefold() or selector in path.stem.casefold()):
            system = data.setdefault("system", {})
            if not isinstance(system, dict):
                system = data["system"] = {}
            env = system.setdefault("env", {})
            if not isinstance(env, dict):
                env = system["env"] = {}
            path_key = str(path)
            if path_key not in entries:
                entries[path_key] = {
                    "had_value": "PROTON_PREFER_SDL" in env,
                    "value": env.get("PROTON_PREFER_SDL"),
                }
            if str(env.get("PROTON_PREFER_SDL", "")) != "1":
                env["PROTON_PREFER_SDL"] = "1"
                configured += 1
                changed = True
        if changed:
            path.write_text(yaml.safe_dump(data, allow_unicode=True, sort_keys=False), encoding="utf-8")

if selector:
    state_path.write_text(json.dumps(state, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
print(f"CLEANED={cleaned}")
print(f"CONFIGURED={configured}")
PY

    # La versión anterior también podía haber creado este archivo global. Solo
    # eliminamos nuestras claves y preservamos cualquier otro ajuste del usuario.
    local wine_runner_yml="$REAL_HOME/.config/lutris/runners/wine.yml"
    if [ -f "$wine_runner_yml" ]; then
        as_real_user python3 - "$wine_runner_yml" <<'PY'
from pathlib import Path
import sys
import yaml

path = Path(sys.argv[1])
data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
env = data.get("system", {}).get("env", {}) if isinstance(data, dict) else {}
changed = False
if isinstance(env, dict):
    for key in ("PROTON_SONY_HIDRAW_XINPUT", "PROTON_ENABLE_HIDRAW"):
        if key in env:
            del env[key]
            changed = True
if changed:
    path.write_text(yaml.safe_dump(data, allow_unicode=True, sort_keys=False), encoding="utf-8")
PY
    fi

    if [ -n "$selector" ]; then
        log_success "Lutris configurado para '$selector' con SDL físico, sin Steam Input en ese juego."
    else
        log_info "Migración completada. No se modificó ningún juego de Lutris de forma global."
        log_info "Para un juego externo: $0 --lutris-sdl <slug-o-nombre>"
    fi
}

# ==============================================================================
# 4. PARCHES A NIVEL DE SISTEMA Y KERNEL (REQUIERE PRIVILEGIOS DE ROOT)
# ==============================================================================
apply_system_fixes() {
    log_step "3. Verificando paquetes y reglas del sistema (udev, uinput, bluetooth)"

    local need_sudo=0
    if [ "$EUID" -ne 0 ]; then
        log_info "Se requieren permisos de administrador (sudo) para las reglas del sistema..."
        need_sudo=1
    fi

    local run_cmd=""
    if [ "$need_sudo" -eq 1 ]; then
        run_cmd="sudo"
    fi

    # 4.1 Instalar steam-devices si no está presente (reglas udev para mandos)
    if ! rpm -q steam-devices &>/dev/null; then
        log_info "Instalando paquete 'steam-devices' (reglas udev para mandos)..."
        $run_cmd dnf install -y steam-devices || log_warn "No se pudo instalar steam-devices automáticamente con dnf."
    else
        log_success "Paquete 'steam-devices' ya instalado en el sistema."
    fi

    # 4.2 Cargar módulo uinput automáticamente. No sobrescribimos una política
    # existente de módulos; solo creamos un archivo que podamos identificar.
    log_info "Asegurando carga del módulo de kernel 'uinput'..."
    if [ ! -e /etc/modules-load.d/uinput.conf ]; then
        cat << 'EOF' | $run_cmd tee /etc/modules-load.d/linuxtools-gamepad-uinput.conf > /dev/null
# Managed by linuxtools gamepad patch
uinput
EOF
    fi
    $run_cmd modprobe uinput || true

    # 4.3 ERTM solo se desactiva para un mando Xbox detectado. DualSense y
    # DualShock no lo necesitan y un cambio global de Bluetooth no es inocuo.
    if bluetoothctl devices Connected 2>/dev/null | grep -qi 'xbox\|microsoft'; then
        log_info "Mando Xbox Bluetooth detectado; configurando ERTM desactivado..."
        if [ ! -e /etc/modprobe.d/linuxtools-gamepad-bluetooth-ertm.conf ]; then
            cat << 'EOF' | $run_cmd tee /etc/modprobe.d/linuxtools-gamepad-bluetooth-ertm.conf > /dev/null
# Managed by linuxtools gamepad patch; improves some Xbox Bluetooth controllers.
options bluetooth disable_ertm=1
EOF
        fi
        if [ -f /sys/module/bluetooth/parameters/disable_ertm ]; then
            echo 1 | $run_cmd tee /sys/module/bluetooth/parameters/disable_ertm > /dev/null || true
        fi
    else
        log_info "No hay mando Xbox Bluetooth conectado; se conserva ERTM sin cambios."
    fi

    # 4.4 Recargar reglas udev
    $run_cmd udevadm control --reload-rules || true
    $run_cmd udevadm trigger || true

    log_success "Reglas del sistema y módulos de kernel aplicados correctamente."
}

# ==============================================================================
# 5. RECOMENDACIONES DE CONFIGURACIÓN PARA STEAM
# ==============================================================================
show_steam_recommendations() {
    log_step "4. Recomendaciones para Steam y Steam Input"

    echo -e "${CYAN}--------------------------------------------------${RESET}"
    echo -e "${BOLD}Para garantizar que los juegos en Steam detecten tu mando:${RESET}"
    echo -e " 1. Abre ${BOLD}Steam > Parámetros > Mando${RESET}."
    echo -e " 2. Asegúrate de que la opción:"
    echo -e "    ${GREEN}«Habilitar Steam Input para mandos de PlayStation»${RESET}"
    echo -e "    esté en ${BOLD}«Activado»${RESET} (no en 'Solo en juegos sin soporte' ni 'Desactivado')."
    echo -e " 3. En la biblioteca de Steam, configura Steam Input ${BOLD}por juego${RESET}."
    echo -e " 4. Para un juego iniciado por Lutris mientras Steam está abierto, usa:"
    echo -e "    ${GREEN}$0 --lutris-sdl <slug-o-nombre>${RESET}"
    echo -e "    Esto no cambia Steam: solo aísla ese proceso externo del mando virtual."
    echo -e " 5. Si un juego antiguo solo admite un mando, desconecta mandos secundarios"
    echo -e "    para que no compitan por ser el Mando del Jugador 1."
    echo -e "${CYAN}--------------------------------------------------${RESET}"
}

# ==============================================================================
# 6. HERRAMIENTAS DE DIAGNÓSTICO Y MONITOR EN VIVO
# ==============================================================================
# 6.1 Diagnóstico de dispositivos conectados
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

# 6.2 Prueba interactiva de eventos en vivo
test_live_controller() {
    log_step "Prueba Interactiva en Vivo (3 segundos de lectura de eventos)"
    echo -e "Presiona botones o mueve las palancas en tu mando ahora...\n"

    python3 -c "
import os, glob, select, time

joysticks = sorted(glob.glob('/dev/input/js*'))
if not joysticks:
    print('No se encontraron joysticks en /dev/input/js* para probar.')
    exit(0)

fds = {}
try:
    for joystick in joysticks:
        fds[os.open(joystick, os.O_RDONLY | os.O_NONBLOCK)] = joystick
    print('Probando eventos en: ' + ', '.join(fds.values()))
    start = time.time()
    events = {path: 0 for path in fds.values()}
    while time.time() - start < 3.0:
        ready, _, _ = select.select(list(fds), [], [], 0.1)
        for fd in ready:
            events[fds[fd]] += len(os.read(fd, 64)) // 8
    for path, count in events.items():
        status = '\033[0;32m[OK]\033[0m' if count else '\033[1;33m[!]\033[0m'
        print(f'{status} {path}: {count} eventos')
finally:
    for fd in fds:
        os.close(fd)
" 2>/dev/null || true
}

# ==============================================================================
# 7. FUNCIÓN DE REVERSIÓN LIMPIA (ROLLBACK)
# ==============================================================================
restore_defaults() {
    log_step "Restaurando configuraciones originales..."

    remove_legacy_environment

    local state_file="$REAL_HOME/.config/linuxtools/gamepad-lutris-state.json"
    if [ -f "$state_file" ]; then
        as_real_user python3 - "$state_file" <<'PY'
from pathlib import Path
import json
import sys
import yaml

state_path = Path(sys.argv[1])
state = json.loads(state_path.read_text(encoding="utf-8"))
for filename, previous in state.get("lutris_games", {}).items():
    path = Path(filename)
    if not path.is_file():
        continue
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    env = data.setdefault("system", {}).setdefault("env", {})
    if previous.get("had_value"):
        env["PROTON_PREFER_SDL"] = previous.get("value")
    else:
        env.pop("PROTON_PREFER_SDL", None)
    path.write_text(yaml.safe_dump(data, allow_unicode=True, sort_keys=False), encoding="utf-8")
state_path.unlink()
PY
        log_info "Restaurados los perfiles de Lutris modificados por este script."
    fi

    if [ "$EUID" -eq 0 ] || sudo -n true 2>/dev/null; then
        local run_cmd=""
        [ "$EUID" -ne 0 ] && run_cmd="sudo"
        $run_cmd rm -f /etc/modprobe.d/linuxtools-gamepad-bluetooth-ertm.conf \
            /etc/modules-load.d/linuxtools-gamepad-uinput.conf || true
        log_info "Eliminados únicamente los archivos de sistema gestionados por linuxtools."
    fi

    log_success "Configuraciones revertidas. Es recomendable reiniciar la sesión o el equipo."
}

# ==============================================================================
# 8. MENÚ INTERACTIVO Y ENTRADA PRINCIPAL
# ==============================================================================
show_menu() {
    while true; do
        echo -e "\n${CYAN}==============================================================${RESET}"
        echo -e "${BOLD}${GREEN}   PARCHE Y SOPORTE DE MANDOS BLUETOOTH/USB (FEDORA)          ${RESET}"
        echo -e "${CYAN}==============================================================${RESET}"
        echo -e "  1) ${BOLD}Aplicar parche completo${RESET} (Proton, Lutris, udev, uinput, Bluetooth)"
        echo -e "  2) Configurar solo variables de usuario y Lutris (sin root)"
        echo -e "  3) Configurar un juego externo de Lutris (sin Steam Input)"
        echo -e "  4) Configurar solo reglas de sistema (udev, uinput, ERTM) (requiere sudo)"
        echo -e "  5) Ver diagnóstico de mandos conectados"
        echo -e "  6) Probar respuesta de botones en vivo"
        echo -e "  7) Revertir cambios (Rollback)"
        echo -e "  8) Salir"
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
                echo -ne "Slug o parte del nombre del juego de Lutris: "
                read -r selector
                if [ -n "$selector" ]; then
                    apply_user_environment
                    apply_lutris_patch "$selector"
                else
                    log_error "Debes indicar un slug o nombre."
                fi
                ;;
            4)
                apply_system_fixes
                ;;
            5)
                diagnose_controllers
                ;;
            6)
                test_live_controller
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

# Validar sistema operativo
validate_system

# Parseo de argumentos de línea de comandos (CLI)
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
        --lutris-sdl)
            if [ -z "${2:-}" ]; then
                log_error "Uso: $0 --lutris-sdl <slug-o-nombre>"
                exit 1
            fi
            apply_user_environment
            apply_lutris_patch "$2"
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
            echo "  -a, --all, --install    Migra variables antiguas y aplica reglas seguras del sistema"
            echo "  --user                  Migra variables antiguas sin tocar reglas de sistema"
            echo "  --lutris-sdl <juego>    Aísla un juego externo de Lutris de Steam Input"
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
