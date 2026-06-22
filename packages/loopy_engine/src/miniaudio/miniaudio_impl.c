/*
 * miniaudio_impl.c — the single translation unit that compiles the miniaudio
 * implementation. Kept separate from engine.c so the (large) library body is
 * only compiled once and engine.c stays fast to rebuild.
 */
#define MINIAUDIO_IMPLEMENTATION

/* We only need PCM capture/playback; disable decoders/encoders/resources we do
 * not use to keep the binary small and the build fast. */
#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH

#include "miniaudio.h"
