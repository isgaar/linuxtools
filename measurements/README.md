# Suite de Medición Acústica y Replicación (Windows & Linux / PipeWire)

Herramientas para caracterización acústica de caja negra (*black-box*) y validación de perfiles DSP entre sistemas operativos.

## Estructura de la Suite

* `stimuli.py`: Generador de estímulos acústicos estándar calibrados (barrido senoidal logarítmico 20Hz-20kHz, pulsos Dirac, tonos puros 440Hz/1kHz, ráfagas de aislamiento L/R y saltos dinámicos).
* `capture.py`: Grabador y reproductor síncrono alineado temporalmente por correlación cruzada.
* `analyze_frequency_response.py`: Medición de respuesta en frecuencia (PSD Welch) y ajuste a 10 filtros biquad paramétricos.
* `analyze_crossfeed.py`: Medición de diafonía contralateral, retardo interaural (ITD) y relación Mid/Side.
* `analyze_dynamics.py`: Medición de envolvente RMS, compresión de rango dinámico y ratio DRC.
* `analyze_latency_jitter.py`: Decaimiento Schroeder (EDC/RT60), latencia roundtrip y pureza espectral THD+N.
* `plots/`: Gráficas generadas de las mediciones objetivas.
* `results/`: Resultados cuantitativos estructurados en formato JSON.

## Replicación en Fedora Linux / PipeWire

Para replicar el protocolo en Linux con PipeWire:

1. **Requisitos en Fedora:**
   ```bash
   sudo dnf install -y python3-numpy python3-scipy python3-matplotlib python3-sounddevice pipewire-utils
   ```

2. **Probar la salida de referencia neutra (Windows):**
   ```bash
   mkdir -p ~/.config/pipewire/pipewire.conf.d
   cp fedora-tools/pipewire/65-windows-reference-profile.conf ~/.config/pipewire/pipewire.conf.d/
   systemctl --user restart pipewire wireplumber
   ```

3. **Aplicar la configuración de hardware de pines ALSA (Realtek ALC623):**
   ```bash
   sudo cp fedora-tools/alsa-realtek-alc623.fw /lib/firmware/
   echo "options snd-hda-intel patch=alsa-realtek-alc623.fw" | sudo tee /etc/modprobe.d/alsa-alc623-pins.conf
   ```

4. **Ejecutar mediciones bajo PipeWire:**
   ```bash
   python3 measurements/analyze_frequency_response.py
   python3 measurements/analyze_crossfeed.py
   python3 measurements/analyze_dynamics.py
   python3 measurements/analyze_latency_jitter.py
   ```
