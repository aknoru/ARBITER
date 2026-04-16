// =============================================================================
// itch_parser.rs — NASDAQ TotalView-ITCH 5.0 binary message decoder
// =============================================================================
//
// Specification:
//   https://www.nasdaqtrader.com/content/technicalsupport/specifications/
//           dataproducts/NQTVITCHspecification.pdf
//
// Wire format:
//   · Each message is prefixed by a 2-byte big-endian length field.
//   · All integer fields are big-endian (network byte order).
//   · Prices are u32 in $0.0001 increments (4 decimal places).
//     e.g. AAPL @ $172.50 = 1_725_000
//   · Timestamps are 6-byte big-endian nanoseconds since midnight.
//   · Stock symbols are 8-byte ASCII, right space-padded.
//
// Supported message types (relevant to order matching):
//   A — Add Order (no MPID)
//   F — Add Order with MPID Attribution
//   E — Order Executed
//   C — Order Executed With Price
//   X — Order Cancel (partial)
//   D — Order Delete
//   U — Order Replace (Delete old + Add new)
//
// All other types (S, R, H, Y, L, V, W, K, J, I, N, Q, G, B, O, P, T)
// are silently skipped.
// =============================================================================

use crate::types::Side;
use std::io;
use std::io::Read;

// =============================================================================
// Parsed ITCH message enum
// =============================================================================

#[derive(Debug)]
pub enum ItchMessage {
    /// 'A' — Add Order, no MPID (36 bytes)
    AddOrder {
        ts_ns:     u64,      // nanoseconds since midnight (6-byte field)
        order_ref: u64,      // 8-byte order reference number
        side:      Side,
        shares:    u32,
        stock:     [u8; 8],  // right space-padded ASCII, e.g. b"AAPL    "
        price:     u32,      // raw $0.0001 ticks (e.g. 1_725_000 = $172.50)
    },

    /// 'F' — Add Order with MPID Attribution (40 bytes)
    AddOrderAttributed {
        ts_ns:     u64,
        order_ref: u64,
        side:      Side,
        shares:    u32,
        stock:     [u8; 8],
        price:     u32,
    },

    /// 'E' — Order Executed (31 bytes)
    OrderExecuted {
        ts_ns:     u64,
        order_ref: u64,
        shares:    u32,      // shares executed in this event
    },

    /// 'C' — Order Executed With Price (36 bytes)
    OrderExecutedWithPrice {
        ts_ns:      u64,
        order_ref:  u64,
        shares:     u32,
        exec_price: u32,
    },

    /// 'X' — Order Cancel — partial shares cancelled (23 bytes)
    OrderCancel {
        ts_ns:            u64,
        order_ref:        u64,
        cancelled_shares: u32,
    },

    /// 'D' — Order Delete (19 bytes)
    OrderDelete {
        ts_ns:     u64,
        order_ref: u64,
    },

    /// 'U' — Order Replace (35 bytes)
    /// Semantics: delete `orig_order_ref`, add `new_order_ref` with new fields.
    OrderReplace {
        ts_ns:         u64,
        orig_order_ref: u64,
        new_order_ref:  u64,
        shares:         u32,
        price:          u32,
    },
}

// =============================================================================
// Field read helpers — Big-Endian, bounds assumed valid by caller
// =============================================================================

#[inline] fn r_u16(b: &[u8], i: usize) -> u16 {
    u16::from_be_bytes([b[i], b[i+1]])
}
#[inline] fn r_u32(b: &[u8], i: usize) -> u32 {
    u32::from_be_bytes([b[i], b[i+1], b[i+2], b[i+3]])
}
#[inline] fn r_u64(b: &[u8], i: usize) -> u64 {
    u64::from_be_bytes([b[i],b[i+1],b[i+2],b[i+3],b[i+4],b[i+5],b[i+6],b[i+7]])
}
#[inline] fn r_ts6(b: &[u8], i: usize) -> u64 {
    // 6-byte big-endian field → u64
    ((b[i  ] as u64) << 40) | ((b[i+1] as u64) << 32) |
    ((b[i+2] as u64) << 24) | ((b[i+3] as u64) << 16) |
    ((b[i+4] as u64) <<  8) |  (b[i+5] as u64)
}
#[inline] fn r_stock8(b: &[u8], i: usize) -> [u8; 8] {
    [b[i],b[i+1],b[i+2],b[i+3],b[i+4],b[i+5],b[i+6],b[i+7]]
}

// =============================================================================
// Public helpers
// =============================================================================

/// Return the trimmed ASCII stock symbol from an 8-byte space-padded field.
/// e.g. b"AAPL    " → "AAPL"
pub fn stock_name(stock: &[u8; 8]) -> &str {
    let end = stock.iter()
        .rposition(|&b| b != b' ')
        .map(|i| i + 1)
        .unwrap_or(0);
    std::str::from_utf8(&stock[..end]).unwrap_or("")
}

/// Convert a raw ITCH price (in $0.0001 increments) to BAME ticks ($0.01).
/// AAPL $172.50 = raw 1_725_000 → bame tick 17_250 (fits in u16 up to $655.35)
#[inline]
pub fn price_to_bame_tick(raw_price: u32) -> u32 {
    raw_price / 100
}

// =============================================================================
// Core message parser
// =============================================================================

/// Read exactly one relevant ITCH 5.0 message from `reader`.
///
/// Returns:
///   `None`          — clean EOF
///   `Some(Err(e))`  — I/O error
///   `Some(Ok(msg))` — successfully parsed message
///
/// Unknown or unsupported message types are transparently skipped.
pub fn parse_message<R: Read>(reader: &mut R) -> Option<io::Result<ItchMessage>> {
    let mut len_buf = [0u8; 2];

    loop {
        // ── Read 2-byte length frame ──────────────────────────────────────
        match reader.read_exact(&mut len_buf) {
            Ok(()) => {}
            Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return None,
            Err(e) => return Some(Err(e)),
        }

        let msg_len = r_u16(&len_buf, 0) as usize;
        if msg_len == 0 { continue; }

        // ── Read message body ─────────────────────────────────────────────
        let mut buf = vec![0u8; msg_len];
        match reader.read_exact(&mut buf) {
            Ok(()) => {}
            Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return None,
            Err(e) => return Some(Err(e)),
        }

        let msg_type = buf[0];

        let msg = match msg_type {

            // ── 'A' Add Order — No MPID (36 bytes) ──────────────────────────
            b'A' if msg_len >= 36 => ItchMessage::AddOrder {
                ts_ns:     r_ts6(&buf, 5),
                order_ref: r_u64(&buf, 11),
                side:      if buf[19] == b'B' { Side::Buy } else { Side::Sell },
                shares:    r_u32(&buf, 20),
                stock:     r_stock8(&buf, 24),
                price:     r_u32(&buf, 32),
            },

            // ── 'F' Add Order — MPID Attribution (40 bytes) ─────────────────
            b'F' if msg_len >= 40 => ItchMessage::AddOrderAttributed {
                ts_ns:     r_ts6(&buf, 5),
                order_ref: r_u64(&buf, 11),
                side:      if buf[19] == b'B' { Side::Buy } else { Side::Sell },
                shares:    r_u32(&buf, 20),
                stock:     r_stock8(&buf, 24),
                price:     r_u32(&buf, 32),
                // [36..40] = Attribution (ignored for matching)
            },

            // ── 'E' Order Executed (31 bytes) ────────────────────────────────
            b'E' if msg_len >= 31 => ItchMessage::OrderExecuted {
                ts_ns:     r_ts6(&buf, 5),
                order_ref: r_u64(&buf, 11),
                shares:    r_u32(&buf, 19),
                // [23..31] = Match Number (ignored)
            },

            // ── 'C' Order Executed With Price (36 bytes) ──────────────────────
            b'C' if msg_len >= 36 => ItchMessage::OrderExecutedWithPrice {
                ts_ns:      r_ts6(&buf, 5),
                order_ref:  r_u64(&buf, 11),
                shares:     r_u32(&buf, 19),
                // [23..31] = Match Number, [31] = Printable
                exec_price: r_u32(&buf, 32),
            },

            // ── 'X' Order Cancel (23 bytes) ───────────────────────────────────
            b'X' if msg_len >= 23 => ItchMessage::OrderCancel {
                ts_ns:            r_ts6(&buf, 5),
                order_ref:        r_u64(&buf, 11),
                cancelled_shares: r_u32(&buf, 19),
            },

            // ── 'D' Order Delete (19 bytes) ───────────────────────────────────
            b'D' if msg_len >= 19 => ItchMessage::OrderDelete {
                ts_ns:     r_ts6(&buf, 5),
                order_ref: r_u64(&buf, 11),
            },

            // ── 'U' Order Replace (35 bytes) ──────────────────────────────────
            b'U' if msg_len >= 35 => ItchMessage::OrderReplace {
                ts_ns:          r_ts6(&buf, 5),
                orig_order_ref: r_u64(&buf, 11),
                new_order_ref:  r_u64(&buf, 19),
                shares:         r_u32(&buf, 27),
                price:          r_u32(&buf, 31),
            },

            // ── All other types — skip silently ──────────────────────────────
            _ => continue,
        };

        return Some(Ok(msg));
    }
}
