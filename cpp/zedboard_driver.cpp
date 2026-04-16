/**
 * BAME ZedBoard Driver  —  Physical Hardware Test
 * =============================================================================
 * This application runs on the ZedBoard ARM Core (Linux) to communicate
 * with the BAME engine over the AXI bus.
 *
 * Base Address: 0x40000000
 * Registers:
 *   0x00: Control (Bit 0=Reset/Start, Bit 1=Flush)
 *   0x04: Status (Bits 6:0=FSM State)
 * =============================================================================
 */

#include <iostream>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <stdint.h>

#define BAME_BASE_ADDR   0x40000000
#define BAME_REG_CONTROL 0x00
#define BAME_REG_STATUS  0x04
#define MAP_SIZE         4096

int main() {
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
        std::cerr << "Error: Could not open /dev/mem (requires root/sudo)\n";
        return 1;
    }

    // Map the AXI-Lite register space
    void* map_base = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, BAME_BASE_ADDR);
    if (map_base == MAP_FAILED) {
        std::cerr << "Error: mmap failed\n";
        close(fd);
        return 1;
    }

    volatile uint32_t* bame_regs = (volatile uint32_t*)map_base;

    std::cout << "--- BAME Hardware Diagnostics ---\n";

    // 1. Reset the core
    std::cout << "Resetting BAME Core...\n";
    bame_regs[BAME_REG_CONTROL / 4] = 0x01;
    usleep(100);
    bame_regs[BAME_REG_CONTROL / 4] = 0x00;

    // 2. Read FSM State
    uint32_t status = bame_regs[BAME_REG_STATUS / 4];
    std::cout << "Current State: 0x" << std::hex << (status & 0x7F) << std::dec << " (expected 0x1 for IDLE)\n";

    if ((status & 0x7F) == 0x01) {
        std::cout << "SUCCESS: Hardware is responding on AXI bus!\n";
    } else {
        std::cout << "WARNING: Hardware in unexpected state.\n";
    }

    // 3. Cleanup
    munmap(map_base, MAP_SIZE);
    close(fd);
    return 0;
}
