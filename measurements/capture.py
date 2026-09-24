"""
capture.py - Reproductor y capturador síncrono mediante loopback WASAPI en Windows.
"""

import numpy as np
import soundcard as sc
import threading
import time
from scipy.signal import correlate

class WasapiLoopbackCapturer:
    def __init__(self, speaker_name=None):
        self.speaker = sc.default_speaker() if speaker_name is None else sc.get_speaker(speaker_name)
        self.loopback = sc.get_microphone(id=str(self.speaker.name), include_loopback=True)
        print(f"[Capturer] Altavoz de salida: {self.speaker.name}")
        print(f"[Capturer] Dispositivo loopback: {self.loopback.name}")

    def play_and_record(self, stimulus, fs=48000, extra_record_time=0.8):
        """
        Reproduce un estímulo estéreo (N, 2) y graba la salida capturada por el loopback del endpoint.
        Retorna (captured_audio, aligned_captured, delay_samples).
        """
        num_stimulus_samples = len(stimulus)
        stimulus_duration = num_stimulus_samples / fs
        total_rec_duration = stimulus_duration + extra_record_time
        total_rec_frames = int(fs * total_rec_duration)

        recorded_container = []
        rec_started_event = threading.Event()

        def _record_worker():
            try:
                with self.loopback.recorder(samplerate=fs, channels=2) as recorder:
                    rec_started_event.set()
                    rec_data = recorder.record(numframes=total_rec_frames)
                    recorded_container.append(rec_data)
            except Exception as e:
                print(f"[Capturer Error en grabador]: {e}")
                rec_started_event.set()

        t_rec = threading.Thread(target=_record_worker)
        t_rec.start()

        # Esperar a que el grabador comience
        rec_started_event.wait(timeout=2.0)
        time.sleep(0.1) # Buffer de calentamiento

        # Reproducir estímulo
        try:
            with self.speaker.player(samplerate=fs, channels=2) as player:
                player.play(stimulus.astype(np.float32))
        except Exception as e:
            print(f"[Capturer Error en reproductor]: {e}")

        t_rec.join(timeout=total_rec_duration + 3.0)

        if not recorded_container:
            raise RuntimeError("Fallo al capturar audio en loopback WASAPI.")

        raw_recorded = recorded_container[0]

        # Alinear temporalmente la señal capturada respecto al estímulo
        ref_mono = stimulus[:, 0]
        rec_mono = raw_recorded[:, 0]

        # Encontrar delay usando correlación cruzada en los primeros instantes
        max_search = min(len(rec_mono), int(fs * 2.0))
        corr = correlate(rec_mono[:max_search], ref_mono[:int(fs * 0.5)], mode='full')
        lag = np.argmax(np.abs(corr)) - (len(ref_mono[:int(fs * 0.5)]) - 1)

        delay_samples = max(0, lag)
        
        # Extraer segmento alineado de la misma longitud del estímulo
        if delay_samples + num_stimulus_samples <= len(raw_recorded):
            aligned_rec = raw_recorded[delay_samples:delay_samples + num_stimulus_samples]
        else:
            aligned_rec = raw_recorded[delay_samples:]
            # Rellenar con ceros si falta
            pad = np.zeros((num_stimulus_samples - len(aligned_rec), 2), dtype=np.float32)
            aligned_rec = np.vstack([aligned_rec, pad])

        return raw_recorded, aligned_rec, delay_samples

if __name__ == '__main__':
    from stimuli import generate_pure_tones
    fs, tone = generate_pure_tones(freq=1000.0, duration=1.0)
    capturer = WasapiLoopbackCapturer()
    print("Probando captura...")
    raw, aligned, delay = capturer.play_and_record(tone, fs=fs)
    print(f"Delay detectado: {delay} muestras ({delay/fs*1000:.2f} ms)")
    print(f"RMS estímulo: {np.sqrt(np.mean(tone**2)):.4f}, RMS alineado: {np.sqrt(np.mean(aligned**2)):.4f}")
