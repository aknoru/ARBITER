// Batched Arbitration Matching Engine — C++ reference implementation.
//
// Mirrors the Rust implementation exactly:
//   - Same CSV format (timestamp,order_id,side,price,quantity)
//   - Same batch size (BATCH_SIZE = 8)
//   - Same arbitration sort key (price → timestamp → order_id)
//   - Same trade price rule (sell.price)
//   - Same output format → produces identical output to golden_output.txt
//
// Usage:  ./engine <orders.csv> [--bench]

#include "order.h"
#include "orderbook.h"
#include "matcher.h"

#include <chrono>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

// ============================================================
// CSV parser
// ============================================================

/// Trim leading and trailing ASCII whitespace from s.
static std::string trim(const std::string& s) {
    const char* ws = " \t\r\n";
    auto start = s.find_first_not_of(ws);
    if (start == std::string::npos) return {};
    auto end = s.find_last_not_of(ws);
    return s.substr(start, end - start + 1);
}

/// Parse one non-empty, non-comment CSV line into an Order.
/// Returns false and prints a warning to stderr on any validation failure.
static bool parse_order_line(const std::string& line,
                              uint32_t line_num,
                              Order& out)
{
    // Split on ','
    std::vector<std::string> fields;
    {
        std::istringstream ss(line);
        std::string tok;
        while (std::getline(ss, tok, ','))
            fields.push_back(trim(tok));
    }

    if (fields.size() != 5) {
        std::cerr << "warning: line " << line_num
                  << ": expected 5 fields, got " << fields.size() << "\n";
        return false;
    }

    // Parse numeric fields — throw on bad input.
    try {
        unsigned long v;

        v = std::stoul(fields[0]);
        out.timestamp = static_cast<uint32_t>(v);

        unsigned long long id_ll = std::stoull(fields[1]);
        out.id = static_cast<uint64_t>(id_ll);

        if      (fields[2] == "BUY")  out.side = Side::Buy;
        else if (fields[2] == "SELL") out.side = Side::Sell;
        else {
            std::cerr << "warning: line " << line_num
                      << ": invalid side '" << fields[2]
                      << "' (must be BUY or SELL)\n";
            return false;
        }

        v = std::stoul(fields[3]);
        out.price = static_cast<uint16_t>(v);

        v = std::stoul(fields[4]);
        out.qty = static_cast<uint32_t>(v);

    } catch (const std::exception& e) {
        std::cerr << "warning: line " << line_num
                  << ": integer parse error — " << e.what() << "\n";
        return false;
    }

    if (out.price == 0) {
        std::cerr << "warning: line " << line_num << ": price must be >= 1\n";
        return false;
    }
    if (out.qty == 0) {
        std::cerr << "warning: line " << line_num << ": quantity must be >= 1\n";
        return false;
    }

    return true;
}

// ============================================================
// Output helpers
// ============================================================

static void flush_batch(OrderBook& book,
                         std::vector<Order>& batch,
                         uint32_t batch_num)
{
    std::cout << "BATCH " << batch_num
              << " START orders=" << batch.size() << "\n";

    std::vector<Trade> trades = process_batch(book, batch);

    for (const auto& t : trades) {
        std::cout << "TRADE buy_id="  << t.buy_id
                  << " sell_id="      << t.sell_id
                  << " price="        << t.price
                  << " qty="          << t.qty << "\n";
    }

    std::cout << "BATCH " << batch_num
              << " END trades="    << trades.size()
              << " residuals="     << book.order_count() << "\n";

    batch.clear();
}

static void print_book(const OrderBook& book) {
    for (const Order* o : book.resting_buys_sorted()) {
        std::cout << "BOOK BUY  price=" << o->price
                  << " qty="            << o->qty
                  << " order_id="       << o->id << "\n";
    }
    for (const Order* o : book.resting_asks_sorted()) {
        std::cout << "BOOK SELL price=" << o->price
                  << " qty="            << o->qty
                  << " order_id="       << o->id << "\n";
    }
}

static void print_usage(const char* prog) {
    std::cerr << "\nBatched Arbitration Matching Engine  v1.0\n\n"
              << "  Usage: " << prog << " <orders.csv> [--bench]\n\n"
              << "  Input format (CSV, one order per line):\n"
              << "    timestamp,order_id,side,price,quantity\n"
              << "    # lines beginning with '#' are comments; blank lines ignored\n\n"
              << "  Flags:\n"
              << "    --bench   print throughput metrics to stderr after run\n\n"
              << "  Constants:\n"
              << "    BATCH_SIZE = " << BATCH_SIZE << "\n"
              << "    MAX_PRICE  = " << MAX_PRICE  << " (valid: 1.." << (MAX_PRICE-1) << ")\n\n"
              << "  Trade price rule : sell-side price\n"
              << "  Priority order   : price > timestamp > order_id\n\n";
}

// ============================================================
// main
// ============================================================

int main(int argc, char* argv[]) {
    if (argc < 2) {
        print_usage(argv[0]);
        return 1;
    }

    std::string path      = argv[1];
    bool        bench     = false;

    if (path == "--help" || path == "-h") {
        print_usage(argv[0]);
        return 0;
    }

    for (int k = 2; k < argc; ++k) {
        if (std::string(argv[k]) == "--bench") bench = true;
    }

    std::ifstream file(path);
    if (!file.is_open()) {
        std::cerr << "error: cannot open '" << path << "'\n";
        return 1;
    }

    // ---- Engine loop --------------------------------------------------------
    auto t_start = std::chrono::high_resolution_clock::now();

    OrderBook           book;
    std::vector<Order>  batch;
    batch.reserve(BATCH_SIZE);

    uint32_t batch_num   = 0;
    uint32_t line_num    = 0;
    uint64_t total_orders = 0;

    std::string line;
    while (std::getline(file, line)) {
        ++line_num;

        // Strip trailing CR for Windows CRLF files.
        if (!line.empty() && line.back() == '\r') line.pop_back();

        // Skip blank lines and comment lines.
        if (line.empty() || line[0] == '#') continue;

        Order order{};
        if (!parse_order_line(line, line_num, order)) continue;

        batch.push_back(order);
        ++total_orders;

        if (batch.size() == BATCH_SIZE) {
            flush_batch(book, batch, ++batch_num);
        }
    }

    // Flush partial final batch.
    if (!batch.empty()) {
        flush_batch(book, batch, ++batch_num);
    }

    // Print residual order book.
    print_book(book);

    // ---- Benchmark report (stderr only, does not pollute stdout) ------------
    if (bench) {
        auto   t_end = std::chrono::high_resolution_clock::now();
        double secs  = std::chrono::duration<double>(t_end - t_start).count();

        std::cerr << "\n--- Benchmark Report ---\n"
                  << "Orders processed : " << total_orders     << "\n"
                  << "Batches          : " << batch_num        << "\n"
                  << "Wall time        : " << secs * 1000.0    << " ms\n"
                  << "Throughput       : "
                  << static_cast<uint64_t>(total_orders / (secs > 0 ? secs : 1.0))
                  << " orders/sec\n";
    }

    return 0;
}
