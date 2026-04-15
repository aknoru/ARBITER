use crate::types::Side;
use std::io::{BufReader, Read};

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

fn read_u16(reader: &mut BufReader<std::fs::File>) -> Option<u16> {
    let mut buf = [0u8; 2];
    reader.read_exact(&mut buf).ok()?;

    Some(u16::from_be_bytes(buf))
}

pub fn parse_message(reader: &mut BufReader<std::fs::File>) -> Option<ItchMessage> {
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
