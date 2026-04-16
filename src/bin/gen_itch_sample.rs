use std::fs::File;
use std::io::{Write, Result};

/// Generate a valid NASDAQ ITCH 5.0 binary message (Add Order - Type A)
fn write_add_order(
    f: &mut File,
    ts: u64,
    order_id: u64,
    side: char,
    shares: u32,
    stock: &str,
    price: u32,
) -> Result<()> {
    let msg_len: u16 = 36;
    f.write_all(&msg_len.to_be_bytes())?;

    let mut buf = [0u8; 36];
    buf[0] = b'A';                                  // Type
    buf[1..3].copy_from_slice(&0u16.to_be_bytes()); // Tracking
    buf[3..5].copy_from_slice(&0u16.to_be_bytes()); // MPID
    buf[5..11].copy_from_slice(&ts.to_be_bytes()[2..8]); // TS (6 bytes)
    buf[11..19].copy_from_slice(&order_id.to_be_bytes());
    buf[19] = side as u8;
    buf[20..24].copy_from_slice(&shares.to_be_bytes());
    
    let mut s_buf = [b' '; 8];
    let s_bytes = stock.as_bytes();
    let len = s_bytes.len().min(8);
    s_buf[..len].copy_from_slice(&s_bytes[..len]);
    buf[24..32].copy_from_slice(&s_buf);
    
    buf[32..36].copy_from_slice(&price.to_be_bytes());

    f.write_all(&buf)?;
    Ok(())
}

fn main() -> Result<()> {
    let mut file = File::create("tests/itch_sample.bin")?;

    println!("Generating ITCH 5.0 sample dump for NVDA...");

    // 1. Buy Order: $100.00 (raw 1,000,000), 10 shares
    write_add_order(&mut file, 1000, 101, 'B', 10, "NVDA    ", 1_000_000)?;
    
    // 2. Sell Order: $99.00 (raw 990,000), 5 shares -> Should match 5
    write_add_order(&mut file, 2000, 102, 'S', 5, "NVDA    ", 990_000)?;
    
    // 3. Different Stock (AAPL) -> Should be filtered out by --symbol NVDA
    write_add_order(&mut file, 3000, 103, 'B', 100, "AAPL    ", 1_500_000)?;

    // 4. Sell Order: $100.00 (raw 1,000,000), 10 shares -> Should match 5 (residual)
    write_add_order(&mut file, 4000, 104, 'S', 10, "NVDA    ", 1_000_000)?;

    println!("Created tests/itch_sample.bin (4 messages)");
    println!("Run with: cargo run --release -- --itch tests/itch_sample.bin --symbol NVDA");
    Ok(())
}
