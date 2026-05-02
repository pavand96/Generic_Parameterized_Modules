# defaults
SIM ?= verilator
TOPLEVEL_LANG ?= verilog

# parameters
INPUT_CHUNKS_PER_BEAT ?= 3
OUTPUT_CHUNKS_PER_BEAT ?= 5
BITS_PER_CHUNK ?= 8
WAVES ?= 1

export BITS_PER_CHUNK

ifeq ($(TOPLEVEL_LANG),verilog)

    VERILOG_SOURCES = $(PWD)/gearbox.sv

    ifeq ($(SIM),icarus)
        COMPILE_ARGS += -Pgearbox.INPUT_CHUNKS_PER_BEAT=$(INPUT_CHUNKS_PER_BEAT)
        COMPILE_ARGS += -Pgearbox.OUTPUT_CHUNKS_PER_BEAT=$(OUTPUT_CHUNKS_PER_BEAT)
        COMPILE_ARGS += -Pgearbox.BITS_PER_CHUNK=$(BITS_PER_CHUNK)

    else ifeq ($(SIM),verilator)
        COMPILE_ARGS += -GINPUT_CHUNKS_PER_BEAT=$(INPUT_CHUNKS_PER_BEAT)
        COMPILE_ARGS += -GOUTPUT_CHUNKS_PER_BEAT=$(OUTPUT_CHUNKS_PER_BEAT)
        COMPILE_ARGS += -GBITS_PER_CHUNK=$(BITS_PER_CHUNK)
        COMPILE_ARGS += --timing
        COMPILE_ARGS += --assert
        COMPILE_ARGS += -Wno-WIDTHTRUNC

        ifeq ($(WAVES),1)
            EXTRA_ARGS += --trace
            EXTRA_ARGS += --trace-structs
        endif

    else ifneq ($(filter $(SIM),ius xcelium),)
        EXTRA_ARGS += -defparam "gearbox.INPUT_CHUNKS_PER_BEAT=$(INPUT_CHUNKS_PER_BEAT)"
        EXTRA_ARGS += -defparam "gearbox.OUTPUT_CHUNKS_PER_BEAT=$(OUTPUT_CHUNKS_PER_BEAT)"
        EXTRA_ARGS += -defparam "gearbox.BITS_PER_CHUNK=$(BITS_PER_CHUNK)"

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
