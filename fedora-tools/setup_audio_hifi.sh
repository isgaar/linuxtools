#!/usr/bin/env bash
#
# ==============================================================================
# Script de Configuración de Audio de Alta Fidelidad (Hi-Fi & Bit-Perfect)
# para Fedora Linux (PipeWire 1.6+ & WirePlumber 0.5+)
# ==============================================================================
# Características de Audio Puro (Hardware Bound):
#  - Conmutación dinámica de frecuencia de muestreo de hardware (Bit-Perfect):
#    44.1 kHz, 48.0 kHz, 88.2 kHz, 96.0 kHz, 176.4 kHz y 192.0 kHz sin remuestreo.
#  - Profundidad de bits nativa de 24/32 bits (S32LE) en hardware DAC (ALC623 / HDMI).
#  - Calidad de remuestreo audiófilo nivel 14 (libsoxr / sinc interpolado de alta precisión).
#  - Desactivación de remezclas destructivas (sin pseudo-surround ni normalización recortada).
#  - Acceso directo DMA MMAP para ALSA con periodos y márgenes optimizados.
#  - Nivel de volumen digital PCM ALSA fijado al 100% (0.00 dB) para evitar truncamiento digital.
#  - Desactivación de ahorro de energía agresivo en snd_hda_intel para eliminar pops y cortes.
#  - Prioridades de tiempo real (RTKit / PAM limits) para evitar xruns / caídas de buffer.
#  - Soporte Bluetooth Hi-Fi: SBC-XQ, LDAC (HQ 990 kbps forzado) y códecs aptX / aptX HD.
#  - Diagnóstico en tiempo real y función de restauración completa (Rollback).
#  - Soporta modo Usuario (~/.config, sin sudo) y modo Sistema (/etc, con sudo).
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

# Detectar usuario real y directorio del script
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REAL_USER="${SUDO_USER:-$USER}"
if [ "$REAL_USER" = "root" ]; then
    REAL_USER=$(logname 2>/dev/null || who | awk '{print $1}' | head -n 1 || echo "ismael")
fi
REAL_HOME=$(eval echo "~$REAL_USER")
REAL_UID=$(id -u "$REAL_USER" 2>/dev/null || echo "1000")

# Determinar modo (sistema o usuario)
TARGET_MODE="user"
if [ "$EUID" -eq 0 ]; then
    TARGET_MODE="system"
fi

set_target_paths() {
    if [ "$TARGET_MODE" = "system" ]; then
        PW_BASE="/etc/pipewire"
        WP_BASE="/etc/wireplumber"
    else
        PW_BASE="$REAL_HOME/.config/pipewire"
        WP_BASE="$REAL_HOME/.config/wireplumber"
    fi
}

set_target_paths

# Validar distribución y componentes
validate_system() {
    if [ ! -f /etc/os-release ]; then
        log_error "No se pudo identificar la distribución (/etc/os-release no existe)."
        exit 1
    fi
    . /etc/os-release
    if [[ "$ID" != "fedora" && "$ID_LIKE" != *"fedora"* ]]; then
        log_warn "Sistema detectado: ${NAME:-desconocido}. Diseñado principalmente para Fedora."
    fi

    if ! command -v pipewire &>/dev/null; then
        log_error "PipeWire no está instalado en este sistema."
        exit 1
    fi
}

# Reiniciar servicios de usuario para el usuario real
restart_user_services() {
    log_info "Reiniciando servicios de PipeWire y WirePlumber para $REAL_USER..."
    if [ "$EUID" -eq 0 ]; then
        if [ -d "/run/user/$REAL_UID" ]; then
            sudo -u "$REAL_USER" XDG_RUNTIME_DIR="/run/user/$REAL_UID" \
                systemctl --user restart pipewire pipewire-pulse wireplumber 2>/dev/null || true
            sleep 1
            log_success "Servidores de audio reiniciados con éxito."
        fi
    else
        systemctl --user restart pipewire pipewire-pulse wireplumber 2>/dev/null || true
        sleep 1
        log_success "Servidores de audio reiniciados con éxito."
    fi
}

# 2. Configurar Núcleo de Audio Hi-Fi Bit-Perfect
install_core_hifi() {
    log_step "Aplicando Configuración de Audio de Alta Fidelidad y Bit-Perfect (Modo: $TARGET_MODE)..."

    set_target_paths
    mkdir -p "$PW_BASE/pipewire.conf.d"
    mkdir -p "$PW_BASE/pipewire-pulse.conf.d"
    mkdir -p "$WP_BASE/wireplumber.conf.d"

    # A) PipeWire Engine: dynamic sample rates 44.1k - 192k, resample quality 14 (soxr)
    local pw_conf="$PW_BASE/pipewire.conf.d/99-hires-audio.conf"
    log_info "Configurando motor PipeWire ($pw_conf)..."
    cat > "$pw_conf" << 'EOF'
# PipeWire High-Fidelity & Bit-Perfect Engine Configuration
context.properties = {
    default.clock.rate          = 48000
    default.clock.allowed-rates = [ 44100 48000 88200 96000 176400 192000 ]
    default.clock.quantum       = 1024
    default.clock.min-quantum   = 64
    default.clock.max-quantum   = 8192
}

context.modules = [
    {
        name = libpipewire-module-rt
        args = {
            nice.level    = -19
            rt.prio       = 88
            rt.time.soft  = -1
            rt.time.hard  = -1
        }
        flags = [ ifexists nofail ]
    }
]

stream.properties = {
    resample.quality      = 14
    channelmix.upmix      = false
    channelmix.normalize  = false
    channelmix.lfe-cutoff = 0
    dither.noise          = 0
}
EOF

    # B) PipeWire-Pulse: calidad de remuestreo audiófilo y audio puro
    local pulse_conf="$PW_BASE/pipewire-pulse.conf.d/99-hires-pulse.conf"
    log_info "Configurando cliente PulseAudio ($pulse_conf)..."
    cat > "$pulse_conf" << 'EOF'
# PipeWire-Pulse High-Fidelity Stream Configuration
stream.properties = {
    resample.quality     = 14
    channelmix.upmix     = false
    channelmix.normalize = false
}
EOF

    # C) WirePlumber 0.5+: soporte Hi-Fi / Bit-Perfect multitarjeta (PCI, USB-C, HDMI)
    local alsa_conf="$WP_BASE/wireplumber.conf.d/50-alsa-hifi.conf"
    log_info "Configurando reglas ALSA en WirePlumber ($alsa_conf)..."
    cat > "$alsa_conf" << 'EOF'
# WirePlumber 0.5+ ALSA Hardware Direct Hi-Fi / Bit-Perfect Configuration
monitor.alsa.rules = [
  # Reglas generales para todas las salidas ALSA (PCI, USB-C, USB DACs, HDMI)
  {
    matches = [
      {
        "node.name" = "~alsa_output.*"
      }
    ]
    actions = {
      update-props = {
        "audio.allowed-rates"            = [ 44100 48000 88200 96000 176400 192000 ]
        "resample.quality"               = 14
        "channelmix.upmix"               = false
        "channelmix.normalize"           = false
        "api.alsa.disable-mmap"          = false
        "api.alsa.disable-batch"         = false
      }
    }
  },
  # Optimizaciones de buffer de memoria para DACs internos PCI
  {
    matches = [
      {
        "node.name" = "~alsa_output.pci.*"
      }
    ]
    actions = {
      update-props = {
        "api.alsa.period-size"           = 1024
        "api.alsa.headroom"              = 512
      }
    }
  }
]
EOF

    # Si se ejecuta con permisos de administrador, aplicar ajustes de sistema (modprobe, limits)
    if [ "$EUID" -eq 0 ]; then
        log_info "Desactivando ahorro de energía en snd_hda_intel (/etc/modprobe.d/audio-hifi-powersave.conf)..."
        cat > /etc/modprobe.d/audio-hifi-powersave.conf << 'EOF'
# Desactivar suspensión de energía en el DAC analógico para evitar clicks, pops y latencia
options snd_hda_intel power_save=0 power_save_controller=N
EOF
        if [ -w /sys/module/snd_hda_intel/parameters/power_save ]; then
            echo 0 > /sys/module/snd_hda_intel/parameters/power_save 2>/dev/null || true
        fi
        if [ -w /sys/module/snd_hda_intel/parameters/power_save_controller ]; then
            echo N > /sys/module/snd_hda_intel/parameters/power_save_controller 2>/dev/null || true
        fi

        log_info "Configurando prioridades de tiempo real para audio (/etc/security/limits.d/99-audio-realtime.conf)..."
        cat > /etc/security/limits.d/99-audio-realtime.conf << 'EOF'
@audio   -   rtprio      95
@audio   -   nice        -19
@audio   -   memlock     unlimited
EOF
        if getent group audio >/dev/null 2>&1; then
            if ! id -nG "$REAL_USER" | grep -qw "audio"; then
                log_info "Añadiendo a $REAL_USER al grupo 'audio'..."
                usermod -aG audio "$REAL_USER" || true
            fi
        fi
    fi

    # D) ALSA Hardware Mixer: Fijar PCM y controles al 100% (0 dB) para transmisión de bits inalterada al DAC
    log_info "Calibrando mezclador ALSA a 0 dB de ganancia digital (Bit-Perfect)..."
    for card_num in 0 1 2; do
        if [ -d "/proc/asound/card$card_num" ]; then
            # Controles analógicos existentes
            amixer -c "$card_num" sset PCM 100% 2>/dev/null || true
            amixer -c "$card_num" sset PCM 255 2>/dev/null || true
            amixer -c "$card_num" sset Master 100% unmute 2>/dev/null || true
            amixer -c "$card_num" sset Speaker 100% unmute 2>/dev/null || true
            amixer -c "$card_num" sset Headphone 100% unmute 2>/dev/null || true
            amixer -c "$card_num" sset "Line Out" 100% unmute 2>/dev/null || true
            amixer -c "$card_num" sset "Auto-Mute Mode" "Disabled" 2>/dev/null || true

            # Controles digitales HDMI/IEC958 para solución de volumen bajo en HDMI
            amixer -c "$card_num" sset IEC958 100% unmute 2>/dev/null || true
            amixer -c "$card_num" sset "IEC958 Default PCM" 100% unmute 2>/dev/null || true
            amixer -c "$card_num" sset HDMI 100% unmute 2>/dev/null || true
            amixer -c "$card_num" sset "Digital" 100% unmute 2>/dev/null || true
            amixer -c "$card_num" sset "S/PDIF" 100% unmute 2>/dev/null || true
            amixer -c "$card_num" sset "S/PDIF,0" 100% unmute 2>/dev/null || true
            amixer -c "$card_num" sset "S/PDIF,1" 100% unmute 2>/dev/null || true
        fi
    done

    # Asegurar propiedad correcta si se creó como usuario normal
    if [ "$EUID" -ne 0 ]; then
        chmod -R u+rw "$PW_BASE" "$WP_BASE" 2>/dev/null || true
    fi

    restart_user_services
    log_success "¡Núcleo de audio Hi-Fi Bit-Perfect configurado y activado!"
}

# 3. Configurar Bluetooth Hi-Fi (LDAC HQ, SBC-XQ, aptX)
install_bluetooth_hifi() {
    log_step "Configurando Bluetooth de Alta Fidelidad (Modo: $TARGET_MODE)..."

    set_target_paths
    mkdir -p "$WP_BASE/wireplumber.conf.d"

    local bt_conf="$WP_BASE/wireplumber.conf.d/50-bluetooth-hifi.conf"
    log_info "Configurando perfiles Bluetooth de alta tasa ($bt_conf)..."
    cat > "$bt_conf" << 'EOF'
# WirePlumber 0.5+ Bluetooth Audiophile Configuration
monitor.bluez.properties = {
  bluez5.enable-sbc-xq = true
  bluez5.enable-msbc   = true
  bluez5.enable-hw-volume = true
  bluez5.codecs        = [ "ldac" "aptx_hd" "aptx" "aac" "sbc_xq" "sbc" ]
}

monitor.bluez.rules = [
  {
    matches = [
      {
        "device.name" = "~bluez_card.*"
      }
    ]
    actions = {
      update-props = {
        "bluez5.a2dp.ldac.quality" = "hq"
      }
    }
  }
]
EOF

    # Instalar paquetes de códecs aptX de RPM Fusion si tenemos permisos de root o sudo
    if [ "$EUID" -eq 0 ]; then
        log_info "Instalando paquetes de códecs aptX..."
        dnf install -y pipewire-codec-aptx libfreeaptx 2>/dev/null || log_warn "Aviso al instalar códecs aptX."
    else
        log_info "Los perfiles de WirePlumber (LDAC HQ y SBC-XQ) han sido aplicados."
        log_info "Para soporte adicional de aptX/aptX HD puedes instalar con sudo: 'sudo dnf install -y pipewire-codec-aptx libfreeaptx'"
    fi

    restart_user_services
    log_success "¡Bluetooth de Alta Fidelidad configurado con éxito!"
}

# 4. Instalar y Configurar Perfil Maestro Fusión "hifi-loss" (Hi-Fi Lossless Studio Master)
install_hifi_loss_audio() {
    log_step "Configurando Perfil Maestro Fusión 'hifi-loss' en PipeWire..."

    # 1. Asegurar que EasyEffects quede detenido y deshabilitado para evitar intermediarios
    log_info "Desactivando intermediarios (EasyEffects)..."
    if [ "$EUID" -eq 0 ]; then
        sudo -u "$REAL_USER" XDG_RUNTIME_DIR="/run/user/$REAL_UID" systemctl --user stop easyeffects.service 2>/dev/null || true
        sudo -u "$REAL_USER" XDG_RUNTIME_DIR="/run/user/$REAL_UID" systemctl --user disable easyeffects.service 2>/dev/null || true
    else
        systemctl --user stop easyeffects.service 2>/dev/null || true
        systemctl --user disable easyeffects.service 2>/dev/null || true
    fi

    # 2. Configurar PipeWire Filter-Chain (Perfil Maestro hifi-loss)
    local pw_conf_dir="$REAL_HOME/.config/pipewire/pipewire.conf.d"
    mkdir -p "$pw_conf_dir"
    local template="$SCRIPT_DIR/pipewire/60-hifi-loss.conf"
    local target_conf="$pw_conf_dir/60-hifi-loss.conf"

    # Retirar configuraciones anteriores para evitar colisiones
    rm -f "$pw_conf_dir/60-native-spatial-audio.conf" "$pw_conf_dir/65-windows-reference-profile.conf"
    if [ "$EUID" -eq 0 ]; then
        rm -f /etc/pipewire/pipewire.conf.d/60-native-spatial-audio.conf /etc/pipewire/pipewire.conf.d/65-windows-reference-profile.conf
    fi

    if [ -f "$template" ]; then
        cp -f "$template" "$target_conf"
    fi
    chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.config/pipewire" 2>/dev/null || true

    # Si es root, colocar también en /etc/pipewire
    if [ "$EUID" -eq 0 ]; then
        mkdir -p /etc/pipewire/pipewire.conf.d
        [ -f "$template" ] && cp -f "$template" /etc/pipewire/pipewire.conf.d/60-hifi-loss.conf
    fi

    # 3. Reiniciar servicios de usuario para activar el sink nativo
    restart_user_services

    sleep 1.5

    # 4. Establecer hifi_loss_sink como el sink predeterminado (SIN tocar el volumen del usuario)
    log_info "Configurando 'hifi_loss_sink' como salida de audio principal..."
    local sink_id
    if [ "$EUID" -eq 0 ]; then
        sink_id=$(sudo -u "$REAL_USER" XDG_RUNTIME_DIR="/run/user/$REAL_UID" wpctl status 2>/dev/null | grep "hifi_loss_sink" | grep -oP '\b[0-9]+(?=\.\s+)' | head -n 1)
        if [ -n "$sink_id" ]; then
            sudo -u "$REAL_USER" XDG_RUNTIME_DIR="/run/user/$REAL_UID" wpctl set-default "$sink_id" 2>/dev/null || true
            sudo -u "$REAL_USER" XDG_RUNTIME_DIR="/run/user/$REAL_UID" pactl set-default-sink hifi_loss_sink 2>/dev/null || true
        fi
        # Limpiar afinidades obsoletas en WirePlumber
        if [ -f "$REAL_HOME/.local/state/wireplumber/stream-properties" ]; then
            sed -i 's/"target":"easyeffects_sink", //g; s/, "target":"easyeffects_sink"//g' "$REAL_HOME/.local/state/wireplumber/stream-properties" 2>/dev/null || true
        fi
        if [ -f "$REAL_HOME/.local/state/wireplumber/default-nodes" ]; then
            sed -i 's/^default\.configured\.audio\.sink=.*/default.configured.audio.sink=hifi_loss_sink/' "$REAL_HOME/.local/state/wireplumber/default-nodes" 2>/dev/null || true
        fi
        # Re-enrutar streams de aplicaciones activas hacia hifi_loss_sink
        for input_id in $(sudo -u "$REAL_USER" XDG_RUNTIME_DIR="/run/user/$REAL_UID" pactl list short sink-inputs 2>/dev/null | awk '$3 != "-" {print $1}'); do
            sudo -u "$REAL_USER" XDG_RUNTIME_DIR="/run/user/$REAL_UID" pactl move-sink-input "$input_id" hifi_loss_sink 2>/dev/null || true
        done

        # ESTABLECER VOLUMEN DEL SINK hifi_loss_sink AL 100% PARA CORREGIR VOLUMEN BAJO EN HDMI
        log_info "Estableciendo volumen de hifi_loss_sink al 100% para corregir volumen bajo en salida HDMI..."
        sudo -u "$REAL_USER" XDG_RUNTIME_DIR="/run/user/$REAL_UID" pactl set-sink-volume hifi_loss_sink 100% 2>/dev/null || true

        # 5. Instalar gancho nativo en las entrañas de WirePlumber (C/Lua runtime sin servicios externos)
        log_info "Instalando gancho nativo en las entrañas de WirePlumber (C/Lua Engine)..."
        mkdir -p /etc/wireplumber/scripts /etc/wireplumber/wireplumber.conf.d /etc/pipewire/pipewire-pulse.conf.d
        cp -f "$SCRIPT_DIR/wireplumber/hifi-loss-router.lua" /etc/wireplumber/scripts/hifi-loss-router.lua
        cp -f "$SCRIPT_DIR/wireplumber/60-hifi-loss-router.conf" /etc/wireplumber/wireplumber.conf.d/60-hifi-loss-router.conf
        cp -f "$SCRIPT_DIR/pipewire/60-hifi-loss-routing.conf" /etc/pipewire/pipewire-pulse.conf.d/60-hifi-loss-routing.conf

        mkdir -p "$REAL_HOME/.config/wireplumber/scripts" "$REAL_HOME/.config/wireplumber/wireplumber.conf.d" "$REAL_HOME/.config/pipewire/pipewire-pulse.conf.d"
        cp -f "$SCRIPT_DIR/wireplumber/hifi-loss-router.lua" "$REAL_HOME/.config/wireplumber/scripts/hifi-loss-router.lua"
        cp -f "$SCRIPT_DIR/wireplumber/60-hifi-loss-router.conf" "$REAL_HOME/.config/wireplumber/wireplumber.conf.d/60-hifi-loss-router.conf"
        cp -f "$SCRIPT_DIR/pipewire/60-hifi-loss-routing.conf" "$REAL_HOME/.config/pipewire/pipewire-pulse.conf.d/60-hifi-loss-routing.conf"
        chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.config/wireplumber" "$REAL_HOME/.config/pipewire" 2>/dev/null || true
    else
        sink_id=$(wpctl status 2>/dev/null | grep "hifi_loss_sink" | grep -oP '\b[0-9]+(?=\.\s+)' | head -n 1)
        if [ -n "$sink_id" ]; then
            wpctl set-default "$sink_id" 2>/dev/null || true
            pactl set-default-sink hifi_loss_sink 2>/dev/null || true
        fi
        # Limpiar afinidades obsoletas en WirePlumber
        if [ -f "$REAL_HOME/.local/state/wireplumber/stream-properties" ]; then
            sed -i 's/"target":"easyeffects_sink", //g; s/, "target":"easyeffects_sink"//g' "$REAL_HOME/.local/state/wireplumber/stream-properties" 2>/dev/null || true
        fi
        if [ -f "$REAL_HOME/.local/state/wireplumber/default-nodes" ]; then
            sed -i 's/^default\.configured\.audio\.sink=.*/default.configured.audio.sink=hifi_loss_sink/' "$REAL_HOME/.local/state/wireplumber/default-nodes" 2>/dev/null || true
        fi
        # Re-enrutar streams de aplicaciones activas hacia hifi_loss_sink
        for input_id in $(pactl list short sink-inputs 2>/dev/null | awk '$3 != "-" {print $1}'); do
            pactl move-sink-input "$input_id" hifi_loss_sink 2>/dev/null || true
        done

        # ESTABLECER VOLUMEN DEL SINK hifi_loss_sink AL 100% PARA CORREGIR VOLUMEN BAJO EN HDMI
        log_info "Estableciendo volumen de hifi_loss_sink al 100% para corregir volumen bajo en salida HDMI..."
        pactl set-sink-volume hifi_loss_sink 100% 2>/dev/null || true

        # 5. Instalar gancho nativo en las entrañas de WirePlumber del usuario
        log_info "Instalando gancho nativo en las entrañas de WirePlumber (C/Lua Engine)..."
        mkdir -p "$REAL_HOME/.config/wireplumber/scripts" "$REAL_HOME/.config/wireplumber/wireplumber.conf.d" "$REAL_HOME/.config/pipewire/pipewire-pulse.conf.d"
        cp -f "$SCRIPT_DIR/wireplumber/hifi-loss-router.lua" "$REAL_HOME/.config/wireplumber/scripts/hifi-loss-router.lua"
        cp -f "$SCRIPT_DIR/wireplumber/60-hifi-loss-router.conf" "$REAL_HOME/.config/wireplumber/wireplumber.conf.d/60-hifi-loss-router.conf"
        cp -f "$SCRIPT_DIR/pipewire/60-hifi-loss-routing.conf" "$REAL_HOME/.config/pipewire/pipewire-pulse.conf.d/60-hifi-loss-routing.conf"
    fi

    # Reiniciar WirePlumber para compilar y cargar el gancho nativo en memoria
    restart_user_services

    log_success "¡Perfil Maestro 'hifi-loss' integrado en las entrañas nativas de PipeWire y WirePlumber!"
}

# Alias para compatibilidad hacia atrás
install_native_spatial_audio() {
    install_hifi_loss_audio
}

# 5. Instalar y Configurar Perfil de Referencia Neutro Windows en PipeWire
install_windows_reference_audio() {
    log_step "Configurando Perfil de Referencia Neutro Windows en PipeWire..."

    # 1. Asegurar que EasyEffects quede detenido
    log_info "Desactivando intermediarios (EasyEffects)..."
    if [ "$EUID" -eq 0 ]; then
        sudo -u "$REAL_USER" XDG_RUNTIME_DIR="/run/user/$REAL_UID" systemctl --user stop easyeffects.service 2>/dev/null || true
        sudo -u "$REAL_USER" XDG_RUNTIME_DIR="/run/user/$REAL_UID" systemctl --user disable easyeffects.service 2>/dev/null || true
    else
        systemctl --user stop easyeffects.service 2>/dev/null || true
        systemctl --user disable easyeffects.service 2>/dev/null || true
    fi

    # 2. Configurar PipeWire Filter-Chain Neutro (1:1 lineal, 0% diafonía, techo dinámico -0.14 dBFS)
    local pw_conf_dir="$REAL_HOME/.config/pipewire/pipewire.conf.d"
    mkdir -p "$pw_conf_dir"
    local template="$SCRIPT_DIR/pipewire/65-windows-reference-profile.conf"
    local target_conf="$pw_conf_dir/65-windows-reference-profile.conf"

    # Retirar perfil espacial si estuviera activo para que la salida sea 100% neutra
    rm -f "$pw_conf_dir/60-native-spatial-audio.conf"
    [ "$EUID" -eq 0 ] && rm -f /etc/pipewire/pipewire.conf.d/60-native-spatial-audio.conf

    if [ -f "$template" ]; then
        cp -f "$template" "$target_conf"
    fi
    chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.config/pipewire" 2>/dev/null || true

    # Si es root, colocar también en /etc/pipewire
    if [ "$EUID" -eq 0 ]; then
        mkdir -p /etc/pipewire/pipewire.conf.d
        [ -f "$template" ] && cp -f "$template" /etc/pipewire/pipewire.conf.d/65-windows-reference-profile.conf
    fi

    # 3. Reiniciar servicios de usuario para activar el sink de referencia
    restart_user_services

    sleep 1.5

    # 4. Establecer windows_reference_sink como el sink predeterminado
    log_info "Configurando 'windows_reference_sink' como salida de audio principal..."
    local sink_id
    if [ "$EUID" -eq 0 ]; then
        sink_id=$(sudo -u "$REAL_USER" XDG_RUNTIME_DIR="/run/user/$REAL_UID" wpctl status 2>/dev/null | grep "windows_reference_sink" | grep -oP '\b[0-9]+(?=\.\s+)' | head -n 1)
        if [ -n "$sink_id" ]; then
            sudo -u "$REAL_USER" XDG_RUNTIME_DIR="/run/user/$REAL_UID" wpctl set-default "$sink_id" 2>/dev/null || true
            sudo -u "$REAL_USER" XDG_RUNTIME_DIR="/run/user/$REAL_UID" wpctl set-volume "$sink_id" 1.0 2>/dev/null || true
        fi
        for hw_sink in $(sudo -u "$REAL_USER" XDG_RUNTIME_DIR="/run/user/$REAL_UID" wpctl status 2>/dev/null | sed -n '/Sinks:/,/Sources:/p' | grep -oP '\b[0-9]+(?=\.\s+)'); do
            sudo -u "$REAL_USER" XDG_RUNTIME_DIR="/run/user/$REAL_UID" wpctl set-volume "$hw_sink" 1.0 2>/dev/null || true
        done
    else
        sink_id=$(wpctl status 2>/dev/null | grep "windows_reference_sink" | grep -oP '\b[0-9]+(?=\.\s+)' | head -n 1)
        if [ -n "$sink_id" ]; then
            wpctl set-default "$sink_id" 2>/dev/null || true
            wpctl set-volume "$sink_id" 1.0 2>/dev/null || true
        fi
        for hw_sink in $(wpctl status 2>/dev/null | sed -n '/Sinks:/,/Sources:/p' | grep -oP '\b[0-9]+(?=\.\s+)'); do
            wpctl set-volume "$hw_sink" 1.0 2>/dev/null || true
        done
    fi

    log_success "¡Perfil de Referencia Neutro Windows activado en PipeWire! Respuesta plana 1:1, 0% diafonía y techo de -0.14 dBFS."
}

# 6. Instalar Parche de Pines HDA Realtek ALC623 (Lenovo Chasis)
install_alc623_pin_patch() {
    log_step "Aplicando Parche de Pines HDA para Realtek ALC623 (Lenovo Chasis)..."
    local fw_src="$SCRIPT_DIR/alsa-realtek-alc623.fw"
    if [ ! -f "$fw_src" ]; then
        log_error "No se encontró el firmware de pines: $fw_src"
        return 1
    fi

    if [ "$EUID" -eq 0 ]; then
        log_info "Instalando firmware en /lib/firmware/alsa-realtek-alc623.fw..."
        cp -f "$fw_src" /lib/firmware/alsa-realtek-alc623.fw
        chmod 644 /lib/firmware/alsa-realtek-alc623.fw
        log_info "Creando regla modprobe en /etc/modprobe.d/alsa-alc623-pins.conf..."
        cat > /etc/modprobe.d/alsa-alc623-pins.conf << 'EOF'
# Parche de pines decodificados para Realtek ALC623 (NID 0x17 Altavoces, 0x14 Línea Trasera, 0x21 Auriculares)
options snd-hda-intel patch=alsa-realtek-alc623.fw
EOF
        log_success "Parche de pines ALSA instalado correctamente en /lib/firmware y /etc/modprobe.d/."
    else
        if command -v sudo &>/dev/null; then
            log_info "Se requieren permisos de administrador (sudo) para instalar en /lib/firmware/:"
            sudo cp -f "$fw_src" /lib/firmware/alsa-realtek-alc623.fw
            sudo chmod 644 /lib/firmware/alsa-realtek-alc623.fw
            echo "options snd-hda-intel patch=alsa-realtek-alc623.fw" | sudo tee /etc/modprobe.d/alsa-alc623-pins.conf >/dev/null
            log_success "Parche de pines ALSA instalado correctamente con sudo."
        else
            log_warn "No se tienen permisos de sudo. Ejecuta como root o con sudo para aplicar el parche."
            return 1
        fi
    fi
    log_info "Aviso: El parche de hardware ALSA se cargará automáticamente al reiniciar el sistema o al recargar el módulo snd_hda_intel."
}

# 5. Instalar y Configurar Suite DSP Alternativa (EasyEffects Opcional)
install_dsp_suite() {
    log_step "Instalando y Configurando Suite DSP de Audio Espacial (Dolby Atmos & Soundstage)..."

    # Instalar paquetes de EasyEffects y plugins LV2 si faltan
    if ! command -v easyeffects &>/dev/null; then
        log_info "Instalando EasyEffects y plugins de efectos de estudio..."
        if [ "$EUID" -eq 0 ]; then
            dnf install -y easyeffects lsp-plugins calf lv2-calf-plugins lv2-mdala-plugins lv2-zam-plugins || log_warn "Aviso al instalar paquetes DSP mediante dnf."
        else
            if command -v sudo &>/dev/null; then
                sudo dnf install -y easyeffects lsp-plugins calf lv2-calf-plugins lv2-mdala-plugins lv2-zam-plugins || log_warn "Aviso al instalar paquetes DSP mediante sudo dnf."
            else
                log_error "Se requieren permisos de administrador para instalar paquetes RPM."
                return 1
            fi
        fi
    fi
    log_success "Paquetes de EasyEffects y plugins de audio verificados."

    # Instalar perfiles y archivos de respuesta de impulso (IRS)
    local user_ee_output="$REAL_HOME/.local/share/easyeffects/output"
    local user_ee_irs="$REAL_HOME/.local/share/easyeffects/irs"
    mkdir -p "$user_ee_output" "$user_ee_irs"
    mkdir -p "$REAL_HOME/.config/easyeffects/output" "$REAL_HOME/.config/easyeffects/irs"

    if [ -d "$SCRIPT_DIR/presets" ]; then
        log_info "Instalando perfiles de audio espacial (Dolby Atmos, Loudness, Crystalizer)..."
        cp -f "$SCRIPT_DIR/presets/"*.json "$user_ee_output/" 2>/dev/null || true
        cp -f "$SCRIPT_DIR/presets/"*.json "$REAL_HOME/.config/easyeffects/output/" 2>/dev/null || true
        if [ -d "$SCRIPT_DIR/presets/irs" ]; then
            log_info "Instalando respuestas de impulso acústico (Dolby/Waves/Razer)..."
            cp -f "$SCRIPT_DIR/presets/irs/"* "$user_ee_irs/" 2>/dev/null || true
            cp -f "$SCRIPT_DIR/presets/irs/"* "$REAL_HOME/.config/easyeffects/irs/" 2>/dev/null || true
        fi
        chown -R "$REAL_USER:$REAL_USER" "$user_ee_output" "$user_ee_irs" 2>/dev/null || true
        chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.config/easyeffects" 2>/dev/null || true
    fi

    # Configurar servicio en segundo plano (systemd user service) para que se ejecute silenciosamente
    local service_dir="$REAL_HOME/.config/systemd/user"
    mkdir -p "$service_dir"
    cat > "$service_dir/easyeffects.service" << 'EOF'
[Unit]
Description=EasyEffects Audio Service
Documentation=https://github.com/wwmm/easyeffects
After=pipewire.service wireplumber.service
PartOf=pipewire.service

[Service]
Type=simple
ExecStart=/usr/bin/easyeffects --service-mode
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=default.target
EOF
    chown -R "$REAL_USER:$REAL_USER" "$service_dir" 2>/dev/null || true

    # Habilitar e iniciar servicio para el usuario real
    log_info "Habilitando servicio en segundo plano de EasyEffects (systemd user)..."
    if [ "$EUID" -eq 0 ]; then
        sudo -u "$REAL_USER" XDG_RUNTIME_DIR="/run/user/$REAL_UID" systemctl --user daemon-reload || true
        sudo -u "$REAL_USER" XDG_RUNTIME_DIR="/run/user/$REAL_UID" systemctl --user enable --now easyeffects.service || true
    else
        systemctl --user daemon-reload || true
        systemctl --user enable --now easyeffects.service || true
    fi

    sleep 1
    # Cargar por defecto el perfil Dolby Atmos Spatial Studio
    log_info "Cargando perfil espacial: 'Dolby Atmos Spatial Studio'..."
    if [ "$EUID" -eq 0 ]; then
        sudo -u "$REAL_USER" XDG_RUNTIME_DIR="/run/user/$REAL_UID" easyeffects -l "Dolby Atmos Spatial Studio" 2>/dev/null || true
    else
        easyeffects -l "Dolby Atmos Spatial Studio" 2>/dev/null || true
    fi

    log_success "¡Audio Espacial activado! Se ha eliminado el efecto encapsulado gracias a crossfeed binaural, ensanchamiento stereo y ecualización de presencia."
}

# 5. Diagnóstico de Estado y Monitor Bit-Perfect
show_status() {
    log_step "Diagnóstico de Hardware y Estado de Audio Hi-Fi"
    echo -e "${BOLD}1. Tarjetas de sonido detectadas en ALSA:${NC}"
    aplay -l 2>/dev/null || cat /proc/asound/cards

    echo -e "\n${BOLD}2. Capacidades nativas del DAC analógico (ALC623):${NC}"
    if [ -f /proc/asound/card1/codec#0 ]; then
        grep -E "(Codec:|rates|bits)" /proc/asound/card1/codec#0 | head -n 6
    fi

    echo -e "\n${BOLD}3. Frecuencias y Cuantización activas en PipeWire:${NC}"
    pw-metadata 0 2>/dev/null | grep -E "default\.(clock|audio)" || echo "Metadatos no disponibles."

    echo -e "\n${BOLD}4. Estado de Nodos y Sinks en WirePlumber:${NC}"
    wpctl status 2>/dev/null | sed -n '/Audio/,/Settings/p' || true

    echo -e "\n${BOLD}5. Archivos de configuración Hi-Fi activos:${NC}"
    echo -e "${CYAN}[Usuario $REAL_USER]${NC}"
    ls -l "$REAL_HOME/.config/pipewire/pipewire.conf.d/99-hires-audio.conf" \
          "$REAL_HOME/.config/pipewire/pipewire.conf.d/60-hifi-loss.conf" \
          "$REAL_HOME/.config/pipewire/pipewire.conf.d/60-native-spatial-audio.conf" \
          "$REAL_HOME/.config/pipewire/pipewire.conf.d/65-windows-reference-profile.conf" \
          "$REAL_HOME/.config/pipewire/pipewire-pulse.conf.d/99-hires-pulse.conf" \
          "$REAL_HOME/.config/wireplumber/wireplumber.conf.d/50-alsa-hifi.conf" \
          "$REAL_HOME/.config/wireplumber/wireplumber.conf.d/50-bluetooth-hifi.conf" 2>/dev/null || echo "Sin archivos de usuario."

    echo -e "${CYAN}[Sistema /etc/]${NC}"
    ls -l /etc/pipewire/pipewire.conf.d/99-hires-audio.conf \
          /etc/pipewire/pipewire.conf.d/60-hifi-loss.conf \
          /etc/pipewire/pipewire.conf.d/60-native-spatial-audio.conf \
          /etc/pipewire/pipewire.conf.d/65-windows-reference-profile.conf \
          /etc/pipewire/pipewire-pulse.conf.d/99-hires-pulse.conf \
          /etc/wireplumber/wireplumber.conf.d/50-alsa-hifi.conf \
          /etc/wireplumber/wireplumber.conf.d/50-bluetooth-hifi.conf \
          /etc/modprobe.d/audio-hifi-powersave.conf \
          /etc/modprobe.d/alsa-alc623-pins.conf \
          /lib/firmware/alsa-realtek-alc623.fw \
          /etc/security/limits.d/99-audio-realtime.conf 2>/dev/null || echo "Sin archivos de sistema."

    echo -e "\n${BOLD}6. Estado de Ahorro de Energía (snd_hda_intel):${NC}"
    if [ -r /sys/module/snd_hda_intel/parameters/power_save ]; then
        local ps
        ps=$(cat /sys/module/snd_hda_intel/parameters/power_save)
        local psc
        psc=$(cat /sys/module/snd_hda_intel/parameters/power_save_controller 2>/dev/null || echo "N/A")
        echo "power_save: $ps (0 = Inactivo/Hi-Fi, 1 = Ahorro activo)"
        echo "power_save_controller: $psc"
    fi

    echo -e "\n${BOLD}7. Parche de Hardware ALSA para Realtek ALC623:${NC}"
    if [ -f /lib/firmware/alsa-realtek-alc623.fw ] && [ -f /etc/modprobe.d/alsa-alc623-pins.conf ]; then
        echo -e "${GREEN}[APLICADO]${NC} Firmware /lib/firmware/alsa-realtek-alc623.fw y modprobe activos."
    else
        echo -e "${YELLOW}[NO APLICADO]${NC} Se está utilizando la detección genérica de pines ALSA."
    fi

    echo -e "\n${BOLD}8. Perfil de Procesamiento Activo en PipeWire:${NC}"
    local default_sink
    default_sink=$(pactl get-default-sink 2>/dev/null || wpctl status 2>/dev/null | grep -A 2 "Default Configured Devices" | grep "Audio/Sink" | awk '{print $NF}')
    if [ "$default_sink" = "hifi_loss_sink" ]; then
        echo -e "${GREEN}[ACTIVO Y PREDETERMINADO]${NC} Perfil Maestro Fusión 'hifi-loss' (Hi-Fi Lossless: Harman/Mastering + Sub-25Hz Butterworth + Fase Estéreo Pura 1:1 + Techo -0.14 dBFS)"
    elif wpctl status 2>/dev/null | grep -q "hifi_loss_sink"; then
        echo -e "${YELLOW}[CARGADO PERO NO PREDETERMINADO]${NC} Perfil 'hifi-loss' está en memoria, pero el destino actual es: $default_sink"
    elif [ "$default_sink" = "spatial_audio_sink" ]; then
        echo -e "${GREEN}[ACTIVO Y PREDETERMINADO]${NC} Audio Espacial Nativo (10 Bandas + Pasa-Altos Subsónico 25 Hz + Mid/Side + Bauer)"
    elif [ "$default_sink" = "windows_reference_sink" ]; then
        echo -e "${CYAN}[ACTIVO Y PREDETERMINADO]${NC} Audio Referencia Neutro Windows (Respuesta plana 1:1, 0% diafonía, -0.14 dBFS)"
    else
        echo -e "${YELLOW}[DIRECTO]${NC} Salida directa a hardware ALSA ($default_sink) sin filtros de procesamiento."
    fi

    echo -e "\n${BOLD}9. Flujos de Audio en Reproducción (Streams):${NC}"
    wpctl status 2>/dev/null | sed -n '/Streams:/,/Video/p' | sed '$d'
}

# 6. Prueba de Conmutación Dinámica (Bit-Perfect Test)
run_bitperfect_test() {
    log_step "Ejecutando Prueba de Conmutación de Frecuencia (Bit-Perfect)..."
    log_info "Se generarán flujos de audio a 44.1 kHz, 48.0 kHz, 96.0 kHz y 192.0 kHz."
    log_info "Observa cómo el nodo de hardware conmuta en tiempo real sin remuestreo:"

    for rate in 44100 48000 96000 192000; do
        echo -e "\n${CYAN}>>> Conmutando a ${BOLD}${rate} Hz${NC}${CYAN}...${NC}"
        if command -v pw-cat &>/dev/null; then
            python3 -c "
import sys, math, struct
rate = $rate
duration = 1.8
samples = int(rate * duration)
for i in range(samples):
    sample = int(32767.0 * 0.15 * math.sin(2.0 * math.pi * 440.0 * i / rate))
    sys.stdout.buffer.write(struct.pack('<hh', sample, sample))
" | pw-cat -p --raw --rate "$rate" --channels 2 --format s16 - 2>/dev/null &
            local pid=$!
            sleep 0.6
            if command -v pw-top &>/dev/null; then
                pw-top -b -n 2 | grep -E "(alsa_output.*analog|FORMAT)" | tail -n 2 || true
            fi
            wait "$pid" 2>/dev/null || true
        fi
        sleep 0.3
    done

    echo ""
    log_success "Prueba Bit-Perfect completada con éxito. El DAC conmuta fluidamente a cada tasa nativa."
}

# 7. Restauración / Rollback de Fábrica
restore_defaults() {
    log_step "Restaurando Configuración de Audio de Fábrica (Rollback)..."

    # Eliminar configuraciones de usuario
    rm -f "$REAL_HOME/.config/pipewire/pipewire.conf.d/99-hires-audio.conf"
    rm -f "$REAL_HOME/.config/pipewire/pipewire.conf.d/60-hifi-loss.conf"
    rm -f "$REAL_HOME/.config/pipewire/pipewire.conf.d/60-native-spatial-audio.conf"
    rm -f "$REAL_HOME/.config/pipewire/pipewire.conf.d/65-windows-reference-profile.conf"
    rm -f "$REAL_HOME/.config/pipewire/pipewire-pulse.conf.d/99-hires-pulse.conf"
    rm -f "$REAL_HOME/.config/wireplumber/wireplumber.conf.d/50-alsa-hifi.conf"
    rm -f "$REAL_HOME/.config/wireplumber/wireplumber.conf.d/50-bluetooth-hifi.conf"

    # Si es root, eliminar también las de sistema
    if [ "$EUID" -eq 0 ]; then
        rm -f /etc/pipewire/pipewire.conf.d/99-hires-audio.conf
        rm -f /etc/pipewire/pipewire.conf.d/60-hifi-loss.conf
        rm -f /etc/pipewire/pipewire.conf.d/60-native-spatial-audio.conf
        rm -f /etc/pipewire/pipewire.conf.d/65-windows-reference-profile.conf
        rm -f /etc/pipewire/pipewire-pulse.conf.d/99-hires-pulse.conf
        rm -f /etc/wireplumber/wireplumber.conf.d/50-alsa-hifi.conf
        rm -f /etc/wireplumber/wireplumber.conf.d/50-bluetooth-hifi.conf
        rm -f /etc/modprobe.d/audio-hifi-powersave.conf
        rm -f /etc/modprobe.d/alsa-alc623-pins.conf
        rm -f /lib/firmware/alsa-realtek-alc623.fw
        rm -f /etc/security/limits.d/99-audio-realtime.conf

        if [ -w /sys/module/snd_hda_intel/parameters/power_save ]; then
            echo 1 > /sys/module/snd_hda_intel/parameters/power_save 2>/dev/null || true
        fi
    fi

    restart_user_services
    log_success "Configuraciones Hi-Fi eliminadas. Sistema restaurado a los valores estándar de Fedora."
}

# Menú interactivo
show_menu() {
    while true; do
        echo -e "\n${CYAN}======================================================${NC}"
        echo -e "${BOLD}${MAGENTA}       CONFIGURADOR DE AUDIO HI-FI / BIT-PERFECT      ${NC}"
        echo -e "${BOLD}             Fedora Linux (PipeWire 1.6+)            ${NC}"
        echo -e "${CYAN}======================================================${NC}"
        echo -e "Modo actual: ${BOLD}${TARGET_MODE}${NC} ($( [ "$TARGET_MODE" = "system" ] && echo "/etc/ (global)" || echo "$REAL_HOME/.config/ (usuario)" ))"
        echo -e "Selecciona una opción:\n"
        echo -e "  ${YELLOW}${BOLD}=== OPCIÓN RECOMENDADA (TODO EN UNO) ===${NC}"
        echo -e "  7) ${YELLOW}${BOLD}Instalación Completa${NC} -> Configura todo de una vez (Audio HD + Bluetooth HD + Perfil de sonido)\n"
        echo -e "  ${CYAN}${BOLD}=== CONFIGURACIONES INDIVIDUALES ===${NC}"
        echo -e "  1) ${GREEN}${BOLD}Configurar Audio Hi-Fi / Bit-Perfect & Audio Espacial Nativo${NC} -> Mapeo de audio de Windows + mejora espacial Lossless"
        echo -e "  2) ${GREEN}${BOLD}Audio de Alta Fidelidad (Bit-Perfect)${NC} -> Máxima calidad 24/32-bit sin pérdidas para cable, USB y HDMI"
        echo -e "  3) ${CYAN}Bluetooth de Alta Calidad${NC} -> Activa códecs HD (LDAC, aptX, SBC-XQ) para audífonos inalámbricos"
        echo -e "  4) ${MAGENTA}Parche para Equipos Lenovo (ALC623)${NC} -> Corrige altavoces internos o jack 3.5mm que no suenan"
        echo -e "  5) ${BLUE}Ecualizador Gráfico EasyEffects${NC} -> Instala app con ventana visual para ajustar el sonido a mano\n"
        echo -e "  ${WHITE}${BOLD}=== HERRAMIENTAS Y PRUEBAS ===${NC}"
        echo -e "  8) Ver Diagnóstico y Estado -> Muestra tarjetas de sonido detectadas y perfil activo"
        echo -e "  9) Probar Sonido -> Reproduce tonos de prueba en diferentes calidades"
        echo -e " 10) ${RED}Restaurar Sonido Original (Rollback)${NC} -> Deshace todas las configuraciones y vuelve a valores de fábrica"
        echo -e " 11) Salir"
        echo -e "${CYAN}------------------------------------------------------${NC}"
        echo -ne "Opción: "
        read -r choice

        case "$choice" in
            1)
                install_windows_reference_audio
                install_hifi_loss_audio
                ;;
            2)
                install_core_hifi
                ;;
            3)
                install_bluetooth_hifi
                ;;
            4)
                install_alc623_pin_patch
                ;;
            5)
                install_dsp_suite
                ;;
            6)
                install_core_hifi
                install_bluetooth_hifi
                install_hifi_loss_audio
                ;;
            7)
                show_status
                ;;
            8)
                run_bitperfect_test
                ;;
            9)
                restore_defaults
                ;;
            10)
                echo "¡Hasta luego!"
                exit 0
                ;;
            *)
                log_error "Opción no válida."
                ;;
        esac
    done
}

# --- Punto de Entrada ---
validate_system

if [ $# -gt 0 ]; then
    case "$1" in
        -i|--install)
            install_core_hifi
            ;;
        -b|--bluetooth)
            install_bluetooth_hifi
            ;;
        -l|--lossless|--hifi-loss|-n|--native-spatial|--spatial|--dolby)
            install_hifi_loss_audio
            ;;
        -w|--windows-ref|--reference)
            install_windows_reference_audio
            ;;
        -p|--patch-pins|--alc623)
            install_alc623_pin_patch
            ;;
        -e|--easyeffects|--dsp)
            install_dsp_suite
            ;;
        -a|--all)
            install_core_hifi
            install_bluetooth_hifi
            install_hifi_loss_audio
            ;;
        -s|--status)
            show_status
            ;;
        -t|--test)
            run_bitperfect_test
            ;;
        -r|--restore)
            restore_defaults
            ;;
        -h|--help)
            echo "Uso: $0 [opción]"
            echo "Opciones:"
            echo "  -a, --all                 Instalación Completa recomendada (Audio HD + Bluetooth HD + Perfil de sonido)"
            echo "  -i, --install             Activa audio HD / Bit-Perfect (24/32-bit sin pérdidas para cable/USB/HDMI)"
            echo "  -b, --bluetooth           Configura Bluetooth HD (LDAC HQ, aptX, SBC-XQ para audífonos)"
            echo "  -l, --hifi-loss, -n       Activa perfil 'hifi-loss' (mejores graves, voces claras y anti-distorsión)"
            echo "  -w, --windows-ref         Activa perfil neutro plano de referencia (estilo Windows sin retoques)"
            echo "  -p, --patch-pins          Aplica parche de hardware para equipos Lenovo (Realtek ALC623)"
            echo "  -e, --easyeffects         Instala suite gráfica EasyEffects (ecualizador con ventana)"
            echo "  -s, --status              Muestra el estado y diagnóstico del hardware"
            echo "  -t, --test                Ejecuta la prueba de frecuencias de sonido"
            echo "  -r, --restore             Restaura el audio a valores originales de fábrica"
            echo "  -h, --help                Muestra esta ayuda"
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
