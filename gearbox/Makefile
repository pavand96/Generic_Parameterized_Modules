# defaults
SIM ?= verilator
TOPLEVEL_LANG ?= verilog

# parameters
IN_CHUNKS_PER_BEAT ?= 3
OUT_CHUNKS_PER_BEAT ?= 5
CHUNK_WIDTH ?= 8
WAVES ?= 1

export CHUNK_WIDTH

ifeq ($(TOPLEVEL_LANG),verilog)

    VERILOG_SOURCES = $(PWD)/gearbox.sv

    ifeq ($(SIM),icarus)
        COMPILE_ARGS += -Pgearbox.IN_CHUNKS_PER_BEAT=$(IN_CHUNKS_PER_BEAT)
        COMPILE_ARGS += -Pgearbox.OUT_CHUNKS_PER_BEAT=$(OUT_CHUNKS_PER_BEAT)
        COMPILE_ARGS += -Pgearbox.CHUNK_WIDTH=$(CHUNK_WIDTH)

    else ifeq ($(SIM),verilator)
        COMPILE_ARGS += -GIN_CHUNKS_PER_BEAT=$(IN_CHUNKS_PER_BEAT)
        COMPILE_ARGS += -GOUT_CHUNKS_PER_BEAT=$(OUT_CHUNKS_PER_BEAT)
        COMPILE_ARGS += -GCHUNK_WIDTH=$(CHUNK_WIDTH)
        COMPILE_ARGS += --timing
        COMPILE_ARGS += --assert
        COMPILE_ARGS += -Wno-WIDTHTRUNC

        ifeq ($(WAVES),1)
            EXTRA_ARGS += --trace
            EXTRA_ARGS += --trace-structs
        endif

    else ifneq ($(filter $(SIM),ius xcelium),)
        EXTRA_ARGS += -defparam "gearbox.IN_CHUNKS_PER_BEAT=$(IN_CHUNKS_PER_BEAT)"
        EXTRA_ARGS += -defparam "gearbox.OUT_CHUNKS_PER_BEAT=$(OUT_CHUNKS_PER_BEAT)"
        EXTRA_ARGS += -defparam "gearbox.CHUNK_WIDTH=$(CHUNK_WIDTH)"

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
