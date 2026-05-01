# defaults
SIM ?= verilator
TOPLEVEL_LANG ?= verilog

# parameters
INPUT_BYTES_PER_BEAT ?= 3
OUTPUT_BYTES_PER_BEAT ?= 5
WAVES ?= 1

ifeq ($(TOPLEVEL_LANG),verilog)

    VERILOG_SOURCES = $(PWD)/gearbox.sv

    ifeq ($(SIM),icarus)
        COMPILE_ARGS += -Pgearbox.INPUT_BYTES_PER_BEAT=$(INPUT_BYTES_PER_BEAT)
        COMPILE_ARGS += -Pgearbox.OUTPUT_BYTES_PER_BEAT=$(OUTPUT_BYTES_PER_BEAT)

    else ifeq ($(SIM),verilator)
        COMPILE_ARGS += -GINPUT_BYTES_PER_BEAT=$(INPUT_BYTES_PER_BEAT)
        COMPILE_ARGS += -GOUTPUT_BYTES_PER_BEAT=$(OUTPUT_BYTES_PER_BEAT)
        COMPILE_ARGS += --timing
        COMPILE_ARGS += --assert
        COMPILE_ARGS += -Wno-WIDTHTRUNC

        ifeq ($(WAVES),1)
            EXTRA_ARGS += --trace
            EXTRA_ARGS += --trace-structs
        endif

    else ifneq ($(filter $(SIM),ius xcelium),)
        EXTRA_ARGS += -defparam "gearbox.INPUT_BYTES_PER_BEAT=$(INPUT_BYTES_PER_BEAT)"
        EXTRA_ARGS += -defparam "gearbox.OUTPUT_BYTES_PER_BEAT=$(OUTPUT_BYTES_PER_BEAT)"

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
