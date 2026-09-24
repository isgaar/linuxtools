"""
analyze_latency_jitter.py - Caracterización de Respuesta al Impulso (Reverb Tail/RT60), Latencia, Muestreo y Reloj/Jitter/THD+N.
"""

import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from scipy.signal import find_peaks
import os
import json

from stimuli import generate_dirac_pulse, generate_pure_tones
from capture import WasapiLoopbackCapturer

def run_latency_and_impulse_analysis(fs=48000):
    os.makedirs('measurements/plots', exist_ok=True)
    os.makedirs('measurements/results', exist_ok=True)

    print("[Latency/Impulse] Generando pulso Dirac calibrado (t=0.5s, amp=0.9)...")
    fs, stimulus = generate_dirac_pulse(fs=fs, duration=2.0, amplitude=0.9)

    capturer = WasapiLoopbackCapturer()
    print("[Latency/Impulse] Reproduciendo y grabando por loopback WASAPI...")
    raw_rec, aligned_rec, delay_samples = capturer.play_and_record(stimulus, fs=fs, extra_record_time=0.8)

    ref_mono = stimulus[:, 0]
    raw_mono = raw_rec[:, 0]

    # Encontrar posición del pico Dirac en el estímulo de referencia y en la grabación cruda
    ref_peak_idx = np.argmax(np.abs(ref_mono))
    ref_peak_time = ref_peak_idx / fs

    raw_peak_idx = np.argmax(np.abs(raw_mono))
    raw_peak_time = raw_peak_idx / fs

    roundtrip_latency_ms = (raw_peak_time - ref_peak_time) * 1000.0
    latency_samples = raw_peak_idx - ref_peak_idx

    # Análisis de Respuesta al Impulso y Cola de Reverberación (EDC Schroeder)
    # Extraer 300 ms posteriores al pico Dirac
    tail_len = int(fs * 0.3)
    ir_segment = raw_mono[raw_peak_idx : min(len(raw_mono), raw_peak_idx + tail_len)]
    
    # Normalizar IR
    ir_norm = ir_segment / max(np.max(np.abs(ir_segment)), 1e-9)
    ir_db = 20.0 * np.log10(np.maximum(np.abs(ir_norm), 1e-6))

    # Curva de Decaimiento de Energía (EDC de Schroeder)
    edc = np.flip(np.cumsum(np.flip(ir_segment**2)))
    edc_norm = edc / max(edc[0], 1e-12)
    edc_db = 10.0 * np.log10(np.maximum(edc_norm, 1e-6))

    # Medir decaimiento a -20 dB y -60 dB (RT60 extrapolado)
    idx_minus20 = np.where(edc_db <= -20.0)[0]
    if len(idx_minus20) > 0:
        t_minus20 = idx_minus20[0] / fs
        rt60_est_ms = t_minus20 * 3.0 * 1000.0 # T30/T20 extrapolado a RT60
    else:
        rt60_est_ms = (len(ir_segment) / fs) * 1000.0

    has_reverb_tail = rt60_est_ms > 25.0

    # Gráfica de Respuesta al Impulso
    t_ir_ms = np.linspace(0, len(ir_segment)/fs * 1000.0, len(ir_segment))
    fig, axs = plt.subplots(2, 1, figsize=(10, 6))

    axs[0].plot(t_ir_ms, ir_norm, color='tab:blue', linewidth=1.2)
    axs[0].set_title(f"Respuesta al Impulso (Pico unitario, Latencia loopback: {roundtrip_latency_ms:.2f} ms)")
    axs[0].set_xlabel("Tiempo relativo tras impulso (ms)")
    axs[0].set_ylabel("Amplitud Normalizada")
    axs[0].grid(True, alpha=0.3)

    axs[1].plot(t_ir_ms, edc_db, color='tab:red', linewidth=1.5, label='Curva Decaimiento Schroeder EDC (dB)')
    axs[1].axhline(-20, color='gray', linestyle=':', label='Nivel -20 dB')
    axs[1].axhline(-60, color='black', linestyle=':', label='Nivel -60 dB (Piso acústico)')
    axs[1].set_title(f"Decaimiento Acústico Schroeder (RT60 estimado: {rt60_est_ms:.1f} ms)")
    axs[1].set_xlabel("Tiempo (ms)")
    axs[1].set_ylabel("Energía (dB)")
    axs[1].set_ylim(-70, 5)
    axs[1].grid(True, alpha=0.3)
    axs[1].legend(loc='upper right')

    plt.tight_layout()
    plt.savefig('measurements/plots/impulse_response.png', dpi=200)
    plt.close()

    return {
        "roundtrip_latency_ms": round(float(roundtrip_latency_ms), 2),
        "latency_samples": int(latency_samples),
        "rt60_estimated_ms": round(float(rt60_est_ms), 2),
        "has_reverb_tail": bool(has_reverb_tail),
        "convolution_type": "Direct / No Reverb (Impulso Puro Dirac)" if not has_reverb_tail else "Active Convolution Reverb Tail"
    }

def run_thd_and_clock_analysis(fs=48000, test_freq=440.0):
    print(f"[THD/Clock] Evaluando tono puro a {test_freq} Hz para reloj, THD+N y aliasing...")
    fs, stimulus = generate_pure_tones(fs=fs, freq=test_freq, duration=2.5, amplitude=0.1) # -20 dBFS

    capturer = WasapiLoopbackCapturer()
    raw_rec, aligned_rec, _ = capturer.play_and_record(stimulus, fs=fs, extra_record_time=0.6)

    # Analizar segmento estable central de 1.0s
    rec_mono = aligned_rec[:, 0]
    start_idx = int(fs * 0.5)
    end_idx = start_idx + int(fs * 1.0)
    signal_cut = rec_mono[start_idx:end_idx]

    # Ventana Hann y FFT
    N = len(signal_cut)
    window = np.hanning(N)
    sig_w = signal_cut * window
    fft_vals = np.fft.rfft(sig_w)
    freqs = np.fft.rfftfreq(N, 1.0 / fs)
    mag_dbfs = 20.0 * np.log10(np.maximum(np.abs(fft_vals) * 2.0 / np.sum(window), 1e-12))

    # Identificar pico fundamental
    fund_idx = np.argmax(mag_dbfs)
    fund_freq = freqs[fund_idx]
    fund_power_db = mag_dbfs[fund_idx]
    fund_amp = np.abs(fft_vals[fund_idx])

    freq_drift_hz = fund_freq - test_freq

    # Identificar armónicos 2 a 5 para THD
    harmonic_powers = []
    for h in range(2, 6):
        h_freq = test_freq * h
        if h_freq < fs / 2.0:
            h_idx = np.argmin(np.abs(freqs - h_freq))
            # Buscar pico local en ventana de +- 5 bins
            local_idx = h_idx - 5 + np.argmax(mag_dbfs[max(0, h_idx - 5):min(len(mag_dbfs), h_idx + 6)])
            harmonic_powers.append(np.abs(fft_vals[local_idx])**2)

    thd_ratio = np.sqrt(np.sum(harmonic_powers)) / max(fund_amp, 1e-12)
    thd_percent = thd_ratio * 100.0
    thd_db = 20.0 * np.log10(max(thd_ratio, 1e-9))

    # Piso de ruido (excluyendo fundamental y primeros 5 armónicos)
    noise_mask = np.ones_like(freqs, dtype=bool)
    # Excluir fundamental
    noise_mask[max(0, fund_idx - 10):min(len(freqs), fund_idx + 11)] = False
    for h in range(2, 6):
        h_idx = np.argmin(np.abs(freqs - test_freq * h))
        noise_mask[max(0, h_idx - 5):min(len(freqs), h_idx + 6)] = False

    noise_floor_dbfs = np.median(mag_dbfs[noise_mask])

    # THD+N
    total_power = np.sum(np.abs(fft_vals)**2)
    fund_power = fund_amp**2
    thdn_ratio = np.sqrt(max(0, total_power - fund_power)) / max(fund_amp, 1e-12)
    thdn_db = 20.0 * np.log10(max(thdn_ratio, 1e-9))

    # Gráfica espectral
    plt.figure(figsize=(10, 5))
    plt.semilogx(freqs, mag_dbfs, color='tab:blue', linewidth=1.0, label='Espectro Capturado (dBFS)')
    plt.axvline(test_freq, color='tab:green', linestyle='--', alpha=0.7, label=f'Fundamental {test_freq} Hz ({fund_power_db:.1f} dBFS)')
    plt.axhline(noise_floor_dbfs, color='tab:gray', linestyle=':', label=f'Piso de Ruido Mediano ({noise_floor_dbfs:.1f} dBFS)')
    plt.title(f"Espectro FFT Tono Puro {test_freq} Hz (THD: {thd_percent:.4f}%, THD+N: {thdn_db:.1f} dB)")
    plt.xlabel("Frecuencia (Hz)")
    plt.ylabel("Amplitud (dBFS)")
    plt.xlim(20, 24000)
    plt.ylim(-140, 0)
    plt.grid(True, which="both", alpha=0.3)
    plt.legend(loc='upper right')
    plt.tight_layout()
    plt.savefig(f'measurements/plots/spectrum_{int(test_freq)}hz.png', dpi=200)
    plt.close()

    return {
        "test_freq_hz": test_freq,
        "measured_freq_hz": round(float(fund_freq), 2),
        "freq_drift_hz": round(float(freq_drift_hz), 3),
        "fundamental_level_dbfs": round(float(fund_power_db), 2),
        "thd_percent": round(float(thd_percent), 5),
        "thd_db": round(float(thd_db), 2),
        "thdn_db": round(float(thdn_db), 2),
        "noise_floor_dbfs": round(float(noise_floor_dbfs), 2),
        "clock_stability": "Perfect Lock (0 Hz drift)" if abs(freq_drift_hz) < 0.1 else f"Drift {freq_drift_hz:+.2f} Hz"
    }

def run_latency_jitter_suite():
    ir_res = run_latency_and_impulse_analysis(fs=48000)
    thd440 = run_thd_and_clock_analysis(fs=48000, test_freq=440.0)
    thd1k = run_thd_and_clock_analysis(fs=48000, test_freq=1000.0)

    combined = {
        "impulse_and_latency": ir_res,
        "clock_thd_440hz": thd440,
        "clock_thd_1000hz": thd1k
    }

    with open('measurements/results/latency_jitter.json', 'w') as jf:
        json.dump(combined, jf, indent=2)

    print("\n--- RESULTADOS LATENCIA, IMPULSO Y RELOJ/THD ---")
    print(f"Latencia loopback total:  {ir_res['roundtrip_latency_ms']} ms ({ir_res['latency_samples']} muestras)")
    print(f"RT60 cola convolución:    {ir_res['rt60_estimated_ms']} ms ({ir_res['convolution_type']})")
    print(f"Tono 440 Hz -> Medido:    {thd440['measured_freq_hz']} Hz (Deriva: {thd440['freq_drift_hz']} Hz)")
    print(f"  THD a 440 Hz:           {thd440['thd_percent']}% ({thd440['thd_db']} dB)")
    print(f"  THD+N a 440 Hz:         {thd440['thdn_db']} dB (Piso ruido: {thd440['noise_floor_dbfs']} dBFS)")
    print(f"Tono 1000 Hz -> Medido:   {thd1k['measured_freq_hz']} Hz (Deriva: {thd1k['freq_drift_hz']} Hz)")
    print(f"  THD a 1000 Hz:          {thd1k['thd_percent']}% ({thd1k['thd_db']} dB)")
    print(f"  THD+N a 1000 Hz:        {thd1k['thdn_db']} dB (Piso ruido: {thd1k['noise_floor_dbfs']} dBFS)")
    return combined

if __name__ == '__main__':
    run_latency_jitter_suite()
