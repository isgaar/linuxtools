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
./instalar-apps.sh --browser-mpris# Parche multimedia para navegadores (timeline y posición en KDE Plasma)
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
  - **Perfil Maestro Fusión "hifi-loss" (Hi-Fi Lossless Studio Master)**:
    - **Fusión Acústica Total (Superando a Windows)**: Unifica lo mejor de la medición *black-box* de Windows (linealidad, techo de seguridad dinámico en $-0,14\text{ dBFS}$ contra *inter-sample clipping* y remuestreo sinc de fase lineal `quality = 14`), la espacialización tridimensional de Apple Spatial Audio y Dolby Atmos, y la calibración acústica de Fletcher-Munson / LoudnessCrystal.
    - **Cero intermediarios y Cero latencia (0 ms)**: Procesado en tiempo real en C/SPA mediante `libpipewire-module-filter-chain` directamente en el hilo de audio del kernel sin retraso ni consumo perceptible de CPU.
    - **Filtro Pasa-Altos Subsónico Butterworth (25 Hz, $Q=0.707$)**: Protege los transductores internos (NID `0x17`) y auriculares cortando el infrasonido inaudible ($<25\text{ Hz}$), evitando la sobre-excursión mecánica y distorsión por intermodulación (IMD) sin perder pegada sub-grave.
    - **Ecualizador Paramétrico de 10 Bandas de Precisión**: Curva de estudio equilibrada con realce controlado en sub-graves (32 Hz / 64 Hz), cortes quirúrgicos anti-caja plástica en 250 Hz y 500 Hz, presencia vocal frontal e inteligible en 1 kHz / 2 kHz, y extensión aérea sedosa en 14 kHz (*Air Band*).
    - **Espacialización Mid/Side y Crossfeed Binaural Bauer (700 Hz)**: Ensancha el campo estéreo fuera de la cabeza (+16% soundstage) y aplica filtrado contralateral para disipar la fatiga auditiva en auriculares sin alterar el centro vocal.
    - **Sumidero Maestro Dedicado (`hifi_loss_sink`)**: Expone un nodo `Audio/Sink` nativo con máxima prioridad (`priority.session = 1500`) para enrutamiento automático en WirePlumber.
  - **Perfil de Referencia Neutro Windows (`65-windows-reference-profile.conf`)**:
    - Para monitorización plana y comparativa, permite activar con `./setup_audio_hifi.sh -w` una cadena 1:1 directa (sin EQ ni crossfeed), con 100% de aislamiento L/R ($-170\text{ dB}$) y el techo medido de Windows ($-0,14\text{ dBFS}$).
  - **Parche de Pines HDA Realtek ALC623 (`alsa-realtek-alc623.fw`)**:
    - Corrige la conmutación de altavoces/auriculares y la baja ganancia de ALSA aplicando los descriptores OEM decodificados de Windows mediante `./setup_audio_hifi.sh -p` hacia `/lib/firmware/` y `/etc/modprobe.d/alsa-alc623-pins.conf`.
  - **Presets de Estudio EasyEffects (Opcional / Alternativo)**:
    - Perfiles para interfaz gráfica (`Dolby Atmos Spatial Studio`, `Dolby Atmos Convolver Studio`, `Apple Spatial Audio Studio` y `LoudnessCrystalEqualizer`).
  - **Diagnóstico y Rollback**: Monitor en vivo del reloj de hardware, sumideros y restauración limpia a los valores por defecto de Fedora.
- `fedora-tools/install_virtualbox.sh` automatiza la instalación y configuración
  completa de VirtualBox en Fedora Linux:
  - Habilita repositorios RPM Fusion (Free y Non-Free).
  - Instala dependencias del kernel y herramientas de construcción (`kernel-devel`, `akmods`, `gcc`, `make`).
  - Detección y soporte completo para UEFI Secure Boot mediante generación e importación de claves MOK (`kmodgenca` / `mokutil`).
  - Compilación y firma forzada de módulos (`akmods --rebuild`) para el kernel en ejecución.
  - Añade al usuario actual al grupo `vboxusers`.
  - Instalación opcional y automatizada del Oracle VM VirtualBox Extension Pack.
- `fedora-tools/setup_browser_mpris.sh` soluciona los problemas del widget **"Reproductor multimedia"** de KDE Plasma con navegadores web (Zen Browser, Firefox, Brave, Chrome):
  - **Causa resuelta**: El reproductor nativo de Firefox/Zen (`widget.mpris.enabled`) omite la duración (`mpris:length`) y mantiene la posición fija en `0`, provocando que el widget de KDE Plasma oculte la barra de progreso (timeline/seekbar) y no permita adelantar o atrasar el audio.
  - **Integración Nativa de Plasma**: Instala y enlaza `plasma-browser-integration` y `playerctl` en Fedora Linux.
  - **Soporte completo para Zen Browser y derivados**: Registra los manifiestos Native Messaging Hosts en `~/.config/zen`, `~/.mozilla` y `/opt/zen`, inyecta la extensión oficial de KDE Plasma y configura directivas empresariales (`policies.json`).
  - **Integración y compatibilidad multimedia en `user.js`**: Garantiza la operatividad del reproductor multimedia y cede el control dinámico a Plasma Browser Integration para habilitar la barra de tiempo, posición en vivo y el progreso de descargas en el panel de KDE Plasma.
  - **Soporte para Brave, Google Chrome y Chromium**: Registra manifiestos nativos y políticas para auto-instalación del complemento de KDE Plasma (`cimiefiiaegbelhefglklhhakcgmhkai`).
  - **Monitor y Diagnóstico en Vivo**: Inspecciona en tiempo real el bus de usuario MPRIS, metadatos (`xesam:title`, `xesam:artist`), duración formateada y posición actual.
  - **Reversión (Rollback)**: Permite restaurar limpiamente la configuración original de perfiles y políticas del sistema.
- `measurements/` y `TODO/WINDOWS_AUDIO_PROFILE.md`: Suite de medición acústica de caja negra (*black-box*) y reporte técnico exhaustivo para replicación y comparación objetiva entre Windows (Realtek ALC623) y Fedora Linux (PipeWire / ALSA). Incluye parche de pines HDA (`fedora-tools/alsa-realtek-alc623.fw`) y perfil neutro (`fedora-tools/pipewire/65-windows-reference-profile.conf`).

## Requisitos

Para los perfiles tarball: `curl`, `tar`, `find`, `grep`, `cut`, `uniq` y
`wc`. Las herramientas Gentoo verifican sus dependencias adicionales y, cuando
corresponde, las solicitan con Portage.

## Licencia

Software libre: puedes usarlo, modificarlo y distribuirlo.
