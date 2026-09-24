"""
analyze_crossfeed.py - Caracterización de Crossfeed, Separación L/R y Espacialización Binaural.
"""

import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from scipy.signal import correlate
import os
import json

from stimuli import generate_crossfeed_stimulus
from capture import WasapiLoopbackCapturer

def run_crossfeed_analysis(fs=48000):
    os.makedirs('measurements/plots', exist_ok=True)
    os.makedirs('measurements/results', exist_ok=True)

    print("[Crossfeed] Generando estímulo de aislamiento L/R calibrado...")
    fs, stimulus = generate_crossfeed_stimulus(fs=fs)

    capturer = WasapiLoopbackCapturer()
    print("[Crossfeed] Reproduciendo y grabando por loopback WASAPI...")
    raw_rec, aligned_rec, delay = capturer.play_and_record(stimulus, fs=fs, extra_record_time=1.0)

    # Identificar las dos mitades del estímulo:
    # 1. Left activo, Right silencio (primer ~45% del tiempo de actividad)
    # 2. Right activo, Left silencio (segundo ~45%)
    stim_dur_samples = len(stimulus)
    half_samples = stim_dur_samples // 2
    
    # Segmento 1: Left activo (buscamos energía en L original)
    mask_left_active = np.abs(stimulus[:half_samples, 0]) > 0.05
    # Segmento 2: Right activo (buscamos energía en R original)
    mask_right_active = np.abs(stimulus[half_samples:, 1]) > 0.05

    # Señal capturada alineada correspondiente
    seg1_L = aligned_rec[:half_samples, 0]
    seg1_R = aligned_rec[:half_samples, 1]

    seg2_L = aligned_rec[half_samples:stim_dur_samples, 0]
    seg2_R = aligned_rec[half_samples:stim_dur_samples, 1]

    # 1. Medir Crosstalk global en dB
    rms_L_active = np.sqrt(np.mean(seg1_L[mask_left_active]**2))
    rms_R_leak = np.sqrt(np.mean(seg1_R[mask_left_active]**2))

    rms_R_active = np.sqrt(np.mean(seg2_R[mask_right_active]**2))
    rms_L_leak = np.sqrt(np.mean(seg2_L[mask_right_active]**2))

    crosstalk_R_from_L_db = 20.0 * np.log10(max(rms_R_leak, 1e-9) / max(rms_L_active, 1e-9))
    crosstalk_L_from_R_db = 20.0 * np.log10(max(rms_L_leak, 1e-9) / max(rms_R_active, 1e-9))
    crosstalk_avg_db = 0.5 * (crosstalk_R_from_L_db + crosstalk_L_from_R_db)

    # 2. Medir retardo interaural (ITD) durante la ráfaga
    # Correlación cruzada entre canal directo y canal fugado
    corr = correlate(seg1_L[mask_left_active], seg1_R[mask_left_active], mode='full')
    center_idx = len(seg1_R[mask_left_active]) - 1
    peak_idx = np.argmax(np.abs(corr))
    itd_samples = peak_idx - center_idx
    itd_ms = (itd_samples / fs) * 1000.0

    # 3. Crosstalk por frecuencia espectral (ráfagas a 250, 700, 2000, 6000 Hz)
    test_freqs = [250.0, 700.0, 2000.0, 6000.0]
    freq_leakage = []
    
    # Cada ráfaga dura aprox 0.3s y empieza en offset 0.1s + i*0.45s + silence pre (0.3s)
    for i, freq in enumerate(test_freqs):
        start_t = 0.3 + 0.1 + i * 0.45
        end_t = start_t + 0.3
        idx_start = int(fs * start_t)
        idx_end = int(fs * end_t)
        
        # Sub-ventana
        sub_L = seg1_L[idx_start:idx_end]
        sub_R = seg1_R[idx_start:idx_end]
        
        rms_prim = np.sqrt(np.mean(sub_L**2))
        rms_cross = np.sqrt(np.mean(sub_R**2))
        leak_db = 20.0 * np.log10(max(rms_cross, 1e-9) / max(rms_prim, 1e-9))
        
        freq_leakage.append({
            "frequency_hz": freq,
            "leakage_db": round(float(leak_db), 2),
            "rms_primary": round(float(rms_prim), 4),
            "rms_crosstalk": round(float(rms_cross), 6)
        })

    # 4. Matriz Mid / Side (M/S)
    mid = (aligned_rec[:, 0] + aligned_rec[:, 1]) / np.sqrt(2.0)
    side = (aligned_rec[:, 0] - aligned_rec[:, 1]) / np.sqrt(2.0)
    rms_mid = np.sqrt(np.mean(mid**2))
    rms_side = np.sqrt(np.mean(side**2))
    side_to_mid_ratio = rms_side / max(rms_mid, 1e-9)
    side_to_mid_db = 20.0 * np.log10(max(side_to_mid_ratio, 1e-9))

    results = {
        "crosstalk_avg_db": round(float(crosstalk_avg_db), 2),
        "crosstalk_R_from_L_db": round(float(crosstalk_R_from_L_db), 2),
        "crosstalk_L_from_R_db": round(float(crosstalk_L_from_R_db), 2),
        "itd_samples": int(itd_samples),
        "itd_ms": round(float(itd_ms), 3),
        "side_to_mid_ratio": round(float(side_to_mid_ratio), 3),
        "side_to_mid_db": round(float(side_to_mid_db), 2),
        "frequency_crosstalk": freq_leakage,
        "crossfeed_type": "None (Canales Aislados / Bit-Perfect)" if crosstalk_avg_db < -45.0 else ("Bauer/Simulado" if itd_ms > 0.1 else "Atenuación Simple")
    }

    with open('measurements/results/crossfeed_analysis.json', 'w') as jf:
        json.dump(results, jf, indent=2)

    # Gráficas
    t_plot = np.linspace(0, len(seg1_L)/fs, len(seg1_L))
    fig, axs = plt.subplots(2, 1, figsize=(10, 6), sharex=False)
    
    axs[0].plot(t_plot, seg1_L, label='Canal Directo L (Capturado)', color='tab:blue', alpha=0.8)
    axs[0].plot(t_plot, seg1_R, label='Canal Opuesto R (Crosstalk fugado)', color='tab:red', alpha=0.8)
    axs[0].set_title(f"Aislamiento de Canales L/R (Crosstalk global: {crosstalk_avg_db:.1f} dB)")
    axs[0].set_ylabel("Amplitud Lineal")
    axs[0].set_xlabel("Tiempo (s)")
    axs[0].legend(loc='upper right')
    axs[0].grid(True, alpha=0.3)

    freqs = [item['frequency_hz'] for item in freq_leakage]
    leaks = [item['leakage_db'] for item in freq_leakage]
    axs[1].bar([str(int(f)) + " Hz" for f in freqs], leaks, color='tab:purple', width=0.4)
    axs[1].axhline(-60, color='gray', linestyle=':', label='Límite de ruido/aislamiento perfecto (-60 dB)')
    axs[1].set_title("Nivel de Fuga Contralateral por Frecuencia")
    axs[1].set_ylabel("Crosstalk (dB)")
    axs[1].set_xlabel("Frecuencia de Prueba")
    axs[1].set_ylim(min(-80.0, min(leaks) - 10), 0)
    axs[1].legend(loc='lower right')
    axs[1].grid(True, alpha=0.3)

    plt.tight_layout()
    plt.savefig('measurements/plots/crossfeed_analysis.png', dpi=200)
    plt.close()

    print("[Crossfeed] Gráfica guardada en measurements/plots/crossfeed_analysis.png")
    print("[Crossfeed] Resultados guardados en measurements/results/crossfeed_analysis.json")
    return results

if __name__ == '__main__':
    res = run_crossfeed_analysis()
    print("\n--- RESULTADOS MEDICIÓN CROSSFEED Y ESPACIALIZACIÓN ---")
    print(f"Crosstalk promedio contralateral: {res['crosstalk_avg_db']} dB")
    print(f"Retardo interaural (ITD): {res['itd_ms']} ms ({res['itd_samples']} muestras)")
    print(f"Relación Side/Mid: {res['side_to_mid_ratio']} ({res['side_to_mid_db']} dB)")
    print(f"Diagnóstico: {res['crossfeed_type']}")
    print("Fugas por banda:")
    for f in res['frequency_crosstalk']:
        print(f"  {f['frequency_hz']:6.0f} Hz: {f['leakage_db']:+6.2f} dB")
