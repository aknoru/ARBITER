use crate::types::Side;
use std::io::Read;

pub enum ItchMessage {
    AddLimit {
        order_id: u64,
        side: Side,
        price: usize,
        qty: u64,
    },

    Execute {
        order_id: u64,
        qty: u64,
    },

    Cancel {
        order_id: u64,
        qty: u64,
    },

    Delete {
        order_id: u64,
    },
}

fn read_u16<R: Read>(reader: &mut R) -> Option<u16> {
    let mut buf = [0u8; 2];
    reader.read_exact(&mut buf).ok()?;

    Some(u16::from_be_bytes(buf))
}

pub fn parse_message<R: Read>(reader: &mut R) -> Option<ItchMessage> {
    loop {
        let msg_len = read_u16(reader)? as usize;

        let mut buffer = vec![0u8; msg_len];

        reader.read_exact(&mut buffer).ok()?;

        let msg_type = buffer[0];

        match msg_type {
            b'A' => {
                let order_id = u64::from_be_bytes(buffer[11..19].try_into().ok()?);

                let side = if buffer[19] == b'B' {
                    Side::Buy
                } else {
                    Side::Sell
                };

                let qty = u32::from_be_bytes(buffer[20..24].try_into().ok()?) as u64;

                let raw_price = u32::from_be_bytes(buffer[32..36].try_into().ok()?) as usize;

                let price = raw_price / 100;

                return Some(ItchMessage::AddLimit {
                    order_id,
                    side,
                    price,
                    qty,
                });
            }

            b'E' => {
                let order_id = u64::from_be_bytes(buffer[11..19].try_into().ok()?);

                let qty = u32::from_be_bytes(buffer[19..23].try_into().ok()?) as u64;

                return Some(ItchMessage::Execute { order_id, qty });
            }

            b'X' => {
                let order_id = u64::from_be_bytes(buffer[11..19].try_into().ok()?);

                let qty = u32::from_be_bytes(buffer[19..23].try_into().ok()?) as u64;

                return Some(ItchMessage::Cancel { order_id, qty });
            }

            b'D' => {
                let order_id = u64::from_be_bytes(buffer[11..19].try_into().ok()?);

                return Some(ItchMessage::Delete { order_id });
            }

            _ => continue,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    // ── Helper builders ──────────────────────────────────────────────────────

    /// Build a framed byte stream: 2-byte big-endian length prefix + payload.
    fn frame(payload: &[u8]) -> Vec<u8> {
        let mut out = Vec::with_capacity(2 + payload.len());
        out.extend_from_slice(&(payload.len() as u16).to_be_bytes());
        out.extend_from_slice(payload);
        out
    }

    fn add_payload(order_id: u64, side: u8, qty: u32, price_raw: u32) -> Vec<u8> {
        let mut buf = vec![0u8; 36];
        buf[0] = b'A';
        buf[11..19].copy_from_slice(&order_id.to_be_bytes());
        buf[19] = side;
        buf[20..24].copy_from_slice(&qty.to_be_bytes());
        buf[32..36].copy_from_slice(&price_raw.to_be_bytes());
        buf
    }

    fn execute_payload(order_id: u64, qty: u32) -> Vec<u8> {
        let mut buf = vec![0u8; 23];
        buf[0] = b'E';
        buf[11..19].copy_from_slice(&order_id.to_be_bytes());
        buf[19..23].copy_from_slice(&qty.to_be_bytes());
        buf
    }

    fn cancel_payload(order_id: u64, qty: u32) -> Vec<u8> {
        let mut buf = vec![0u8; 23];
        buf[0] = b'X';
        buf[11..19].copy_from_slice(&order_id.to_be_bytes());
        buf[19..23].copy_from_slice(&qty.to_be_bytes());
        buf
    }

    fn delete_payload(order_id: u64) -> Vec<u8> {
        let mut buf = vec![0u8; 19];
        buf[0] = b'D';
        buf[11..19].copy_from_slice(&order_id.to_be_bytes());
        buf
    }

    // ── AddLimit ('A') ───────────────────────────────────────────────────────

    #[test]
    fn test_parse_add_limit_buy() {
        let data = frame(&add_payload(42, b'B', 100, 15000));
        let mut cursor = Cursor::new(data);
        let msg = parse_message(&mut cursor).expect("expected a message");
        match msg {
            ItchMessage::AddLimit { order_id, side, price, qty } => {
                assert_eq!(order_id, 42);
                assert!(matches!(side, Side::Buy));
                assert_eq!(price, 150); // 15000 / 100
                assert_eq!(qty, 100);
            }
            _ => panic!("expected AddLimit"),
        }
    }

    #[test]
    fn test_parse_add_limit_sell() {
        let data = frame(&add_payload(99, b'S', 200, 25000));
        let mut cursor = Cursor::new(data);
        let msg = parse_message(&mut cursor).expect("expected a message");
        match msg {
            ItchMessage::AddLimit { order_id, side, price, qty } => {
                assert_eq!(order_id, 99);
                assert!(matches!(side, Side::Sell));
                assert_eq!(price, 250); // 25000 / 100
                assert_eq!(qty, 200);
            }
            _ => panic!("expected AddLimit"),
        }
    }

    #[test]
    fn test_parse_add_limit_price_division() {
        // Verify raw price is divided by 100
        let data = frame(&add_payload(1, b'B', 10, 10000));
        let mut cursor = Cursor::new(data);
        if let Some(ItchMessage::AddLimit { price, .. }) = parse_message(&mut cursor) {
            assert_eq!(price, 100);
        } else {
            panic!("expected AddLimit");
        }
    }

    // ── Execute ('E') ────────────────────────────────────────────────────────

    #[test]
    fn test_parse_execute() {
        let data = frame(&execute_payload(7, 50));
        let mut cursor = Cursor::new(data);
        let msg = parse_message(&mut cursor).expect("expected a message");
        match msg {
            ItchMessage::Execute { order_id, qty } => {
                assert_eq!(order_id, 7);
                assert_eq!(qty, 50);
            }
            _ => panic!("expected Execute"),
        }
    }

    // ── Cancel ('X') ─────────────────────────────────────────────────────────

    #[test]
    fn test_parse_cancel() {
        let data = frame(&cancel_payload(13, 25));
        let mut cursor = Cursor::new(data);
        let msg = parse_message(&mut cursor).expect("expected a message");
        match msg {
            ItchMessage::Cancel { order_id, qty } => {
                assert_eq!(order_id, 13);
                assert_eq!(qty, 25);
            }
            _ => panic!("expected Cancel"),
        }
    }

    // ── Delete ('D') ─────────────────────────────────────────────────────────

    #[test]
    fn test_parse_delete() {
        let data = frame(&delete_payload(5));
        let mut cursor = Cursor::new(data);
        let msg = parse_message(&mut cursor).expect("expected a message");
        match msg {
            ItchMessage::Delete { order_id } => assert_eq!(order_id, 5),
            _ => panic!("expected Delete"),
        }
    }

    // ── Unknown message type ─────────────────────────────────────────────────

    #[test]
    fn test_parse_unknown_skips_to_next_known() {
        let mut unknown = vec![0u8; 19];
        unknown[0] = b'Z';

        let mut data = frame(&unknown);
        data.extend_from_slice(&frame(&delete_payload(77)));

        let mut cursor = Cursor::new(data);
        let msg = parse_message(&mut cursor).expect("expected a message");
        match msg {
            ItchMessage::Delete { order_id } => assert_eq!(order_id, 77),
            _ => panic!("expected Delete after skipping unknown"),
        }
    }

    #[test]
    fn test_parse_only_unknown_returns_none() {
        let mut unknown = vec![0u8; 10];
        unknown[0] = b'Z';
        let data = frame(&unknown);
        let mut cursor = Cursor::new(data);
        assert!(parse_message(&mut cursor).is_none());
    }

    // ── Empty / truncated input ──────────────────────────────────────────────

    #[test]
    fn test_parse_empty_returns_none() {
        let mut cursor = Cursor::new(Vec::<u8>::new());
        assert!(parse_message(&mut cursor).is_none());
    }

    #[test]
    fn test_parse_truncated_length_prefix_returns_none() {
        // Only one byte of the 2-byte length field
        let data = vec![0x00u8];
        let mut cursor = Cursor::new(data);
        assert!(parse_message(&mut cursor).is_none());
    }

    #[test]
    fn test_parse_truncated_payload_returns_none() {
        // Length says 36 but only 10 bytes follow
        let mut data = 36u16.to_be_bytes().to_vec();
        data.extend_from_slice(&[0u8; 10]);
        let mut cursor = Cursor::new(data);
        assert!(parse_message(&mut cursor).is_none());
    }
}
