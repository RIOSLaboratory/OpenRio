ROOT := $(abspath ..)
ISA_DPI_DIR ?= $(ROOT)/dpi
ISA_MODEL_ROOT ?= $(abspath $(ROOT)/..)
# Same variable name as mk/common.mk; ISA_INSTALL is kept as a legacy alias.
ISA_MODEL_INSTALL ?= $(if $(ISA_INSTALL),$(ISA_INSTALL),$(ISA_MODEL_ROOT))
# Match mk/common.mk: the release pair is vendored in dpi/, an external release
# under include/ and lib/ overrides it, then a full-checkout under src/libs and
# build.  An unreachable ISA_MODEL_INSTALL falls through to the vendored pair.
ISA_API_INC ?= $(if $(wildcard $(ISA_MODEL_INSTALL)/include/IsaApi.h),$(ISA_MODEL_INSTALL)/include,$(if $(wildcard $(ISA_MODEL_INSTALL)/src/libs/IsaApi.h),$(ISA_MODEL_INSTALL)/src/libs,$(ISA_DPI_DIR)))
ISA_API_LIB ?= $(if $(wildcard $(ISA_MODEL_INSTALL)/lib/lib_ISA_api.so),$(ISA_MODEL_INSTALL)/lib,$(if $(wildcard $(ISA_MODEL_INSTALL)/build/lib_ISA_api.so),$(ISA_MODEL_INSTALL)/build,$(ISA_DPI_DIR)))
ISA_ABI_CHECKER ?= $(ROOT)/tools/check_isa_api_release.py
PYTHON ?= python3
ISA_CFG ?= $(ISA_DPI_DIR)/rivai_0x80000000_1core_rom.yaml
ELF ?=
BUILD_DIR ?= $(CURDIR)/build
OBJ_DIR := $(BUILD_DIR)/obj_dir
TOP := orbe_fe_mock_tb_top
SIM := $(OBJ_DIR)/V$(TOP)
TIMEOUT_CYCLES ?= 100
MIN_FIRE_COUNT ?= 8
SCENARIO ?= ready_all
REDIRECT_CYCLE ?= 8
REDIRECT_PC ?= 0x80000050
SECOND_REDIRECT_CYCLE ?= 9
SECOND_REDIRECT_PC ?= 0x80000070
FETCH_EXCEPTION_PC ?= 0x80000001
FETCH_EXCEPTION_CAUSE ?= 0
FETCH_EXCEPTION_TVAL_OFFSET ?= 0
ifneq ($(filter $(SCENARIO),fetch_exception fetch_exception_under_stall),)
FORCE_FETCH_EXCP ?= 1
else
FORCE_FETCH_EXCP ?= 0
endif
VERBOSE_FIRE ?= 0
WAVE ?= 0

VERILATOR ?= verilator

SV_SOURCES := \
	$(ISA_DPI_DIR)/isa_dpi_pkg.sv \
	$(CURDIR)/orbe_fe_mock_if.sv \
	$(CURDIR)/orbe_fe_mock_fe_agent.sv \
	$(CURDIR)/orbe_fe_mock_wrapper.sv \
	$(CURDIR)/orbe_fe_mock_monitor.sv \
	$(CURDIR)/orbe_fe_mock_tb_top.sv

CPP_SOURCES := $(ISA_DPI_DIR)/isa_dpi_wrapper.cc

VERILATOR_FLAGS := --binary --timing --trace --top-module $(TOP) \
	-Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
	--timescale 1ns/1ps \
	--Mdir $(OBJ_DIR) \
	-CFLAGS "-std=c++17 -I$(ISA_API_INC)" \
	-LDFLAGS "-L$(ISA_API_LIB) -l_ISA_api -Wl,-rpath,$(ISA_API_LIB)"

.PHONY: all build lint run clean help check_isa_abi

all: build

build: $(SIM)

# Fail before Verilator when the ISA model release pair does not match the DPI
# wrapper, instead of letting the C++ compile fail with a less obvious error.
check_isa_abi:
	@$(PYTHON) $(ISA_ABI_CHECKER) --inc "$(ISA_API_INC)" --lib "$(ISA_API_LIB)"

$(SIM): $(SV_SOURCES) $(CPP_SOURCES)
	@$(PYTHON) $(ISA_ABI_CHECKER) --inc "$(ISA_API_INC)" --lib "$(ISA_API_LIB)"
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) $(SV_SOURCES) $(CPP_SOURCES)

lint:
	$(VERILATOR) --lint-only --timing --top-module $(TOP) \
		-Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
		--timescale 1ns/1ps $(SV_SOURCES)

run: build
	@test -n "$(ELF)" || { echo "ELF=/absolute/path/to/case.riscv is required"; exit 2; }
	@test -r "$(ELF)" || { echo "ELF is not readable: $(ELF)"; exit 2; }
	@test -r "$(ISA_CFG)" || { echo "ISA_CFG is not readable: $(ISA_CFG)"; exit 2; }
	LD_LIBRARY_PATH=$(ISA_API_LIB)$${LD_LIBRARY_PATH:+:$${LD_LIBRARY_PATH}} \
		$(SIM) +ISA_CFG=$(abspath $(ISA_CFG)) +ISA_ELF=$(abspath $(ELF)) \
		+MOCK_SCENARIO=$(SCENARIO) \
		+MOCK_TIMEOUT_CYCLES=$(TIMEOUT_CYCLES) \
		+MOCK_MIN_FIRE_COUNT=$(MIN_FIRE_COUNT) \
		+MOCK_REDIRECT_CYCLE=$(REDIRECT_CYCLE) \
		+MOCK_REDIRECT_PC=$(REDIRECT_PC) \
		+MOCK_SECOND_REDIRECT_CYCLE=$(SECOND_REDIRECT_CYCLE) \
		+MOCK_SECOND_REDIRECT_PC=$(SECOND_REDIRECT_PC) \
		+MOCK_FETCH_EXCEPTION_PC=$(FETCH_EXCEPTION_PC) \
		+MOCK_FORCE_FETCH_EXCP=$(FORCE_FETCH_EXCP) \
		+MOCK_FORCE_FETCH_EXCP_PC=$(FETCH_EXCEPTION_PC) \
		+MOCK_FORCE_FETCH_EXCP_CAUSE=$(FETCH_EXCEPTION_CAUSE) \
		+MOCK_FORCE_FETCH_EXCP_TVAL_OFFSET=$(FETCH_EXCEPTION_TVAL_OFFSET) \
		+MOCK_VERBOSE_FIRE=$(VERBOSE_FIRE) \
		+ISA_RUN_LOG=$(BUILD_DIR)/isa_run.log \
		+ISA_COMMIT_LOG=$(BUILD_DIR)/isa_commit.log \
		$(if $(filter 1,$(WAVE)),+WAVE_FILE=$(BUILD_DIR)/waves.vcd,)

clean:
	rm -rf $(BUILD_DIR)

help:
	@printf '%s\n' \
		'make lint' \
		'make check_isa_abi' \
		'make build' \
		'make run ELF=/absolute/path/to/case.riscv' \
		'make run ELF=/absolute/path/to/case.riscv TIMEOUT_CYCLES=100 MIN_FIRE_COUNT=8' \
		'make run SCENARIO=redirect_normal REDIRECT_PC=0x80000050 ELF=/absolute/path/to/case.riscv' \
		'make run SCENARIO=redirect_twice REDIRECT_PC=0x80000050 SECOND_REDIRECT_PC=0x80000070 ELF=/absolute/path/to/case.riscv' \
		'make run SCENARIO=fetch_exception ELF=/absolute/path/to/case.riscv' \
		'make run SCENARIO=fetch_exception_under_stall MIN_FIRE_COUNT=1 ELF=/absolute/path/to/case.riscv' \
		'make run ELF=/absolute/path/to/case.riscv VERBOSE_FIRE=1' \
		'make run ELF=/absolute/path/to/case.riscv WAVE=1'
