#ifndef NATIVE_AUDIO_H
#define NATIVE_AUDIO_H

#include "display_consumer.h"

/*
 * Consumer-side audio bridge over the display library's audio socket.
 *
 *   - playback: reads desktop PCM datagrams from the socket and writes them to an
 *                AAudio output stream (the Android speaker);
 *   - capture : reads the Android mic via an AAudio input stream and writes PCM
 *                datagrams to the socket (the producer exposes them as a Linux
 *                recording source). Only active while the mic is enabled.
 *
 * Playback is driven by an AAudio data callback. The socket thread appends PCM to a
 * frame-aligned ring buffer and the callback supplies near-silent keepalive samples
 * on underrun. The output stream is rebuilt independently after AAudio failures and
 * may idle-stop after silence; the display connection is never rebuilt for this.
 * The capture stream is opened once and only started while the mic is enabled.
 *
 * PowOS: every live connection (surface) carries its own audio socket, and KWin sends the desktop's sound on ONE of
 * them: the desktop's (surface 0) while it is connected, otherwise a live window task's (kwin 0067) - with a game
 * full screen in its own task there is usually no desktop connection at all (11-08: game sound reached anland-speaker
 * but no AudioTrack ran). So the bridge listens on all of them: audio_attach() when a connection goes live
 * (exit-fallback), audio_detach() when it drops or closes. Each attached fd is dup()ed and owned here (closed by the
 * playback thread only), so the display library closing its own copy never races a read.
 */

void audio_start(void);
void audio_stop(void);

/* Surface [surface_id]'s connection is live with audio socket [fd] (get_audio_fd; dup()ed - the caller keeps its
 * own). Replaces that surface's previous link. fd < 0 = audio_detach(). Any thread. */
void audio_attach(uint32_t surface_id, int fd);
/* Surface [surface_id]'s connection dropped or is closing: stop using its audio socket. Any thread, idempotent. */
void audio_detach(uint32_t surface_id);

/* Enable/disable microphone capture (the up path). Off by default; the Java layer
 * turns it on only once RECORD_AUDIO has been granted. */
void audio_set_mic_enabled(int enabled);

/* Latency presets, separately for the speaker (playback) and microphone (capture)
 * paths, in milliseconds. 0 = let the engine pick the default quantum. The value is
 * converted to a frame count using the device's negotiated rate and forwarded to the
 * producer, which applies it as the PipeWire node.latency. Takes effect immediately
 * (the formats are re-announced on the live connection). */
void audio_set_latency(int speaker_ms, int mic_ms);

/* Keep the output stream hot for burst reliability, or allow it to idle-stop after
 * silence to save standby power. Disabled by default. */
void audio_set_keepalive(int enabled);

#endif
