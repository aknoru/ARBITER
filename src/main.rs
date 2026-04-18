mod itch_parser;
mod orderbook;
mod types;

use std::fs::File;
use std::io::BufReader;
use std::time::Instant;

use itch_parser::{parse_message, ItchMessage};
use types::{Order, OrderBook};

fn main() {
    println!("ITCH Processing\n");
    println!("ITCH Parser Processing...\n");

    let file = File::open("itch_binary").expect("file not found");
    let mut reader = BufReader::new(file);

    let mut total_messages = 0u64;

    let start = Instant::now();

    while let Some(_) = parse_message(&mut reader) {
        total_messages += 1;
    }

    let elapsed = start.elapsed().as_secs_f64();

    println!("Success...\n");

    println!("ITCH Parsing Statistics:");
    println!("Total Messages: {}", total_messages);
    println!("Total Time: {:.3} seconds", elapsed);
    println!("Speed: {:.0} msg/second", total_messages as f64 / elapsed);
    println!(
        "Latency: {:.0} ns\n",
        (elapsed * 1e9) / total_messages as f64
    );

    println!("LOB Performance\n");
    println!("LOB Processing...\n");

    let file = File::open("12302019.NASDAQ_ITCH50").expect("file not found");
    let mut reader = BufReader::new(file);

    let mut book = OrderBook::new();

    let mut add_orders = 0u64;
    let mut exec_orders = 0u64;
    let mut cancel_orders = 0u64;
    let mut delete_orders = 0u64;
    let replace_orders = 0u64;

    let mut total_messages = 0u64;

    let start = Instant::now();

    while let Some(msg) = parse_message(&mut reader) {
        total_messages += 1;

        match msg {
            ItchMessage::AddLimit {
                order_id,
                side,
                price,
                qty,
            } => {
                let order = Order {
                    id: order_id,
                    price,
                    qty,
                    side,
                };

                book.add_limit_order(order);

                add_orders += 1;
            }

            ItchMessage::Execute { order_id, qty } => {
                book.execute_order(order_id, qty);

                exec_orders += 1;
            }

            ItchMessage::Cancel { order_id, qty } => {
                book.cancel_order(order_id, qty);

                cancel_orders += 1;
            }

            ItchMessage::Delete { order_id } => {
                book.delete_order(order_id);

                delete_orders += 1;
            }
        }
    }

    let elapsed = start.elapsed().as_secs_f64();

    println!("Success...\n");

    println!("Performance Metrics:");
    println!("Total Messages: {}", total_messages);
    println!(
        "ITCH Latency: {:.0} ns",
        (elapsed * 1e9) / total_messages as f64
    );
    println!("Total Time: {:.3} seconds", elapsed);
    println!("Speed: {:.0} msg/second\n", total_messages as f64 / elapsed);

    println!("Orderbook Statistics:");
    println!("Total Add Orders: {}", add_orders);
    println!("Total Execute Orders: {}", exec_orders);
    println!("Total Cancel Orders: {}", cancel_orders);
    println!("Total Delete Orders: {}", delete_orders);
    println!("Total Replace Orders: {}", replace_orders);
}
