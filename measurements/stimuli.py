"""
stimuli.py - Generador de estímulos acústicos estándar para caracterización black-box.
Genera archivos WAV calibrados a 48000 Hz (y 44100 Hz), 24/32-bit float.
"""

import numpy as np
from scipy.io import wavfile
import os

FS_DEFAULT = 48000

def generate_log_sine_sweep(fs=FS_DEFAULT, duration=5.0, f_start=20.0, f_end=20000.0, amplitude=0.5):
    """
    Genera un barrido senoidal logarítmico calibrado con silencios de seguridad (headroom/tail).
    """
    t = np.linspace(0, duration, int(fs * duration), endpoint=False)
    # Frecuencia instantánea: f(t) = f_start * (f_end / f_start) ** (t / duration)
    # Fase: phi(t) = 2 * pi * f_start * duration / ln(f_end / f_start) * ((f_end / f_start)**(t / duration) - 1)
    K = (2.0 * np.pi * f_start * duration) / np.log(f_end / f_start)
    phi = K * ((f_end / f_start) ** (t / duration) - 1.0)
    sweep = amplitude * np.sin(phi)
    
    # Ventana Tukey para evitar transitorios en bordes
    t_fade = 0.05
    fade_len = int(fs * t_fade)
    fade_in = 0.5 * (1.0 - np.cos(np.linspace(0, np.pi, fade_len)))
    fade_out = 0.5 * (1.0 + np.cos(np.linspace(0, np.pi, fade_len)))
    sweep[:fade_len] *= fade_in
    sweep[-fade_len:] *= fade_out
    
    # Silencios de 0.5s al inicio y 1.0s al final
    silence_pre = np.zeros(int(fs * 0.5), dtype=np.float32)
    silence_post = np.zeros(int(fs * 1.0), dtype=np.float32)
    
    full_mono = np.concatenate([silence_pre, sweep.astype(np.float32), silence_post])
    stereo = np.column_stack([full_mono, full_mono])
    return fs, stereo

def generate_pure_tones(fs=FS_DEFAULT, freq=440.0, duration=3.0, amplitude=0.1): # -20 dBFS aprox
    """
    Tono puro para verificación de reloj, THD+N y aliasing.
    """
    t = np.linspace(0, duration, int(fs * duration), endpoint=False)
    tone = (amplitude * np.sin(2.0 * np.pi * freq * t)).astype(np.float32)
    
    silence_pre = np.zeros(int(fs * 0.2), dtype=np.float32)
    silence_post = np.zeros(int(fs * 0.3), dtype=np.float32)
    full = np.concatenate([silence_pre, tone, silence_post])
    return fs, np.column_stack([full, full])

def generate_dirac_pulse(fs=FS_DEFAULT, duration=2.0, amplitude=0.9):
    """
    Impulso unitario Dirac para respuesta al impulso, detección de colas de reverb y latencia.
    """
    total_samples = int(fs * duration)
    sig = np.zeros(total_samples, dtype=np.float32)
    # Impulso en el segundo 0.5
    idx = int(fs * 0.5)
    sig[idx] = amplitude
    return fs, np.column_stack([sig, sig])

def generate_crossfeed_stimulus(fs=FS_DEFAULT, duration=2.0, amplitude=0.5):
    """
    Estímulo aislado L/R: Canal L emite ráfagas de tonos y barrido, Canal R totalmente en silencio,
    y luego viceversa, para medir crosstalk / crossfeed / retraso interaural (ITD).
    """
    t = np.linspace(0, duration, int(fs * duration), endpoint=False)
    # Frecuencias clave de prueba: 250 Hz, 700 Hz, 1 kHz, 4 kHz
    tone_burst = np.zeros_like(t, dtype=np.float32)
    for i, freq in enumerate([250.0, 700.0, 2000.0, 6000.0]):
        sub_t = t[:int(fs * 0.3)]
        burst = amplitude * np.sin(2.0 * np.pi * freq * sub_t)
        burst_fade = int(fs * 0.02)
        burst[:burst_fade] *= np.linspace(0, 1, burst_fade)
        burst[-burst_fade:] *= np.linspace(1, 0, burst_fade)
        start_idx = int(fs * (0.1 + i * 0.45))
        tone_burst[start_idx:start_idx + len(burst)] = burst

    # Parte 1: Left activo, Right silencio
    left_only = np.column_stack([tone_burst, np.zeros_like(tone_burst)])
    # Parte 2: Right activo, Left silencio
    right_only = np.column_stack([np.zeros_like(tone_burst), tone_burst])
    
    silence = np.zeros((int(fs * 0.3), 2), dtype=np.float32)
    full = np.vstack([silence, left_only, silence, right_only, silence])
    return fs, full

def generate_dynamic_test(fs=FS_DEFAULT, duration=6.5):
    """
    Señal con saltos abruptos de dinámica (-30 dBFS -> -6 dBFS -> -30 dBFS)
    con silencio inicial para alineación cruzada exacta.
    """
    total_samples = int(fs * duration)
    t = np.linspace(0, duration, total_samples, endpoint=False)
    carrier = np.sin(2.0 * np.pi * 1000.0 * t).astype(np.float32)
    
    # Envolvente:
    # 0.0s - 0.5s: Silencio absoluto (alineación temporal exacta)
    # 0.5s - 2.0s: Nivel bajo (-30 dBFS -> amp ~ 0.0316)
    # 2.0s - 4.0s: Nivel alto (-6 dBFS -> amp ~ 0.501)
    # 4.0s - 5.5s: Nivel bajo (-30 dBFS -> amp ~ 0.0316)
    # 5.5s - 6.5s: Silencio
    env = np.zeros(total_samples, dtype=np.float32)
    idx_low1_start = int(fs * 0.5)
    idx_high_start = int(fs * 2.0)
    idx_high_end = int(fs * 4.0)
    idx_low2_end = int(fs * 5.5)

    env[idx_low1_start:idx_high_start] = 0.0316
    env[idx_high_start:idx_high_end] = 0.501
    env[idx_high_end:idx_low2_end] = 0.0316
    
    sig = (carrier * env).astype(np.float32)
    return fs, np.column_stack([sig, sig])

if __name__ == '__main__':
    out_dir = os.path.join(os.path.dirname(__file__), 'wav_stimuli')
    os.makedirs(out_dir, exist_ok=True)
    
    print("Generando estímulos...")
    fs, sweep = generate_log_sine_sweep()
    wavfile.write(os.path.join(out_dir, 'sweep_48k.wav'), fs, sweep)
    
    fs, tone440 = generate_pure_tones(freq=440.0)
    wavfile.write(os.path.join(out_dir, 'tone_440_48k.wav'), fs, tone440)
    
    fs, tone1k = generate_pure_tones(freq=1000.0)
    wavfile.write(os.path.join(out_dir, 'tone_1k_48k.wav'), fs, tone1k)
    
    fs, pulse = generate_dirac_pulse()
    wavfile.write(os.path.join(out_dir, 'dirac_pulse_48k.wav'), fs, pulse)
    
    fs, cross = generate_crossfeed_stimulus()
    wavfile.write(os.path.join(out_dir, 'crossfeed_stimulus_48k.wav'), fs, cross)
    
    fs, dyn = generate_dynamic_test()
    wavfile.write(os.path.join(out_dir, 'dynamic_test_48k.wav'), fs, dyn)
    
    print(f"Estímulos generados con éxito en {out_dir}")
