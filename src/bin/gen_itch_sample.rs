use std::fs::File;
use std::io::Write;

fn main() -> std::io::Result<()> {
    // Generate a dummy ITCH 5.0 binary file for testing
    let mut file = File::create("tests/itch_sample.bin")?;
    
    // Add Order (Type 'A')
    let len: u16 = 36;
    file.write_all(&len.to_be_bytes())?;
    let mut buf = vec![0u8; 36];
    buf[0] = b'A';
    // Dummy values
    file.write_all(&buf)?;
    
    println!("Created tests/itch_sample.bin");
    Ok(())
}
