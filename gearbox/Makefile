# defaults
SIM ?= verilator
TOPLEVEL_LANG ?= verilog

# parameters
IN_DATA_WIDTH ?= 24
OUT_DATA_WIDTH ?= 40
WAVES ?= 1

ifeq ($(TOPLEVEL_LANG),verilog)

    VERILOG_SOURCES = $(PWD)/../common/common_pkg.sv
    VERILOG_SOURCES += $(PWD)/gearbox.sv

    ifeq ($(SIM),icarus)
        COMPILE_ARGS += -Pgearbox.IN_DATA_WIDTH=$(IN_DATA_WIDTH)
        COMPILE_ARGS += -Pgearbox.OUT_DATA_WIDTH=$(OUT_DATA_WIDTH)

    else ifeq ($(SIM),verilator)
        COMPILE_ARGS += -GIN_DATA_WIDTH=$(IN_DATA_WIDTH)
        COMPILE_ARGS += -GOUT_DATA_WIDTH=$(OUT_DATA_WIDTH)
        COMPILE_ARGS += --timing
        COMPILE_ARGS += --assert
        COMPILE_ARGS += -Wno-WIDTHTRUNC

        ifeq ($(WAVES),1)
            EXTRA_ARGS += --trace
            EXTRA_ARGS += --trace-structs
        endif

    else ifneq ($(filter $(SIM),ius xcelium),)
        EXTRA_ARGS += -defparam "gearbox.IN_DATA_WIDTH=$(IN_DATA_WIDTH)"
        EXTRA_ARGS += -defparam "gearbox.OUT_DATA_WIDTH=$(OUT_DATA_WIDTH)"

    endif

    ifneq ($(filter $(SIM),riviera activehdl),)
        COMPILE_ARGS += -sv2k12
    endif

else
    $(error A valid value verilog was not provided for TOPLEVEL_LANG=$(TOPLEVEL_LANG))
endif

TOPLEVEL = gearbox
COCOTB_TEST_MODULES = testbench

include $(shell cocotb-config --makefiles)/Makefile.sim

.PHONY: clean
clean::
	@$(RM) -rf __pycache__
