use crate::types::{Order, Side};
use std::fmt;

// ---------------------------------------------------------------------------
// Error type
// ---------------------------------------------------------------------------

#[derive(Debug)]
pub enum ParseError {
    WrongFieldCount(usize),
    InvalidSide(String),
    BadInteger { field: &'static str, raw: String },
    ZeroPrice,
    ZeroQuantity,
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ParseError::WrongFieldCount(n) =>
                write!(f, "expected 5 comma-separated fields, got {}", n),
            ParseError::InvalidSide(s) =>
                write!(f, "invalid side '{}': must be BUY or SELL", s),
            ParseError::BadInteger { field, raw } =>
                write!(f, "cannot parse field '{}' as integer: '{}'", field, raw),
            ParseError::ZeroPrice =>
                write!(f, "price must be >= 1"),
            ParseError::ZeroQuantity =>
                write!(f, "quantity must be >= 1"),
        }
    }
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

/// Parse one CSV line into an Order.
///
/// Expected format (no header):
///   `timestamp,order_id,side,price,quantity`
///
/// Lines starting with `#` and empty lines must be filtered out by the caller.
pub fn parse_order_line(line: &str) -> Result<Order, ParseError> {
    let fields: Vec<&str> = line.split(',').map(str::trim).collect();

    if fields.len() != 5 {
        return Err(ParseError::WrongFieldCount(fields.len()));
    }

    let timestamp: u32 = fields[0]
        .parse()
        .map_err(|_| ParseError::BadInteger { field: "timestamp", raw: fields[0].to_string() })?;

    let id: u32 = fields[1]
        .parse()
        .map_err(|_| ParseError::BadInteger { field: "order_id", raw: fields[1].to_string() })?;

    let side = match fields[2] {
        "BUY"  => Side::Buy,
        "SELL" => Side::Sell,
        other  => return Err(ParseError::InvalidSide(other.to_string())),
    };

    let price: u32 = fields[3]
        .parse()
        .map_err(|_| ParseError::BadInteger { field: "price", raw: fields[3].to_string() })?;

    let qty: u32 = fields[4]
        .parse()
        .map_err(|_| ParseError::BadInteger { field: "quantity", raw: fields[4].to_string() })?;

    if price == 0 {
        return Err(ParseError::ZeroPrice);
    }
    if qty == 0 {
        return Err(ParseError::ZeroQuantity);
    }

    Ok(Order { timestamp, id, side, price, qty })
}
