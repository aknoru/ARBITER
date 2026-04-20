# Additional clean files
cmake_minimum_required(VERSION 3.16)

if("${CONFIG}" STREQUAL "" OR "${CONFIG}" STREQUAL "")
  file(REMOVE_RECURSE
  "C:\\arbiter\\BAME\\bameplatform\\zynq_fsbl\\zynq_fsbl_bsp\\include\\diskio.h"
  "C:\\arbiter\\BAME\\bameplatform\\zynq_fsbl\\zynq_fsbl_bsp\\include\\ff.h"
  "C:\\arbiter\\BAME\\bameplatform\\zynq_fsbl\\zynq_fsbl_bsp\\include\\ffconf.h"
  "C:\\arbiter\\BAME\\bameplatform\\zynq_fsbl\\zynq_fsbl_bsp\\include\\sleep.h"
  "C:\\arbiter\\BAME\\bameplatform\\zynq_fsbl\\zynq_fsbl_bsp\\include\\xilffs.h"
  "C:\\arbiter\\BAME\\bameplatform\\zynq_fsbl\\zynq_fsbl_bsp\\include\\xilffs_config.h"
  "C:\\arbiter\\BAME\\bameplatform\\zynq_fsbl\\zynq_fsbl_bsp\\include\\xilrsa.h"
  "C:\\arbiter\\BAME\\bameplatform\\zynq_fsbl\\zynq_fsbl_bsp\\include\\xiltimer.h"
  "C:\\arbiter\\BAME\\bameplatform\\zynq_fsbl\\zynq_fsbl_bsp\\include\\xtimer_config.h"
  "C:\\arbiter\\BAME\\bameplatform\\zynq_fsbl\\zynq_fsbl_bsp\\lib\\libxilffs.a"
  "C:\\arbiter\\BAME\\bameplatform\\zynq_fsbl\\zynq_fsbl_bsp\\lib\\libxilrsa.a"
  "C:\\arbiter\\BAME\\bameplatform\\zynq_fsbl\\zynq_fsbl_bsp\\lib\\libxiltimer.a"
  )
endif()
