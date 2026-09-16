# Tarzar

Tarzar (`tar` + `lanzar`) instala y registra aplicaciones distribuidas como
tarballs en GNU/Linux. Extrae en `/opt`, crea accesos `.desktop` y añade
lanzadores de terminal en `/usr/local/bin`.

![Menú actual de Tarzar](src/screenshot.png)

## Uso

```bash
chmod +x instalar-apps.sh
./instalar-apps.sh
```

El menú permite instalar o registrar Zen Browser, Antigravity IDE, VSCodium,
una aplicación tarball genérica o una carpeta ya presente en `/opt`.

También admite ejecución directa:

```bash
./instalar-apps.sh --zen          # Zen oficial desde tarball
./instalar-apps.sh --gentoo-tools # PCSX2 o Zen desde código fuente
./instalar-apps.sh --pcsx2
./instalar-apps.sh --zen-build
./instalar-apps.sh --virtualbox   # VirtualBox en Fedora (akmods y Secure Boot)
./instalar-apps.sh --audio-hifi   # Audio Hi-Fi / Bit-Perfect (192kHz/24bit, PipeWire)
./instalar-apps.sh --spatial      # Audio Espacial Nativo PipeWire (C/SPA, convolución HRIR, sin intermediarios)
./instalar-apps.sh --easyeffects  # Audio Espacial alternativo mediante EasyEffects (GUI dinámico)
./instalar-apps.sh --gamepad      # Parche mandos Bluetooth/XInput (Steam, Lutris, Proton)
./instalar-apps.sh --fedora-tools # Menú de herramientas para Fedora
```

## Herramientas Gentoo

- `gentoo-tools/pcsx2.sh` clona o actualiza PCSX2 en `~/Documentos/pcsx2`,
  lo compila y crea lanzadores solo para el usuario.
- `gentoo-tools/zen-browser.sh` clona Zen Browser en el directorio XDG de
  Descargas, lo compila con `--disable-necko-wifi`, lo empaqueta y lo instala
  en `/opt/zen`. El acceso de escritorio y el comando `zen-browser` apuntan a
  esa instalación.

La primera compilación de Zen requiere al menos 30 GB libres y puede tardar
varias horas. Usa `--clean` para limpiar sus artefactos generados o `--launch`
para abrirlo al finalizar.

## Herramientas Fedora

- `fedora-tools/setup_gamepad_patch.sh` soluciona la detección de mandos Bluetooth y USB (Sony DualShock 4 / DualSense, Xbox, etc.) en juegos de Steam, Lutris, Wine y Proton:
  - **Mapeo XInput forzado para mandos Sony (`PROTON_SONY_HIDRAW_XINPUT=1`)**: Evita que Wine/Proton oculte los mandos de PlayStation de la API XInput en juegos de Windows (como GTA San Andreas con GInput, GTA V, etc.).
  - **Integración con Lutris**: Inyecta automáticamente la variable de entorno en todos los juegos Wine/Proton registrados en Lutris y en el runner global.
  - **Persistencia en sesión de usuario**: Configura `~/.config/environment.d/99-gamepad.conf` e importa las variables en la sesión activa de systemd.
  - **Reglas del sistema y udev**: Verifica la instalación de `steam-devices` para permisos en `/dev/uinput` y `/dev/hidraw*`.
  - **Estabilidad Bluetooth para Xbox**: Desactiva ERTM (`disable_ertm=1`) en `/etc/modprobe.d/bluetooth-ertm.conf` para evitar desconexiones constantes.
  - **Carga de módulo de kernel**: Asegura la carga automática del módulo `uinput`.
  - **Diagnóstico y pruebas en vivo**: Muestra el estado de mandos Bluetooth, nodos evdev, hidraw, detección SDL2 y un monitor de respuesta de botones en tiempo real.
  - **Rollback**: Permite revertir todas las configuraciones de manera limpia a los valores originales.
- `fedora-tools/setup_audio_hifi.sh` configura el subsistema de audio en Fedora Linux para lograr **Alta Fidelidad Pura y Bit-Perfect** hasta el límite del hardware (DAC Realtek ALC623, USB-C y HDMI):
  - **Conmutación dinámica de frecuencias (Bit-Perfect)**: Admite de forma nativa `44.1 kHz`, `48.0 kHz`, `88.2 kHz`, `96.0 kHz`, `176.4 kHz` y `192.0 kHz` sin remuestreo forzado.
  - **Profundidad nativa de 24/32 bits (`S32LE`)**: Aprovecha el rango dinámico completo del hardware (>110 dB) en lugar del estándar recortado de 16 bits.
  - **Calidad de remuestreo audiófilo nivel 14 (`libsoxr`)**: Interpolación sinc de grado de estudio en caso de flujos concurrentes.
  - **Cero alteración digital**: Desactiva remezclas destructivas, pseudo-surround y normalizaciones automáticas; fija el volumen digital PCM de ALSA al 100% (0.00 dB).
  - **Eliminación de pops y latencia**: Desactiva el ahorro de energía agresivo en `snd_hda_intel` (`power_save=0`), manteniendo los osciladores del DAC activos.
  - **Prioridad en tiempo real**: Configura límites PAM (`rtprio 95`, `memlock unlimited`) para evitar cortes de audio (*xruns*).
  - **Bluetooth de alta definición**: Habilita SBC-XQ, prioridad LDAC (HQ 990 kbps forzado) y códecs `aptX`/`aptX HD` con RPM Fusion.
  - **Audio Espacial 100% Nativo en PipeWire (`libpipewire-module-filter-chain`)**:
    - **Cero intermediarios y Cero latencia (0 ms)**: Se ejecuta directamente en el hilo DSP en tiempo real en C/SPA de PipeWire. Sin demoras añadidas, sin desfases acústicos y sin consumir ciclos de CPU en aplicaciones de usuario como EasyEffects.
    - **Ecualizador Paramétrico de Estudio (10 Bandas)**: Curva calibrada de alta precisión con filtros biquad (`bq_peaking`) que refuerza sub-graves limpios (35 Hz / 65 Hz), elimina de raíz el sonido encajonado/hueco de plástico (cortes quirúrgicos en 250 Hz y 500 Hz), entrega máxima presencia vocal (2 kHz / 4 kHz) y apertura aérea cristalina (8 kHz / 12 kHz).
    - **Matriz de Espacialización Mid/Side y Compensación Binaural**: Ensanchamiento de escenario estéreo tridimensional (+20% amplitud fuera de la cabeza) y crossfeed contralateral a 700 Hz (Bauer) para disipar la fatiga auditiva sin afectar la inteligibilidad ni el centro de voces.
    - **Volumen Calibrado al 100% (Sin Pérdidas ni Doble Atenuación)**: Maximiza el sumidero de hardware físico y ajusta la ganancia nominal con margen de seguridad dinámico (+2.5 dB RMS de plenitud acústica, 0% clipping).
    - **Sumidero Nativo de Audio**: Expone un nodo `Audio/Sink` nativo (`spatial_audio_sink`) configurado automáticamente como salida predeterminada del sistema.
  - **Presets de Estudio EasyEffects (Opcional / Alternativo)**:
    - Para quienes prefieran ajuste visual dinámico por GUI, incluye perfiles como `Dolby Atmos Spatial Studio`, `Dolby Atmos Convolver Studio`, `Apple Spatial Audio Studio` y `LoudnessCrystalEqualizer`.
  - **Diagnóstico y Rollback**: Monitor en vivo del reloj de hardware, sumideros y restauración limpia a los valores por defecto de Fedora.
- `fedora-tools/install_virtualbox.sh` automatiza la instalación y configuración
  completa de VirtualBox en Fedora Linux:
  - Habilita repositorios RPM Fusion (Free y Non-Free).
  - Instala dependencias del kernel y herramientas de construcción (`kernel-devel`, `akmods`, `gcc`, `make`).
  - Detección y soporte completo para UEFI Secure Boot mediante generación e importación de claves MOK (`kmodgenca` / `mokutil`).
  - Compilación y firma forzada de módulos (`akmods --rebuild`) para el kernel en ejecución.
  - Añade al usuario actual al grupo `vboxusers`.
  - Instalación opcional y automatizada del Oracle VM VirtualBox Extension Pack.

## Requisitos

Para los perfiles tarball: `curl`, `tar`, `find`, `grep`, `cut`, `uniq` y
`wc`. Las herramientas Gentoo verifican sus dependencias adicionales y, cuando
corresponde, las solicitan con Portage.

## Licencia

Software libre: puedes usarlo, modificarlo y distribuirlo.
