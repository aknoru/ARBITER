// Batched Arbitration Matching Engine — Rust reference implementation.
//
// Modules:
//   csv_parser     — CSV line parser for the batched mode input format
//   batch_matcher  — core batch matching algorithm
//   orderbook      — persistent order book state (add / execute / cancel / delete)
//   types          — shared data types (Order, Side, PriceLevel, OrderBook)
//   itch_parser    — original binary ITCH 5.0 reader (preserved; unused in batch mode)
mod batch_matcher;
mod csv_parser;
mod orderbook;
mod types;

// Original ITCH reader kept for reference; not compiled into the batch execution path.
#[allow(dead_code)]
mod itch_parser;

use std::env;
use std::fs::File;
use std::io::{BufRead, BufReader};

use batch_matcher::{Trade, process_batch};
use csv_parser::parse_order_line;
use types::{Order, Side, OrderBook, BATCH_SIZE};
use itch_parser::{parse_message, ItchMessage, stock_name, price_to_bame_tick};

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

fn main() {
    let args: Vec<String> = env::args().collect();

    if args.len() < 2 || args[1] == "--help" || args[1] == "-h" {
        print_usage();
        return;
    }

    let mut is_itch = false;
    let mut symbol = String::new();
    let mut path = String::new();

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--itch" => {
                is_itch = true;
                i += 1;
                if i < args.len() { path = args[i].clone(); }
            }
            "--symbol" => {
                i += 1;
                if i < args.len() { symbol = args[i].clone(); }
            }
            _ => { path = args[i].clone(); }
        }
        i += 1;
    }

    if path.is_empty() {
        print_usage();
        return;
    }

    let file = File::open(&path).unwrap_or_else(|e| {
        eprintln!("error: cannot open '{}': {}", path, e);
        std::process::exit(1);
    });

    if is_itch {
        run_itch_engine(BufReader::new(file), &symbol);
    } else {
        run_csv_engine(BufReader::new(file));
    }
}

// ---------------------------------------------------------------------------
// Engine driver
// ---------------------------------------------------------------------------

fn run_csv_engine<R: BufRead>(reader: R) {
    let mut book      = OrderBook::new();
    let mut batch     = Vec::<Order>::with_capacity(BATCH_SIZE);
    let mut batch_num = 0u32;
    let mut mem_file  = File::create("tests/orders.mem").expect("failed to create orders.mem");

    for (line_idx, line_result) in reader.lines().enumerate() {
        let line = match line_result {
            Ok(l)  => l,
            Err(e) => {
                eprintln!("warning: I/O error on line {}: {}", line_idx + 1, e);
                continue;
            }
        };

        let trimmed = line.trim().to_string();

        // Skip blank lines and comments.
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }

        match parse_order_line(&trimmed) {
            Ok(order) => {
                let side_bit = if order.side == Side::Buy { 1 } else { 0 };
                let bin_str = format!("{:064b}{:016b}{:032b}{:032b}{:b}\n",
                    order.id, order.price, order.qty, order.timestamp, side_bit);
                use std::io::Write;
                mem_file.write_all(bin_str.as_bytes()).unwrap();

                batch.push(order);
                if batch.len() == BATCH_SIZE {
                    batch_num += 1;
                    flush_batch(&mut book, &mut batch, batch_num);
                }
            }
            Err(e) => {
                eprintln!("warning: line {}: {}", line_idx + 1, e);
            }
        }
    }

    // Flush any remaining partial batch.
    if !batch.is_empty() {
        batch_num += 1;
        flush_batch(&mut book, &mut batch, batch_num);
    }

    // Print final order book state.
    print_book(&book);
}

fn run_itch_engine<R: std::io::Read>(mut reader: R, filter_symbol: &str) {
    let mut book      = OrderBook::new();
    let mut batch     = Vec::<Order>::with_capacity(BATCH_SIZE);
    let mut batch_num = 0u32;
    let mut mem_file  = File::create("tests/orders.mem").expect("failed to create orders.mem");

    println!("INFO: Processing ITCH protocol data (filter: '{}')", filter_symbol);

    while let Some(result) = parse_message(&mut reader) {
        let msg = match result {
            Ok(m) => m,
            Err(e) => {
                eprintln!("error: ITCH decode failure: {}", e);
                break;
            }
        };

        if let ItchMessage::AddOrder { ts_ns, order_ref, side, shares, stock, price } = msg {
            let symbol = stock_name(&stock);
            if !filter_symbol.is_empty() && symbol != filter_symbol {
                continue;
            }

            let order = Order {
                timestamp: (ts_ns % 1_000_000_000) as u32,
                id:        order_ref,
                side:      side,
                price:     price_to_bame_tick(price),
                qty:       shares,
            };

            // Write to mem file for simulation parity
            let side_bit = if order.side == Side::Buy { 1 } else { 0 };
            let bin_str = format!("{:064b}{:016b}{:032b}{:032b}{:b}\n",
                order.id, order.price, order.qty, order.timestamp, side_bit);
            use std::io::Write;
            mem_file.write_all(bin_str.as_bytes()).unwrap();

            batch.push(order);
            if batch.len() == BATCH_SIZE {
                batch_num += 1;
                flush_batch(&mut book, &mut batch, batch_num);
            }
        }
    }

    if !batch.is_empty() {
        batch_num += 1;
        flush_batch(&mut book, &mut batch, batch_num);
    }

    print_book(&book);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Run one batch through the matching engine and print results to stdout.
fn flush_batch(book: &mut OrderBook, batch: &mut Vec<Order>, batch_num: u32) {
    println!("BATCH {} START orders={}", batch_num, batch.len());

    let trades: Vec<Trade> = process_batch(book, batch);
    let trade_count = trades.len();

    for t in &trades {
        println!(
            "TRADE buy_id={} sell_id={} price={} qty={}",
            t.buy_id, t.sell_id, t.price, t.qty
        );
    }

    // Residuals = number of order records remaining in the book after matching.
    let residual_count = book.orders.len();
    println!(
        "BATCH {} END trades={} residuals={}",
        batch_num, trade_count, residual_count
    );

    batch.clear();
}

/// Print all resting orders to stdout in canonical price-priority order.
fn print_book(book: &OrderBook) {
    for o in book.resting_buys_sorted() {
        println!(
            "BOOK BUY  price={} qty={} order_id={}",
            o.price, o.qty, o.id
        );
    }
    for o in book.resting_asks_sorted() {
        println!(
            "BOOK SELL price={} qty={} order_id={}",
            o.price, o.qty, o.id
        );
    }
}

fn print_usage() {
    println!("Batched Arbitration Matching Engine  v1.0");
    println!();
    println!("  USAGE:  matching_engine [OPTIONS] <file>");
    println!();
    println!("  OPTIONS:");
    println!("    --itch           Interpret input as binary NASDAQ ITCH 5.0");
    println!("    --symbol <SYM>   Filter ITCH stream for specific ticker (e.g. AAPL)");
    println!();
    println!("  INPUT FORMAT (CSV default, one order per line):");
    println!("    timestamp,order_id,side,price,quantity");
    println!("    # lines beginning with # are comments; empty lines ignored");
    println!();
    println!("  OUTPUT FORMAT:");
    println!("    BATCH N START orders=K");
    println!("    TRADE buy_id=B sell_id=S price=P qty=Q");
    println!("    BATCH N END trades=T residuals=R");
    println!("    BOOK BUY  price=P qty=Q order_id=I");
    println!("    BOOK SELL price=P qty=Q order_id=I");
    println!();
    println!("  BATCH SIZE: {}", BATCH_SIZE);
    println!("  TRADE PRICE RULE: sell-side price");
    println!("  PRIORITY: price → timestamp → order_id (all ascending advantage)");
}
