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
