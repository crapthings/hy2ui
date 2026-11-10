//! C ABI: callers must serialize access and stop exactly once after all I/O has stopped.
use hysteria_cli::config::ClientConfig;
use std::{
    panic::{AssertUnwindSafe, catch_unwind},
    ptr, slice,
    sync::atomic::Ordering,
};
use tokio::sync::mpsc;

/// Defines the native worker lifecycle behind the opaque C handle.
mod engine;
/// Defines the typed return values shared with Swift callers.
mod status;
pub use engine::Engine;
pub use status::{EngineState, ReadStatus, WriteResult};

/// Copies a UTF-8 error into a caller-owned NUL-terminated output buffer.
fn copy_text(text: &str, output: *mut u8, capacity: usize) -> usize {
    if output.is_null() || capacity == 0 {
        return 0;
    }
    let count = text.len().min(capacity - 1);
    // SAFETY: ABI requires a writable buffer of capacity bytes.
    unsafe {
        ptr::copy_nonoverlapping(text.as_ptr(), output, count);
        *output.add(count) = 0;
    }
    count
}

/// Creates a native engine from JSON without blocking on the network handshake.
///
/// # Safety
/// Non-null input and output pointers must cover their declared readable or writable lengths.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hy2_start(
    json: *const u8,
    length: usize,
    mtu: u16,
    error: *mut u8,
    capacity: usize,
) -> *mut Engine {
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<Engine, String> {
        if json.is_null() || length == 0 || length > 1024 * 1024 {
            return Err("invalid configuration buffer".into());
        }
        if !(1280..=1500).contains(&mtu) {
            return Err("invalid MTU".into());
        }
        let bytes = unsafe { slice::from_raw_parts(json, length) };
        let config: ClientConfig = serde_json::from_slice(bytes)
            .map_err(|_| "invalid client configuration".to_string())?;
        config.validate_connection().map_err(|e| e.to_string())?;
        engine::start(config, mtu)
    }));
    match result {
        Ok(Ok(engine)) => Box::into_raw(Box::new(engine)),
        other => {
            let message = match other {
                Ok(Err(e)) => e,
                _ => "failed to create packet engine".into(),
            };
            copy_text(&message, error, capacity);
            ptr::null_mut()
        }
    }
}

/// Reports the lifecycle state of a live engine or failure for a null handle.
///
/// # Safety
/// A non-null handle must refer to an engine that has not been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hy2_state(engine: *const Engine) -> EngineState {
    match unsafe { engine.as_ref() }.map(|engine| engine.state.load(Ordering::Acquire)) {
        Some(value) if value == EngineState::Connecting as u8 => EngineState::Connecting,
        Some(value) if value == EngineState::Connected as u8 => EngineState::Connected,
        Some(value) if value == EngineState::Stopped as u8 => EngineState::Stopped,
        _ => EngineState::Failed,
    }
}

/// Copies a packet into the input queue and reports acceptance or backpressure.
///
/// # Safety
/// The live engine handle and readable packet buffer must remain valid for the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hy2_write(
    engine: *const Engine,
    packet: *const u8,
    length: usize,
) -> WriteResult {
    let Some(engine) = (unsafe { engine.as_ref() }) else {
        return WriteResult::Closed;
    };
    if packet.is_null() || length < 20 || length > 65535 {
        return WriteResult::Closed;
    }
    let packet = unsafe { slice::from_raw_parts(packet, length) };
    if !matches!(packet[0] >> 4, 4 | 6) || (packet[0] >> 4 == 6 && length < 40) {
        return WriteResult::Closed;
    }
    match engine.input.try_send(packet.to_vec()) {
        Ok(()) => WriteResult::Accepted,
        Err(mpsc::error::TrySendError::Full(_)) => WriteResult::Full,
        Err(_) => WriteResult::Closed,
    }
}

/// Copies the next output packet or returns a named nonpositive ReadStatus value.
///
/// # Safety
/// The live engine handle and writable output buffer must cover the declared capacity.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hy2_read(engine: *const Engine, output: *mut u8, capacity: usize) -> i32 {
    let Some(engine) = (unsafe { engine.as_ref() }) else {
        return ReadStatus::Closed as i32;
    };
    if output.is_null() || capacity < 65535 {
        return ReadStatus::BufferTooSmall as i32;
    }
    let Ok(mut receiver) = engine.output.lock() else {
        return ReadStatus::Closed as i32;
    };
    match receiver.try_recv() {
        Ok(packet) => {
            if packet.len() > capacity {
                return ReadStatus::BufferTooSmall as i32;
            }
            unsafe {
                ptr::copy_nonoverlapping(packet.as_ptr(), output, packet.len());
            }
            packet.len() as i32
        }
        Err(mpsc::error::TryRecvError::Empty) => ReadStatus::Empty as i32,
        Err(_) => ReadStatus::Closed as i32,
    }
}

/// Copies the latest engine error into a caller-owned NUL-terminated buffer.
///
/// # Safety
/// The non-null handle must be live and the output buffer must cover its capacity.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hy2_error(
    engine: *const Engine,
    output: *mut u8,
    capacity: usize,
) -> usize {
    let Some(engine) = (unsafe { engine.as_ref() }) else {
        return copy_text("engine unavailable", output, capacity);
    };
    engine
        .error
        .lock()
        .map_or(0, |e| copy_text(&e, output, capacity))
}

/// Stops the worker and frees its engine after all packet I/O has finished.
///
/// # Safety
/// A non-null engine must be stopped exactly once with no concurrent or later handle calls.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hy2_stop(engine: *mut Engine) {
    if engine.is_null() {
        return;
    }
    let engine = unsafe { Box::from_raw(engine) };
    engine.stop();
}

/// Verifies invalid ABI inputs fail before any network work starts.
#[cfg(test)]
mod tests {
    use super::*;
    /// Rejects empty credentials before allocating a native worker.
    #[test]
    fn invalid_configuration_fails_before_starting_a_worker() {
        let mut error = [0u8; 256];
        let json = br#"{"server":"example.com:443","auth":""}"#;
        let engine = unsafe {
            hy2_start(
                json.as_ptr(),
                json.len(),
                1400,
                error.as_mut_ptr(),
                error.len(),
            )
        };
        assert!(engine.is_null());
        assert!(String::from_utf8_lossy(&error).contains("auth"));
    }
    /// Rejects null configuration and engine pointers without dereferencing them.
    #[test]
    fn invalid_buffer_is_rejected() {
        assert!(unsafe { hy2_start(ptr::null(), 0, 1400, ptr::null_mut(), 0) }.is_null());
        assert_eq!(
            unsafe { hy2_write(ptr::null(), ptr::null(), 0) },
            WriteResult::Closed
        );
    }
}
