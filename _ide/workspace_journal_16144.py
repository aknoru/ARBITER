# 2026-04-19T19:07:03.333089900
import vitis

client = vitis.create_client()
client.set_workspace(path="BAME")

platform = client.create_platform_component(name = "bameplatform",hw_design = "$COMPONENT_LOCATION/../vivado/bame_master/bamewrapper.xsa",os = "standalone",cpu = "ps7_cortexa9_0",domain_name = "standalone_ps7_cortexa9_0",compiler = "gcc")

platform = client.get_component(name="bameplatform")
status = platform.build()

comp = client.create_app_component(name="app_bame",platform = "$COMPONENT_LOCATION/../bameplatform/export/bameplatform/bameplatform.xpfm",domain = "standalone_ps7_cortexa9_0")

comp = client.get_component(name="app_bame")
status = comp.import_files(from_loc="", files=["C:\arbiter\BAME\cpp\zedboard_driver.cpp"], is_skip_copy_sources = False)

status = platform.build()

comp = client.get_component(name="app_bame")
comp.build()

status = platform.build()

comp.build()

vitis.dispose()

