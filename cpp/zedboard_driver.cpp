/**
 * BAME ZedBoard Driver — Full Streaming Test
 * =============================================================================
 * Bridges the CPU to the BAME Hardware Engine via AXI-Lite and AXI-Stream FIFO.
 * =============================================================================
 */

#include <iostream>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <stdint.h>
#include <vector>

// ---- Memory Map ----
#define ADDR_WRAPPER     0x40000000
#define ADDR_FIFO        0x43C00000
#define MAP_SIZE         65536

// ---- FIFO Registers (AXI-Stream FIFO) ----
#define FIFO_TDFV        (0x14/4)  // Transmit Vacancy
#define FIFO_TDFD        (0x18/4)  // Transmit Data Write
#define FIFO_TLF         (0x1C/4)  // Transmit Length
#define FIFO_RDFO        (0x24/4)  // Receive Occupancy
#define FIFO_RDFD        (0x28/4)  // Receive Data Read
#define FIFO_RLF         (0x2C/4)  // Receive Length

// ---- BAME Core Registers ----
#define CORE_CONTROL     (0x00/4)
#define CORE_STATUS      (0x04/4)

struct OrderWords {
    uint32_t w[8]; // 256 bits per our AXI-Stream wrapper config
};

void send_order(volatile uint32_t* fifo, const OrderWords& order) {
    // 1. Wait for vacancy
    while (fifo[FIFO_TDFV] < 8);
    
    // 2. Write 8 words (256 bits)
    for (int i = 0; i < 8; ++i) {
        fifo[FIFO_TDFD] = order.w[i];
    }
    
    // 3. Set length (32 bytes = 8 words)
    fifo[FIFO_TLF] = 32;
}

int main() {
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open"); return 1; }

    void* virt_wrapper = mmap(NULL, MAP_SIZE, PROT_READ|PROT_WRITE, MAP_SHARED, fd, ADDR_WRAPPER);
    void* virt_fifo    = mmap(NULL, MAP_SIZE, PROT_READ|PROT_WRITE, MAP_SHARED, fd, ADDR_FIFO);
    
    volatile uint32_t* regs = (volatile uint32_t*)virt_wrapper;
    volatile uint32_t* fifo = (volatile uint32_t*)virt_fifo;

    std::cout << "--- BAME Full SoC Streaming Test ---\n";

    // 1. Hardware Reset
    regs[CORE_CONTROL] = 0x01; 
    usleep(100); 
    regs[CORE_CONTROL] = 0x00;

    // 2. Prepare Match (Buy @ 100, Sell @ 99)
    OrderWords buy_order = {0};
    // Layout: [144:81] ID, [80:65] Price, [64:33] Qty, [32:1] TS, [0] Side
    // 145 bits total. Let's pack manually.
    buy_order.w[0] = 0x00000001; // Side=1 (Buy), TS=0 (indices approximated)
    buy_order.w[1] = 10;         // Qty=10
    buy_order.w[2] = 100;        // Price=100
    buy_order.w[3] = 101;        // ID=101 (lower)
    
    OrderWords sell_order = {0};
    sell_order.w[0] = 0x00000000; // Side=0 (Sell)
    sell_order.w[1] = 5;          // Qty=5
    sell_order.w[2] = 99;         // Price=99
    sell_order.w[3] = 102;        // ID=102

    std::cout << "Pushing Buy Order (ID=101, P=100)...\n";
    send_order(fifo, buy_order);
    
    std::cout << "Pushing Sell Order (ID=102, P=99)...\n";
    send_order(fifo, sell_order);

    std::cout << "Requesting Flush...\n";
    regs[CORE_CONTROL] = 0x02; // Bit 1 = Flush

    // 3. Poll for Outcome
    std::cout << "Waiting for trades...\n";
    int timeout = 1000;
    while (fifo[FIFO_RDFO] == 0 && timeout--) usleep(100);

    if (fifo[FIFO_RDFO] > 0) {
        uint32_t len = fifo[FIFO_RLF];
        std::cout << "Trade Received! (Length: " << len << " bytes)\n";
        for (uint32_t i = 0; i < len/4; ++i) {
            std::cout << "  Word[" << i << "]: 0x" << std::hex << fifo[FIFO_RDFD] << std::dec << "\n";
        }
    } else {
        std::cout << "Timeout: No trade generated.\n";
    }

    return 0;
}
