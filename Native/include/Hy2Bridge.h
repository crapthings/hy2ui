#ifndef HY2_BRIDGE_H
#define HY2_BRIDGE_H
#include <stdint.h>
#include <stddef.h>

// Identifies an opaque native engine whose calls and destruction must be serialized.
typedef struct Engine Hy2Engine;

// Reports the current lifecycle phase and mirrors Rust's repr(u8) EngineState.
typedef enum Hy2EngineState : uint8_t {
    Hy2EngineStateConnecting = 0,
    Hy2EngineStateConnected = 1,
    Hy2EngineStateStopped = 2,
    Hy2EngineStateFailed = 3
} Hy2EngineState;

// Reports acceptance or backpressure and mirrors Rust's repr(i32) WriteResult.
typedef enum Hy2WriteResult : int32_t {
    Hy2WriteResultClosed = -1,
    Hy2WriteResultFull = 0,
    Hy2WriteResultAccepted = 1
} Hy2WriteResult;

// Describes nonpositive read results while positive values carry packet lengths.
typedef enum Hy2ReadStatus : int32_t {
    Hy2ReadStatusBufferTooSmall = -2,
    Hy2ReadStatusClosed = -1,
    Hy2ReadStatusEmpty = 0
} Hy2ReadStatus;

// Starts an engine from a readable JSON buffer and writes startup errors to the supplied buffer.
Hy2Engine *hy2_start(const uint8_t *json, size_t length, uint16_t mtu, uint8_t *error, size_t capacity);
// Reads the lifecycle state of a live engine or reports failure for null.
Hy2EngineState hy2_state(const Hy2Engine *engine);
// Copies one readable IP packet into the engine's bounded input queue.
Hy2WriteResult hy2_write(const Hy2Engine *engine, const uint8_t *packet, size_t length);
// Copies one queued packet into a writable 65535-byte buffer or returns Hy2ReadStatus.
int32_t hy2_read(const Hy2Engine *engine, uint8_t *output, size_t capacity);
// Copies an engine error into a writable buffer and terminates it with a NUL byte.
size_t hy2_error(const Hy2Engine *engine, uint8_t *output, size_t capacity);
// Stops and frees an engine exactly once after all other calls have finished.
void hy2_stop(Hy2Engine *engine);
#endif
