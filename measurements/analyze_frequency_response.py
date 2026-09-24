"""
analyze_frequency_response.py - Caracterización de Respuesta en Frecuencia (Sweep acústico y ajuste Biquad IIR).
"""

import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from scipy.signal import welch
from scipy.optimize import minimize
import os
import json

from stimuli import generate_log_sine_sweep
from capture import WasapiLoopbackCapturer

def biquad_peaking_mag_db(f, f0, Q, gain_db, fs=48000):
    """
    Función de transferencia de magnitud en dB para un filtro biquad peaking (Robert Bristow-Johnson EQ Cookbook).
    Exactamente idéntico al 'bq_peaking' de PipeWire SPA.
    """
    w0 = 2.0 * np.pi * f0 / fs
    A = 10.0 ** (gain_db / 40.0)
    alpha = np.sin(w0) / (2.0 * Q)
    
    b0 = 1.0 + alpha * A
    b1 = -2.0 * np.cos(w0)
    b2 = 1.0 - alpha * A
    a0 = 1.0 + alpha / A
    a1 = -2.0 * np.cos(w0)
    a2 = 1.0 - alpha / A
    
    # Evaluar respuesta en frecuencia discreta en z = exp(j * 2 * pi * f / fs)
    w = 2.0 * np.pi * f / fs
    z = np.exp(-1j * w)
    z2 = np.exp(-2j * w)
    
    num = (b0 + b1 * z + b2 * z2) / a0
    den = (1.0 + (a1 / a0) * z + (a2 / a0) * z2)
    H = num / den
    return 20.0 * np.log10(np.maximum(np.abs(H), 1e-12))

def multi_biquad_response(f, params, fs=48000):
    """
    Suma de respuestas en dB de N filtros biquad peaking en cascada:
    params es un array [f0_1, Q_1, G_1, f0_2, Q_2, G_2, ...]
    """
    total_db = np.zeros_like(f)
    num_filters = len(params) // 3
    for i in range(num_filters):
        f0 = params[i * 3]
        Q = params[i * 3 + 1]
        G = params[i * 3 + 2]
        total_db += biquad_peaking_mag_db(f, f0, Q, G, fs=fs)
    return total_db

def run_frequency_response_analysis(fs=48000, duration=6.0):
    os.makedirs('measurements/plots', exist_ok=True)
    os.makedirs('measurements/results', exist_ok=True)

    print("[FreqResponse] Generando barrido senoidal logarítmico calibrado 20Hz-20kHz...")
    _, sweep = generate_log_sine_sweep(fs=fs, duration=duration, f_start=20.0, f_end=20000.0, amplitude=0.4)

    capturer = WasapiLoopbackCapturer()
    print("[FreqResponse] Reproduciendo y grabando por loopback WASAPI...")
    raw_rec, aligned_rec, delay = capturer.play_and_record(sweep, fs=fs)

    ref_L = sweep[:, 0]
    rec_L = aligned_rec[:, 0]
    rec_R = aligned_rec[:, 1]

    # Calcular PSD con Welch para relación espectral suave
    nperseg = 8192
    f_ref, P_ref = welch(ref_L, fs=fs, window='hann', nperseg=nperseg, noverlap=nperseg//2)
    f_rec_L, P_rec_L = welch(rec_L, fs=fs, window='hann', nperseg=nperseg, noverlap=nperseg//2)
    f_rec_R, P_rec_R = welch(rec_R, fs=fs, window='hann', nperseg=nperseg, noverlap=nperseg//2)

    # Filtrar rango audible 20 Hz - 20 kHz
    mask = (f_ref >= 20.0) & (f_ref <= 20000.0)
    f_eval = f_ref[mask]
    
    H_L_db = 10.0 * np.log10(np.maximum(P_rec_L[mask], 1e-12)) - 10.0 * np.log10(np.maximum(P_ref[mask], 1e-12))
    H_R_db = 10.0 * np.log10(np.maximum(P_rec_R[mask], 1e-12)) - 10.0 * np.log10(np.maximum(P_ref[mask], 1e-12))

    # Promedio entre canales
    H_avg_db = 0.5 * (H_L_db + H_R_db)

    # Ajuste de filtros Biquad Peaking paramétricos (modelo de 10 bandas como PipeWire)
    target_f0s = [35.0, 65.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 12000.0]
    initial_params = []
    bounds = []
    for f0 in target_f0s:
        # Estimar ganancia inicial aproximada en la frecuencia f0
        idx = np.argmin(np.abs(f_eval - f0))
        g_init = H_avg_db[idx]
        initial_params.extend([f0, 1.0, g_init])
        bounds.extend([(f0 * 0.8, f0 * 1.2), (0.4, 3.0), (-15.0, 15.0)])

    def loss_func(p):
        pred_db = multi_biquad_response(f_eval, p, fs=fs)
        # Ponderación acústica leve en rango de presencia 500Hz-8kHz
        weights = np.ones_like(f_eval)
        weights[(f_eval >= 300.0) & (f_eval <= 8000.0)] = 2.0
        return np.mean(weights * (pred_db - H_avg_db)**2)

    print("[FreqResponse] Ajustando curva a modelo de 10 biquads paramétricos (L-BFGS-B)...")
    res = minimize(loss_func, initial_params, bounds=bounds, method='L-BFGS-B')
    fitted_params = res.x
    fitted_curve_db = multi_biquad_response(f_eval, fitted_params, fs=fs)
    rmse = np.sqrt(np.mean((fitted_curve_db - H_avg_db)**2))

    # Formatear parámetros biquad en lista de diccionarios
    biquad_results = []
    num_filters = len(target_f0s)
    for i in range(num_filters):
        f0 = round(float(fitted_params[i * 3]), 1)
        Q = round(float(fitted_params[i * 3 + 1]), 2)
        gain = round(float(fitted_params[i * 3 + 2]), 2)
        biquad_results.append({
            "band": i + 1,
            "freq_hz": f0,
            "q": Q,
            "gain_db": gain
        })

    # Guardar resultados JSON
    results_payload = {
        "sample_rate": fs,
        "rmse_db": round(float(rmse), 3),
        "biquad_filters": biquad_results,
        "max_deviation_db": round(float(np.max(np.abs(H_avg_db))), 2),
        "min_gain_db": round(float(np.min(H_avg_db)), 2),
        "max_gain_db": round(float(np.max(H_avg_db)), 2)
    }
    with open('measurements/results/frequency_response.json', 'w') as jf:
        json.dump(results_payload, jf, indent=2)

    # Gráfica
    plt.figure(figsize=(10, 5))
    plt.semilogx(f_eval, H_L_db, label='Medición Canal L (dB)', color='tab:blue', alpha=0.6, linewidth=1.2)
    plt.semilogx(f_eval, H_R_db, label='Medición Canal R (dB)', color='tab:cyan', alpha=0.6, linewidth=1.2)
    plt.semilogx(f_eval, H_avg_db, label='Promedio Medido L/R (dB)', color='black', linewidth=1.8)
    plt.semilogx(f_eval, fitted_curve_db, label=f'Ajuste 10 Biquads (RMSE={rmse:.2f} dB)', color='tab:red', linestyle='--', linewidth=2.0)
    plt.axhline(0, color='gray', linestyle=':', alpha=0.7)
    plt.grid(True, which="both", ls="-", alpha=0.3)
    plt.xlim(20, 20000)
    plt.ylim(min(-10.0, np.min(H_avg_db) - 3), max(10.0, np.max(H_avg_db) + 3))
    plt.title("Respuesta en Frecuencia: Salida Windows (WASAPI Loopback) vs Estímulo Original")
    plt.xlabel("Frecuencia (Hz)")
    plt.ylabel("Magnitud Relativa (dB)")
    plt.legend(loc='best')
    plt.tight_layout()
    plot_path = 'measurements/plots/frequency_response.png'
    plt.savefig(plot_path, dpi=200)
    plt.close()
    print(f"[FreqResponse] Gráfica guardada en {plot_path}")
    print(f"[FreqResponse] Parámetros guardados en measurements/results/frequency_response.json")
    return results_payload

if __name__ == '__main__':
    res = run_frequency_response_analysis()
    print("\n--- RESULTADOS MEDICIÓN RESPUESTA EN FRECUENCIA ---")
    print(f"Desviación máxima: {res['max_deviation_db']} dB (Rango: {res['min_gain_db']} dB a {res['max_gain_db']} dB)")
    print(f"Error residual de ajuste (RMSE): {res['rmse_db']} dB")
    print("Filtros Biquad Peaking ajustados:")
    for b in res['biquad_filters']:
        print(f"  Banda {b['band']:2d}: {b['freq_hz']:7.1f} Hz | Q = {b['q']:.2f} | Ganancia = {b['gain_db']:+5.2f} dB")
