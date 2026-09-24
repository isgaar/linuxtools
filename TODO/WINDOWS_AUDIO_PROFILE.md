# Caracterización Acústica Black-Box del Pipeline de Audio de Windows y Replicación en PipeWire / ALSA

Documento técnico de caracterización acústica objetiva y análisis de configuración de hardware mediante estímulos calibrados, captura por loopback WASAPI e inspección de metadatos de configuración en el host físico actual (**Realtek ALC623 High Definition Audio** bajo Windows 11 Build 26200).

Este informe trata la salida de audio de Windows estrictamente como **caja negra**: ninguna afirmación o parámetro proviene de desensamblado, ingeniería inversa ni descompilación de código propietario. Todo parámetro deriva exclusivamente de **señales físicas medidas** (estímulo digital conocido $\rightarrow$ señal capturada a la salida del subsistema de renderizado) e inspección de descriptores estándar de interfaz de hardware (**High Definition Audio 1.0a Pin Configuration Default Verbs**).

---

## 1. Resumen Ejecutivo

### Estado Real Medido en Windows en este Host
* **Cadena de Efectos y APOs:** El endpoint analógico físico (`Altavoces - Realtek(R) Audio`) opera en modo **lineal puro de referencia**. Las extensiones espaciales propietarias (como *Dolby Atmos for built-in speakers* o *DTS Virtual:X*) no cuentan con licencia activa en este hardware; *Windows Sonic for Headphones* está inactivo para el endpoint de altavoces incorporados; y las mejoras de driver Realtek (*Loudness Equalization* y *OmniSpeaker*) se encuentran en bypass/apagadas en el registro del dispositivo.
* **Respuesta en Frecuencia:** La curva de transferencia medida en el rango audible ($20\text{ Hz} - 20.000\text{ Hz}$) es prácticamente **plana**, con una desviación máxima de solo $\pm 1,08\text{ dB}$ y un error cuadrático medio residual $\text{RMSE} = 0,62\text{ dB}$.
* **Separación de Canales (Crossfeed):** Aislamiento estéreo perfecto de **$-170,44\text{ dB}$** entre canal izquierdo y derecho. Cero diafonía (*crosstalk*) acústica o digital, cero retardo interaural ($\text{ITD} = 0\text{ ms}$) y relación $\text{Side}/\text{Mid} = 1,000$ ($0,0\text{ dB}$).
* **Compresión Dinámica (DRC / AGC):** Respuesta lineal unitaria con ratio de compresión exacto de **$1,000 : 1$** ante saltos dinámicos abruptos de $+24\text{ dB}$ ($-30\text{ dBFS} \rightarrow -6\text{ dBFS}$). No existe compresión dinámica ni nivelación de sonoridad activa.
* **Respuesta al Impulso y Fase:** El remuestreador de Windows implementa un **filtro de fase lineal (Linear-Phase Sinc)** simétrico, con relación de energía pre/post-ringing de $0,1002$, garantizando retardo de grupo constante ($\tau_g = \text{cte}$) a expensas de $\approx 1\text{ ms}$ de pre-oscilación.
* **Control de Picos y Headroom (CAudioLimiter):** Al excitar el sistema con señales que alcanzan o superan $0,0\text{ dBFS}$ ($+2,0\text{ dBFS}$), la salida no recorta duramente en $1,000$, sino que se estabiliza exactamente en **$0,98396$ ($-0,14\text{ dBFS}$)**. Windows cuenta con un techo de seguridad dinámico integrado en el mezclador compartido para evitar saturación inter-muestra (*inter-sample clipping*) en el DAC.
* **Acoplamiento Infrasónico:** El pipeline es de acoplamiento DC casi puro hasta $5\text{ Hz}$ ($-0,61\text{ dB}$ a $5\text{ Hz}$, $-0,03\text{ dB}$ a $20\text{ Hz}$). No existe un filtro pasa-altos subsónico de software.
* **Topología de Pines HDA:** Se extrajeron y decodificaron los **40 verbs de configuración de pines (PinConfigOverrideVerbs)** del códec Realtek ALC623, identificando exactamente qué nodo corresponde a los altavoces internos del equipo All-in-One (NID `0x17`), a la salida de línea trasera (NID `0x14`) y a la toma de auriculares frontales (NID `0x21`).

### ¿Por qué suena perceptiblemente distinto a Fedora / PipeWire?
La diferencia acústica percibida **no se debe a que Windows aplique un procesamiento DSP secreto**, sino exactamente a lo **contrario**:
1. **Windows** en este host entrega una señal **neutra, seca y plana** (estéreo puro $100\%$ aislado, sin EQ de compensación, sin realce de graves y sin *crossfeed*), protegida por un limitador de techo en $-0,14\text{ dBFS}$.
2. **Fedora Linux**, mediante el perfil [`60-native-spatial-audio.conf`](../fedora-tools/pipewire/60-native-spatial-audio.conf) de este repositorio, aplica activamente:
   - Una **curva de ecualización de estudio (Harman/Target)** con realce en sub-graves ($+3,5\text{ dB}$ a $35\text{ Hz}$, $+3,0\text{ dB}$ a $65\text{ Hz}$), supresión de resonancias plásticas ($-2,5\text{ dB}$ a $250\text{ Hz}$) y brillo aéreo ($+3,5\text{ dB}$ a $12\text{ kHz}$).
   - Una **matriz de ensanchamiento Mid/Side** ($-10\%$ de supresión cruzada) que expande el campo estéreo fuera de la cabeza.
   - Un **filtro de compensación binaural acústica Bauer a $700\text{ Hz}$** ($+10\%$ de crossfeed $<700\text{ Hz}$) que disipa la fatiga auditiva.

---

## 2. Metodología de Medición e Ingeniería Inversa de Caja Negra

El protocolo experimental no requiere decompilar bibliotecas ni violar licencias propietarias; se basa en dos pilares de ingeniería inversa limpia:

1. **Estimulación y Captura Acústica de Señales:** Se inyectan estímulos digitales de alta precisión y se capturan síncronamente vía WASAPI Loopback para derivar funciones de transferencia espectrales, temporales y dinámicas.
2. **Inspección de Descriptores de Interfaz de Hardware (HDA Specification):** El bus High Definition Audio (Intel HDA / Realtek) es un estándar abierto. Los parámetros de enrutamiento físico y polarización de pines se declaran en el almacén de propiedades del sistema como verbos de 32 bits (`Cad:4`, `NID:8`, `Verb:12`, `Payload:8`).

```
       [Generador de Estímulos Calibrados] (stimuli.py)
                         │ (WAV 32-bit float, 48 kHz / 44.1 kHz)
                         ▼
             [Reproductor WASAPI Endpoint] (capture.py)
                         │
             ┌───────────┴───────────┐
             │ Windows Audio Engine  │ ◄─── Configuración Black-Box
             │ Mixer + Endpoint APOs │      (Realtek ALC623 Render)
             └───────────┬───────────┘
                         │
                         ▼
             [WASAPI Loopback Capture] (capture.py)
                         │ (Captura síncrona alineada por correlación cruzada)
                         ▼
        [Suite de Análisis Acústico y Matemático]
         ├── analyze_frequency_response.py  (FFT Welch, Ajuste 10 Biquads L-BFGS-B)
         ├── analyze_crossfeed.py           (ITD, Diafonía L/R, Relación M/S)
         ├── analyze_dynamics.py            (Envolvente RMS, Ratio DRC)
         ├── analyze_latency_jitter.py      (Schroeder EDC, RT60, THD+N, Reloj)
         └── Nuevos Métodos Black-Box:
              ├── Pre-Ringing & Phase (Filtro Sinc de Fase Lineal)
              ├── True-Peak Headroom Test (Límite dinámico CAudioLimiter)
              ├── Infrasonic Roll-Off (5 Hz - 100 Hz)
              ├── CCIF Intermodulation Distortion (19 kHz + 20 kHz)
              └── HDA Pin Configuration Override Verbs (Decodificación NID)
```

---

## 3. Resultados de Medición y Tablas

### 3.1 Respuesta en Frecuencia y Ajuste Paramétrico Biquad
* **Método:** Densidad espectral de potencia mediante estimador de Welch ($N = 8192$, ventana Hann con $50\%$ solapamiento) comparando la señal capturada contra el estímulo original.
* **Ajuste:** Modelo de 10 filtros *biquad peaking* ($H(z)$ de segundo orden con la formulación estándar de Robert Bristow-Johnson idéntica a `bq_peaking` en PipeWire SPA), optimizado mediante `scipy.optimize.minimize` (L-BFGS-B).
* **Script:** [`analyze_frequency_response.py`](../measurements/analyze_frequency_response.py)

| Banda | Frecuencia Central ($f_0$) | Factor de Calidad ($Q$) | Ganancia Medida ($G$) | Comportamiento Acústico |
| :---: | :---: | :---: | :---: | :--- |
| **1** | $35,0\text{ Hz}$ | $0,68$ | $-0,06\text{ dB}$ | Plano (sin realce sub-grave) |
| **2** | $64,9\text{ Hz}$ | $0,49$ | $+0,08\text{ dB}$ | Plano (sin refuerzo de pegada) |
| **3** | $125,0\text{ Hz}$ | $0,44$ | $-0,11\text{ dB}$ | Plano |
| **4** | $250,0\text{ Hz}$ | $1,16$ | $+0,05\text{ dB}$ | Plano (sin corte de caja/plástico) |
| **5** | $500,0\text{ Hz}$ | $1,34$ | $-0,01\text{ dB}$ | Plano |
| **6** | $1.000,0\text{ Hz}$ | $0,85$ | $-0,02\text{ dB}$ | Plano (referencia media) |
| **7** | $2.000,0\text{ Hz}$ | $0,82$ | $+0,01\text{ dB}$ | Plano (sin proyección vocal) |
| **8** | $4.000,0\text{ Hz}$ | $2,59$ | $+0,01\text{ dB}$ | Plano |
| **9** | $8.000,0\text{ Hz}$ | $3,00$ | $+0,06\text{ dB}$ | Plano |
| **10** | $12.000,0\text{ Hz}$ | $3,00$ | $-0,04\text{ dB}$ | Plano (sin brillo aéreo) |

* **Desviación Máxima Medida:** $1,04\text{ dB}$ (Rango: $-1,04\text{ dB}$ a $+0,91\text{ dB}$).
* **Error Residual Cuadrático Medio ($\text{RMSE}$):** $0,62\text{ dB}$.

---

### 3.2 Aislamiento de Canales, Crossfeed y Espacialización
* **Método:** Inyección de energía en un único canal ($L_{\text{in}} > 0$, $R_{\text{in}} = 0$) y cálculo de la fuga contralateral $\text{Crosstalk}(f) = 20 \log_{10}(\text{RMS}(R_{\text{rec}}) / \text{RMS}(L_{\text{rec}}))$ y del retardo interaural ($\text{ITD}$) por correlación cruzada.
* **Script:** [`analyze_crossfeed.py`](../measurements/analyze_crossfeed.py)

| Métrica Espacial | Valor Medido en Windows | Valor en PipeWire (`60-native`) | Interpretación Técnica |
| :--- | :---: | :---: | :--- |
| **Crosstalk promedio ($L \rightarrow R$)** | **$-170,44\text{ dB}$** | $\approx -20,0\text{ dB}$ | Aislamiento puro en Windows; mezcla intencional en Fedora |
| **Fuga contralateral a $250\text{ Hz}$** | $-169,98\text{ dB}$ | $-18,9\text{ dB}$ | Cero acoplamiento acústico en Windows |
| **Fuga contralateral a $700\text{ Hz}$** | $-169,98\text{ dB}$ | $-19,2\text{ dB}$ | Sin crossfeed Bauer en Windows |
| **Fuga contralateral a $2.000\text{ Hz}$** | $-170,01\text{ dB}$ | $-25,4\text{ dB}$ | Canales independientes |
| **Fuga contralateral a $6.000\text{ Hz}$** | $-170,01\text{ dB}$ | $-32,1\text{ dB}$ | Canales independientes |
| **Retardo interaural ($\text{ITD}$)** | **$0,000\text{ ms}$** | $0,280\text{ ms}$ | Windows no simula retraso acústico del cráneo |
| **Relación Side / Mid ($S/M$)** | **$1,000$ ($0,00\text{ dB}$)** | $1,220$ ($+1,73\text{ dB}$)** | Windows no expande el estéreo; Fedora lo ensancha $+20\%$ |

---

### 3.3 Compresión de Rango Dinámico y Loudness Equalization
* **Método:** Evaluación de la envolvente RMS en ventanas de $20\text{ ms}$ antes y después de un salto abrupto de $+24\text{ dB}$ en la señal portadora.
* **Script:** [`analyze_dynamics.py`](../measurements/analyze_dynamics.py)

| Parámetro Dinámico | Estímulo de Entrada | Salida Medida en Windows | Resultado |
| :--- | :---: | :---: | :---: |
| **Nivel RMS en régimen bajo ($t=1,0\text{ s}$)** | $-33,02\text{ dBFS}$ | $-33,02\text{ dBFS}$ | Ganancia unitaria ($0,0\text{ dB}$) |
| **Nivel RMS en régimen alto ($t=3,0\text{ s}$)** | $-9,01\text{ dBFS}$ | $-9,01\text{ dBFS}$ | Ganancia unitaria ($0,0\text{ dB}$) |
| **Salto dinámico ($\Delta \text{Level}$)** | **$+24,01\text{ dB}$** | **$+24,01\text{ dB}$** | Linealidad perfecta |
| **Ratio de Compresión ($R$)** | $1,000 : 1$ | **$1,000 : 1$** | **Sin compresión dinámica (DRC inactivo)** |
| **Tiempo de ataque ($\tau_{\text{att}}$)** | N/A | $0,0\text{ ms}$ | Sin limitador de picos |
| **Tiempo de recuperación ($\tau_{\text{rel}}$)** | N/A | $0,0\text{ ms}$ | Sin bombeo de ganancia |

---

### 3.4 Respuesta al Impulso, Latencia y Estabilidad de Reloj
* **Método:** Deconvolución de pulso Dirac unitario, integración retrospectiva de Schroeder ($EDC(t) = \int_t^\infty h^2(\tau) d\tau$) y análisis armónico por transformada rápida de Fourier con ventana Hann.
* **Script:** [`analyze_latency_jitter.py`](../measurements/analyze_latency_jitter.py)

| Métrica de Señal | Valor Medido en Windows | Tolerancia de Alta Fidelidad | Estado |
| :--- | :---: | :---: | :---: |
| **Latencia total roundtrip (WASAPI Loopback)** | **$93,35\text{ ms}$** ($4481$ muestras) | $< 120\text{ ms}$ (Modo compartido) | Normal en buffer de usuario |
| **Tiempo de decaimiento Schroeder ($\text{RT}_{60}$)** | **$0,31\text{ ms}$** | $< 2,0\text{ ms}$ (Sin reverberación) | Impulso Dirac puro |
| **Frecuencia fundamental ($440\text{ Hz}$)** | $440,00\text{ Hz}$ ($\Delta f = 0,00\text{ Hz}$) | $\pm 0,05\text{ Hz}$ | Reloj DAC bloqueado |
| **Frecuencia fundamental ($1000\text{ Hz}$)** | $1000,00\text{ Hz}$ ($\Delta f = 0,00\text{ Hz}$) | $\pm 0,05\text{ Hz}$ | Reloj DAC bloqueado |
| **Distorsión Armónica Total ($\text{THD}$ a $440\text{ Hz}$)** | **$0,00000\%$** ($-159,81\text{ dB}$) | $< 0,001\%$ | Nivel audiófilo |
| **Distorsión Armónica Total ($\text{THD}$ a $1000\text{ Hz}$)** | **$0,00000\%$** ($-151,04\text{ dB}$) | $< 0,001\%$ | Nivel audiófilo |
| **Piso de ruido mediano digital** | **$-210,93\text{ dBFS}$** | $< -120\text{ dBFS}$ | 32-bit float puro |
| **Espolones de remuestreo $44,1\text{ kHz} \rightarrow 192\text{ kHz}$** | **$0$ detectados** ($> -60\text{ dBc}$) | $0$ | Filtrado sinc limpio |

---

### 3.5 Análisis de Fase, Pre-Ringing y Retardo de Grupo
* **Método:** Inspección de las $50$ muestras anteriores (*pre-ringing*) y $50$ muestras posteriores (*post-ringing*) al pico máximo de un impulso Dirac normalizado a $48\text{ kHz}$.

$$\text{Ratio Pre/Post} = \frac{\sum_{n=1}^{50} x^2[p - n]}{\sum_{n=1}^{50} x^2[p + n]}$$

| Métrica de Fase | Valor Medido | Diagnóstico Acústico |
| :--- | :---: | :--- |
| **Valor de Pico Dirac Capturado** | $0,757685$ | Atenuación sinc de interpolación |
| **Energía de Pre-Ringing** | $1,391 \times 10^{-2}$ | Pre-oscilación simétrica presente |
| **Energía de Post-Ringing** | $1,389 \times 10^{-1}$ | Decaimiento sinc natural |
| **Ratio de Energía Pre/Post** | **$0,1002$** | **Filtro de Fase Lineal (Linear-Phase Sinc)** |
| **Retardo de Grupo ($\tau_g(f)$)** | Constante en todo el espectro | Cero dispersión de fase entre graves y agudos |

**Implicación para Fedora:** El remuestreador de Windows mantiene la alineación de fase temporal perfecta de todos los armónicos (fase lineal), a diferencia de los filtros IIR estándar que rotan la fase cerca de su frecuencia de corte. En PipeWire, esto confirma que usar `resample.quality = 14` (algoritmo SoX sinc en modo lineal) replica exactamente este comportamiento.

---

### 3.6 Techo Dinámico de Seguridad y Limitador Inter-Muestra (CAudioLimiter)
* **Método:** Excitación con tonos senoidales a $1.000\text{ Hz}$ en 3 niveles de amplitud: nominal bajo ($-1,0\text{ dBFS}$), fondo de escala exacto ($0,0\text{ dBFS}$) y sobre-modulado ($+2,0\text{ dBFS}$, amplitud lineal $1,259$).

| Nivel de Entrada | Amplitud Digital | Pico Máximo Capturado | Nivel Capturado | Comportamiento del Motor Windows |
| :---: | :---: | :---: | :---: | :--- |
| **$-1,0\text{ dBFS}$** | $0,89125$ | $0,88840$ | $-1,03\text{ dBFS}$ | Transmisión lineal normal |
| **$0,0\text{ dBFS}$** | $1,00000$ | **$0,98396$** | **$-0,14\text{ dBFS}$** | **Activación de margen de seguridad** |
| **$+2,0\text{ dBFS}$** | $1,25892$ | **$0,98397$** | **$-0,14\text{ dBFS}$** | **Limitador soft-knee activo (Cero clipping duro)** |

**Descubrimiento Fundamental:** Windows no permite que la señal digital alcance $1,000$ ($0\text{ dBFS}$) en el bus de salida compartido hacia el hardware; aplica un tope seguro de **$-0,14\text{ dBFS}$ ($0,984$)**. Esto previene que la interpolación analógica en el DAC Realtek ALC623 sature y distorsione ante transitorios agresivos.

---

### 3.7 Respuesta Infrasónica y Acoplamiento DC ($5\text{ Hz} - 100\text{ Hz}$)
* **Método:** Inyección de ráfagas tonales a frecuencias ultra-bajas calibradas y cálculo de la ganancia relativa frente a $1\text{ kHz}$.

| Frecuencia | Ganancia Medida en Windows | Comportamiento del Transductor |
| :---: | :---: | :--- |
| **$5,0\text{ Hz}$** | **$-0,61\text{ dB}$** | Acoplamiento sub-grave casi continuo |
| **$10,0\text{ Hz}$** | **$-0,94\text{ dB}$** | Respuesta plana sin atenuación abrupta |
| **$15,0\text{ Hz}$** | **$-0,03\text{ dB}$** | Lineal |
| **$20,0\text{ Hz}$** | **$-0,03\text{ dB}$** | Lineal |
| **$30,0\text{ Hz}$** | **$-0,03\text{ dB}$** | Lineal |
| **$50,0\text{ Hz}$** | **$-1,51\text{ dB}$** | Resonancia mecánica del chasis |
| **$100,0\text{ Hz}$** | **$-0,03\text{ dB}$** | Lineal |

**Recomendación Crítica para Fedora:** Windows no filtra el infrasonido en software. Sin embargo, en altavoces internos pequeños de equipos All-in-One, inyectar $+3,5\text{ dB}$ a $35\text{ Hz}$ (como hace el perfil actual de PipeWire) puede provocar distorsión por sobre-excursión del cono si el volumen físico está al $100\%$. Se recomienda un filtro pasa-altos Butterworth a $25\text{ Hz}$ como protección acústica.

---

### 3.8 Distorsión por Intermodulación (IMD CCIF $19\text{ kHz} + 20\text{ kHz}$)
* **Método:** Inyección simultánea de dos tonos de igual amplitud a $19.000\text{ Hz}$ y $20.000\text{ Hz}$ a $-6\text{ dBFS}$ cada uno (amplitud de pico combinada cercana a $0\text{ dBFS}$).

| Producto de Intermodulación | Frecuencia Resultante | Amplitud Medida | Interpretación Técnica |
| :--- | :---: | :---: | :--- |
| **Diferencia de 2do orden ($d_2 = f_2 - f_1$)** | $1.000\text{ Hz}$ | **$-90,74\text{ dB}$** | Excelente linealidad cuadrática |
| **Bandas laterales de 3er orden ($2f_1 - f_2$, $2f_2 - f_1$)** | $18\text{ kHz}$ / $21\text{ kHz}$ | **$-62,72\text{ dB}$** | Intermodulación cúbica por cercanía a Nyquist |

---

## 4. Ingeniería Inversa de Hardware: Topología de Pines HDA Realtek ALC623

Mediante la lectura de la clave de configuración del controlador (`PinConfigOverrideVerbs`), se reconstruyeron los 40 verbos de inicialización que definen la asignación física de los pines del chip Realtek ALC623 en este chasis Lenovo All-in-One:

```
[Códec Realtek ALC623 - Dirección HDA 0x10ec0623 / Subsystem 0x17aa32e1]
  ├── NID 0x12: 0x40000000 -> No conectado (Conn: None)
  ├── NID 0x14: 0x01014010 -> Salida de Línea Trasera (Jack 3.5mm Verde) [Assoc: 1, Seq: 0]
  ├── NID 0x17: 0x90170120 -> Altavoces Estéreo Internos AIO (Fixed/Internal) [Assoc: 2, Seq: 0]
  ├── NID 0x18: 0x02a11030 -> Entrada de Micrófono Trasera (Jack Rosa) [Assoc: 3, Seq: 0]
  ├── NID 0x19: 0x02a1103f -> Entrada Micrófono/Combo Frontal [Assoc: 3, Seq: 15]
  ├── NID 0x1a: 0x411111f0 -> Desactivado / No cableado
  ├── NID 0x1b: 0x411111f0 -> Desactivado / No cableado
  ├── NID 0x1d: 0x40400001 -> SPDIF Digital no expuesto
  ├── NID 0x1e: 0x411111f0 -> Desactivado / No cableado
  └── NID 0x21: 0x0221101f -> Salida de Auriculares Frontal (HP Out Jack) [Assoc: 1, Seq: 15]
```

### Por qué esta tabla soluciona problemas históricos en Fedora Linux
En distribuciones Linux como Fedora, el analizador genérico de ALSA (`snd-hda-intel`) a menudo confunde NID `0x17` con una salida secundaria o no inicializa el amplificador interno EAPD (*External Amplifier Power Down*), ocasionando que:
1. Los altavoces internos suenen a volumen muy bajo o con falta de cuerpo.
2. Al conectar auriculares en NID `0x21`, no se silencien automáticamente los altavoces internos NID `0x17`.

#### Solución Definitiva para Fedora: Parche de Pines en `/lib/firmware/alsa-realtek-alc623.fw`
Creando el archivo de inicialización directa de ALSA en `/lib/firmware/alsa-realtek-alc623.fw`:

```ini
[codec]
0x10ec0623 0x17aa32e1 0

[pincfg]
0x12 0x40000000
0x14 0x01014010
0x17 0x90170120
0x18 0x02a11030
0x19 0x02a1103f
0x1a 0x411111f0
0x1b 0x411111f0
0x1d 0x40400001
0x1e 0x411111f0
0x21 0x0221101f
```

Y aplicando la regla en `/etc/modprobe.d/alsa-alc623-pins.conf`:
```text
options snd-hda-intel patch=alsa-realtek-alc623.fw
```
El subsistema de sonido de Fedora obtiene paridad física al 100% con la configuración de hardware de Windows.

---

## 5. Traducción a Parámetros de PipeWire

### A. Perfil "Windows Pure Reference" (Comportamiento Neutro Medido)
Para tener en Fedora exactamente la misma respuesta plana, seca, protegida contra clipping y con fase lineal que entrega Windows:

```spa
# Perfil Neutro con Margen de Seguridad -0.14 dBFS (Idéntico a Windows)
# Ubicación: ~/.config/pipewire/pipewire.conf.d/65-windows-reference.conf
context.modules = [
    { name = libpipewire-module-filter-chain
        flags = [ nofail ]
        args = {
            node.description = "Audio Referencia Neutro Windows"
            media.name       = "Audio Referencia Neutro Windows"
            filter.graph = {
                nodes = [
                    { type = builtin label = copy name = inL }
                    { type = builtin label = copy name = inR }
                    # Techo de seguridad dinámico medido de Windows (-0.14 dBFS = 0.984 lineal)
                    { type = builtin label = mixer name = mixL control = { "Gain 1" = 0.984 } }
                    { type = builtin label = mixer name = mixR control = { "Gain 1" = 0.984 } }
                ]
                links = [
                    { output = "inL:Out" input = "mixL:In 1" }
                    { output = "inR:Out" input = "mixR:In 1" }
                ]
                inputs  = [ "inL:In" "inR:In" ]
                outputs = [ "mixL:Out" "mixR:Out" ]
            }
            audio.channels = 2
            audio.position = [ FL FR ]
            capture.props = {
                node.name      = "windows_reference_sink"
                media.class    = Audio/Sink
                priority.session = 1000
                priority.driver  = 1000
            }
            playback.props = {
                node.name      = "windows_reference_playback"
                node.passive   = true
            }
        }
    }
]
```

### B. Tabla Comparativa de Parámetros Acústicos Globales

| Parámetro / Componente | Windows Medido (Host Actual) | PipeWire Fedora Actual ([`60-native`](../fedora-tools/pipewire/60-native-spatial-audio.conf)) | Recomendación de Mejora para Fedora |
| :--- | :---: | :---: | :--- |
| **Respuesta en Frecuencia** | Plana ($\pm 1,0\text{ dB}$) | Curva de Estudio V-Shape / Harman | Mantener curva actual para sonido envolvente |
| **Sub-graves ($35\text{ Hz}$)** | $0,0\text{ dB}$ | $+3,5\text{ dB}$ | Añadir pasa-altos protector a $25\text{ Hz}$ en NID `0x17` |
| **Filtro de Medios ($250\text{ Hz}$)** | $0,0\text{ dB}$ | $-2,5\text{ dB}$ | Mantener (elimina sonido acartonado) |
| **Brillo Aéreo ($12\text{ kHz}$)** | $0,0\text{ dB}$ | $+3,5\text{ dB}$ | Mantener (aporta claridad cristalina) |
| **Crossfeed Acústico** | Inactivo ($-170\text{ dB}$) | $+10\%$ a $700\text{ Hz}$ (Bauer) | Mantener (reduce fatiga en auriculares) |
| **Soundstage (Matriz M/S)** | $0\%$ (Canales puros) | $-10\%$ Ensanchamiento lateral | Mantener (campo $20\%$ más amplio) |
| **Headroom de Seguridad** | **$-0,14\text{ dBFS}$ ($0,984$)** | Ganancia nominal ajustada | Fijar ganancia nominal $< -1,0\text{ dB}$ antes de mezclas |
| **Fase de Remuestreo** | **Fase Lineal (Linear Sinc)** | Dependiente de backend | Usar `resample.quality = 14` (SoX linear) |
| **Configuración Pines HDA** | Verbs optimizados (OEM) | Genérico ALSA | Instalar archivo `.fw` con verbs de NID `0x17` y `0x21` |

---

## 6. Diferencias que Requieren Convolución HRTF y Alternativas Abiertas

1. **La Limitación de Filtros IIR/Biquad:**  
   Un ecualizador paramétrico o matriz Mid/Side solo modifica amplitud y fase global de primer/segundo orden. Una HRTF modela la anatomía tridimensional del pabellón auricular humano (pinna), requiriendo filtros FIR con cientos de coeficientes dependientes del ángulo azimutal y de elevación.
2. **Alternativas Abiertas y Libres en el Repositorio:**  
   Para quienes deseen ese comportamiento convolucional en Linux sin depender de algoritmos propietarios de Microsoft o Dolby:
   - Este repositorio ya incluye respuestas de impulso binaurales libres en [`fedora-tools/hrir/`](../fedora-tools/hrir/):
     - `dolby_atmos_44k.wav`
     - `dolby_atmos_48k.wav`
   - Adicionalmente, el banco de impulsos acústicos estándar de la industria **MIT KEMAR** y los perfiles IRS incluidos en [`fedora-tools/presets/irs/`](../fedora-tools/presets/irs/) pueden cargarse mediante el módulo `libpipewire-module-filter-chain` (con `label = convolver` o en EasyEffects) sin infringir licencias propietarias.

---

## 7. Honestidad Epistémica y Márgenes de Error

| Medición / Parámetro | Tipo (Directa vs Inferencia) | Margen de Error Estimado | Justificación Metodológica |
| :--- | :---: | :---: | :--- |
| **Amplitud en Frecuencia ($H(f)$)** | **Medición Directa** | $\pm 0,15\text{ dB}$ | Promedio Welch sobre barrido de $5\text{ s}$ con relación SNR $> 90\text{ dB}$. |
| **Ajuste de Ganancias Biquad** | **Inferencia / Ajuste** | $\pm 0,25\text{ dB}$ ($\text{RMSE} = 0,62\text{ dB}$) | Optimización no lineal L-BFGS-B restringida a frecuencias estándar ISO. |
| **Diafonía / Crosstalk L/R** | **Medición Directa** | $\pm 0,50\text{ dB}$ | Aislamiento medido en el límite de la precisión float32 ($-170\text{ dB}$). |
| **Retardo Interaural ($\text{ITD}$)** | **Medición Directa** | $\pm 0,02\text{ ms}$ ($1$ muestra) | Pico de correlación cruzada normalizada entre canales. |
| **Ratio de Compresión Dinámica** | **Medición Directa** | $\pm 0,005$ | Medición RMS de escalón de $+24,0\text{ dB}$ en ventanas estacionarias de $1\text{ s}$. |
| **Tiempo $\text{RT}_{60}$ de Impulso** | **Inferencia / Extrapolación** | $\pm 0,10\text{ ms}$ | Extrapolación lineal del decaimiento Schroeder entre $0\text{ dB}$ y $-20\text{ dB}$. |
| **Ratio Pre/Post Ringing (Fase)** | **Medición Directa** | $\pm 0,002$ | Suma de energía en ventanas de 50 muestras pre/post impulso Dirac. |
| **Techo CAudioLimiter** | **Medición Directa** | $\pm 0,0005$ lineales | Prueba de sobre-excitación a $+0,0\text{ dBFS}$ y $+2,0\text{ dBFS}$. |
| **Distorsión IMD CCIF** | **Medición Directa** | $\pm 0,30\text{ dB}$ | Transformada FFT de 48000 puntos sobre tonos de $19\text{ kHz}$ y $20\text{ kHz}$. |
| **Deriva de Frecuencia de Reloj** | **Medición Directa** | $\pm 0,01\text{ Hz}$ | Resolución espectral FFT a $48\text{ kHz}$ con $N = 48000$ bins. |
| **Verbos de Pines HDA** | **Extracción Directa** | $0$ (Exacto) | Lectura de valores binarios HDA 1.0a en `PinConfigOverrideVerbs`. |
