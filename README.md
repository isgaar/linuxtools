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

- `fedora-tools/setup_audio_hifi.sh` configura el subsistema de audio en Fedora Linux para lograr **Alta Fidelidad Pura y Bit-Perfect** hasta el límite del hardware (DAC Realtek ALC623 y HDMI):
  - **Conmutación dinámica de frecuencias (Bit-Perfect)**: Admite de forma nativa `44.1 kHz`, `48.0 kHz`, `88.2 kHz`, `96.0 kHz`, `176.4 kHz` y `192.0 kHz` sin remuestreo forzado.
  - **Profundidad nativa de 24/32 bits (`S32LE`)**: Aprovecha el rango dinámico completo del hardware (>110 dB) en lugar del estándar recortado de 16 bits.
  - **Calidad de remuestreo audiófilo nivel 14 (`libsoxr`)**: Interpolación sinc de grado de estudio en caso de flujos concurrentes.
  - **Cero alteración digital**: Desactiva remezclas destructivas, pseudo-surround y normalizaciones automáticas; fija el volumen digital PCM de ALSA al 100% (0.00 dB).
  - **Eliminación de pops y latencia**: Desactiva el ahorro de energía agresivo en `snd_hda_intel` (`power_save=0`), manteniendo los osciladores del DAC activos.
  - **Prioridad en tiempo real**: Configura límites PAM (`rtprio 95`, `memlock unlimited`) para evitar cortes de audio (*xruns*).
  - **Bluetooth de alta definición**: Habilita SBC-XQ, prioridad LDAC (HQ 990 kbps forzado) y códecs `aptX`/`aptX HD` con RPM Fusion.
  - **Suite DSP opcional**: Instalación de `EasyEffects` y plugins `LSP` para ecualización paramétrica y corrección acústica.
  - **Diagnóstico y Rollback**: Monitor en vivo del reloj de hardware y restauración limpia a los valores por defecto de Fedora.
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
