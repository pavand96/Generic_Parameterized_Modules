# defaults
SIM ?= verilator
TOPLEVEL_LANG ?= verilog

# parameters
IN_DB ?= 3
OUT_DB ?= 5
WAVES ?= 1

ifeq ($(TOPLEVEL_LANG),verilog)

    VERILOG_SOURCES = $(PWD)/gearbox.sv

    ifeq ($(SIM),icarus)
        COMPILE_ARGS += -Pgearbox.IN_DB=$(IN_DB)
        COMPILE_ARGS += -Pgearbox.OUT_DB=$(OUT_DB)

    else ifeq ($(SIM),verilator)
        COMPILE_ARGS += -GIN_DB=$(IN_DB)
        COMPILE_ARGS += -GOUT_DB=$(OUT_DB)
        COMPILE_ARGS += --timing
        COMPILE_ARGS += -Wno-WIDTHTRUNC

        ifeq ($(WAVES),1)
            EXTRA_ARGS += --trace
            EXTRA_ARGS += --trace-structs
        endif

    else ifneq ($(filter $(SIM),ius xcelium),)
        EXTRA_ARGS += -defparam "gearbox.IN_DB=$(IN_DB)"
        EXTRA_ARGS += -defparam "gearbox.OUT_DB=$(OUT_DB)"

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
