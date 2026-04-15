#pragma once
#include <cstdint>

// ============================================================
// Constants — must match Rust and Verilog parameters exactly
// ============================================================

static constexpr uint32_t BATCH_SIZE = 8;
static constexpr uint32_t MAX_PRICE  = 65536; // valid price range: 1..65535

// ============================================================
// Core types
// ============================================================

enum class Side : uint8_t { Buy, Sell };

/// A single limit order.
/// All fields are 32-bit unsigned integers — matches the Rust extended baseline
/// and maps cleanly to 32-bit Verilog wires.
struct Order {
    uint32_t timestamp; // monotonically non-decreasing; used for price-time priority
    uint32_t id;        // unique within one session
    Side     side;      // BUY or SELL
    uint32_t price;     // integer ticks; range [1, 65535]
    uint32_t qty;       // integer lots; range [1, 65535]; may decrease on partial fill
};

/// One executed trade produced by process_batch().
struct Trade {
    uint32_t buy_id;
    uint32_t sell_id;
    uint32_t price;  // = sell.price (canonical intra-batch trade price rule)
    uint32_t qty;
};
