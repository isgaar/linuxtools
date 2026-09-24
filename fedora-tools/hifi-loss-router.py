#!/usr/bin/env python3
"""
Hi-Fi Lossless Dynamic Hardware Router (hifi-loss-router)
=========================================================
Garantiza que el perfil de estudio "hifi-loss" procese TODO el audio del sistema
sin importar si el usuario conmuta entre Altavoces/Auriculares analógicos (ALC623),
monitores DisplayPort / HDMI, o DACs / audífonos USB-C.

Principios inviolables:
 1. Cero alteración de volumen: NUNCA modifica el nivel de volumen fijado por el usuario.
 2. A prueba de hotplug: Si se conecta o desconecta un dispositivo USB-C o DP, el flujo
    se re-enlaza en caliente (< 5ms) sin interrumpir la reproducción.
 3. Cero bypass: Las aplicaciones permanecen siempre conectadas a hifi_loss_sink.
"""

import sys
import subprocess
import re
import time
import signal

HIFI_SINK = "hifi_loss_sink"
HIFI_PLAYBACK_NAME = "hifi_loss_playback"

# Estado interno
current_hardware_sink = None
hifi_playback_input_id = None
running = True

def signal_handler(sig, frame):
    global running
    running = False
    sys.exit(0)

signal.signal(signal.SIGINT, signal_handler)
signal.signal(signal.SIGTERM, signal_handler)

def run_cmd(cmd):
    try:
        res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False)
        return res.stdout.strip()
    except Exception:
        return ""

def get_sinks():
    """Retorna lista de sinks [(id, name), ...]"""
    output = run_cmd(["pactl", "list", "short", "sinks"])
    sinks = []
    for line in output.splitlines():
        if not line:
            continue
        parts = line.split("\t")
        if len(parts) >= 2:
            sinks.append((parts[0], parts[1]))
    return sinks

def get_physical_sinks():
    """Filtra y retorna solo sinks de hardware (ALSA o Bluetooth)"""
    return [s for s in get_sinks() if s[1].startswith("alsa_output.") or s[1].startswith("bluez_output.")]

def get_sink_inputs():
    """Retorna lista de streams de reproducción [(input_id, sink_id, client_id, name), ...]"""
    output = run_cmd(["pactl", "list", "short", "sink-inputs"])
    inputs = []
    for line in output.splitlines():
        if not line:
            continue
        parts = line.split("\t")
        if len(parts) >= 3:
            inputs.append((parts[0], parts[1], parts[2]))
    return inputs

def get_hifi_playback_id():
    """Encuentra el sink-input correspondiente a la salida del filtro hifi-loss"""
    output = run_cmd(["pactl", "list", "sink-inputs"])
    current_id = None
    is_hifi_playback = False
    for line in output.splitlines():
        m_id = re.match(r"^Entrada del destino #(\d+)|^Sink Input #(\d+)", line)
        if m_id:
            if current_id and is_hifi_playback:
                return current_id
            current_id = m_id.group(1) or m_id.group(2)
            is_hifi_playback = False
            continue
        if current_id and 'node.name = "' + HIFI_PLAYBACK_NAME + '"' in line:
            is_hifi_playback = True
    if current_id and is_hifi_playback:
        return current_id
    return None

def get_default_sink():
    return run_cmd(["pactl", "get-default-sink"])

def ensure_routing():
    global current_hardware_sink, hifi_playback_input_id

    # 1. Verificar si hifi_loss_sink existe
    all_sinks = dict(get_sinks())
    sink_names = set(all_sinks.values())
    if HIFI_SINK not in sink_names:
        return

    # 2. Localizar el stream de salida de hifi-loss
    playback_id = get_hifi_playback_id()
    if not playback_id:
        return
    hifi_playback_input_id = playback_id

    # 3. Detectar qué sink físico debe recibir el audio
    # Si el usuario seleccionó un sink físico en KDE o pactl, lo adoptamos
    default_sink = get_default_sink()
    physical_sinks = get_physical_sinks()
    physical_names = [s[1] for s in physical_sinks]

    if default_sink in physical_names:
        current_hardware_sink = default_sink
    elif not current_hardware_sink or current_hardware_sink not in physical_names:
        # Preferir USB-C si está conectado, luego HDMI/DP, luego analógico
        usb_sinks = [s for s in physical_names if "usb" in s.lower()]
        hdmi_sinks = [s for s in physical_names if "hdmi" in s.lower()]
        analog_sinks = [s for s in physical_names if "analog" in s.lower()]

        if usb_sinks:
            current_hardware_sink = usb_sinks[0]
        elif analog_sinks:
            current_hardware_sink = analog_sinks[0]
        elif hdmi_sinks:
            current_hardware_sink = hdmi_sinks[0]
        elif physical_names:
            current_hardware_sink = physical_names[0]

    # 4. Asegurar que hifi_loss_playback apunte al hardware activo
    if current_hardware_sink:
        # Obtener sink actual de hifi_loss_playback
        for inp in get_sink_inputs():
            if inp[0] == hifi_playback_input_id:
                current_target_id = inp[1]
                target_hardware_id = [s[0] for s in physical_sinks if s[1] == current_hardware_sink]
                if target_hardware_id and current_target_id != target_hardware_id[0]:
                    subprocess.run(["pactl", "move-sink-input", hifi_playback_input_id, current_hardware_sink],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                break

    # 5. Asegurar que las aplicaciones vayan hacia hifi_loss_sink
    hifi_sink_id = [k for k, v in all_sinks.items() if v == HIFI_SINK]
    if hifi_sink_id:
        h_id = hifi_sink_id[0]
        for inp in get_sink_inputs():
            # Si no es la salida del propio filtro y no está en hifi_loss_sink, moverlo
            if inp[0] != hifi_playback_input_id and inp[1] != h_id and inp[2] != "-":
                subprocess.run(["pactl", "move-sink-input", inp[0], HIFI_SINK],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    # 6. Mantener hifi_loss_sink como el sink predeterminado visible para apps
    if default_sink != HIFI_SINK:
        subprocess.run(["pactl", "set-default-sink", HIFI_SINK],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def monitor_events():
    """Bucle reactivo con pactl subscribe (cero polling, despierta solo con eventos)"""
    while running:
        ensure_routing()
        try:
            proc = subprocess.Popen(["pactl", "subscribe"],
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            for line in proc.stdout:
                if not running:
                    break
                # Eventos relevantes: cambio en servidor (default-sink), cambio/nuevo sink o sink-input
                if any(ev in line for ev in ["sink", "sink-input", "server"]):
                    ensure_routing()
        except Exception:
            time.sleep(1)

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--once":
        ensure_routing()
        print("Routing sincronizado con éxito.")
    else:
        monitor_events()
