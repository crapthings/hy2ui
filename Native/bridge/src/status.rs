//! Defines the C-compatible states and queue results mirrored in Hy2Bridge.h.

/// Reports the current lifecycle phase of a native packet engine.
#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EngineState {
    Connecting = 0,
    Connected = 1,
    Stopped = 2,
    Failed = 3,
}

/// Reports whether a packet was accepted, backpressured, or rejected.
#[repr(i32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WriteResult {
    Closed = -1,
    Full = 0,
    Accepted = 1,
}

/// Defines nonpositive packet-read results while positive values carry packet lengths.
#[repr(i32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ReadStatus {
    BufferTooSmall = -2,
    Closed = -1,
    Empty = 0,
}
