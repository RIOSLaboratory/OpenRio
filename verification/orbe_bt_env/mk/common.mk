# Shared build, simulation, logging, and ELF handling rules.

MKDIR_P ?= mkdir -p
REMOVE  ?= rm -rf

# Resolve paths from this file, not from the caller's current directory.
ROOT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)

SIM_DIR ?= $(ROOT_DIR)/sim
DUT_KIND ?= mock
# Keep every generated artifact below the SYS+TAG namespace.  Override
# VCS_CACHE_ROOT to a local SSD when the source checkout itself is on a network
# filesystem; the default preserves the requested sim/$(SYS)_$(TAG)/build/
# hierarchy.
SYS_TAG_DIR ?= $(SIM_DIR)/$(SYS)_$(TAG)
BUILD_ROOT ?= $(SYS_TAG_DIR)/build
VCS_CACHE_ROOT ?= $(BUILD_ROOT)
MNEMONICS_DECODER ?= 0
VCS_CACHE_KEY ?= $(SYS)_$(TOP)_dut$(DUT_KIND)_lanes$(LANES)_fcov$(FCOV)_pipeview$(PIPEVIEW)_mnemonics$(MNEMONICS_DECODER)
RTL_LIB_DIR ?= $(VCS_CACHE_ROOT)/rtl_lib
TB_BUILD_DIR ?= $(VCS_CACHE_ROOT)/tb_build
BUILD_DIR ?= $(TB_BUILD_DIR)
SIM ?= $(BUILD_DIR)/simv
LOG_DIR ?= $(SYS_TAG_DIR)/log
SIM_WORK_DIR ?= $(ROOT_DIR)
# VCS does not expose a separately linkable SV logical library in this flow.
# Its persistent -Mdir database is the compatible RTL/TB compilation cache;
# VCS uses -Mupdate to rebuild only stale compilation units from it.
VCS_OBJ_DIR ?= $(RTL_LIB_DIR)/vcs_obj
SIM_MAKEFILE := $(SIM_DIR)/Makefile

COMMON_FILELIST := $(ROOT_DIR)/cfg/filelist/common.f
TB_FILELIST := $(ROOT_DIR)/cfg/filelist/tb.f
ifeq ($(DUT_KIND),mock)
RTL_FILELIST ?= $(ROOT_DIR)/cfg/filelist/rtl_mock.f
else ifeq ($(DUT_KIND),rtl_v1)
RTL_FILELIST ?= $(ROOT_DIR)/cfg/filelist/rtl_v1.f
else
RTL_FILELIST ?= $(ROOT_DIR)/cfg/filelist/rtl_$(DUT_KIND).f
endif

# The ISA model is not part of this repository; it ships separately as a binary
# release pair (include/IsaApi.h plus lib/lib_ISA_api.so) or as a full checkout
# for internal development.  Point ISA_MODEL_INSTALL at whatever holds it, or
# set ISA_API_INC/ISA_API_LIB directly.
ISA_MODEL_ROOT ?= $(abspath $(ROOT_DIR)/..)
ISA_MODEL_INSTALL ?= $(ISA_MODEL_ROOT)
ISA_API_INC ?= $(if $(wildcard $(ISA_MODEL_INSTALL)/include/IsaApi.h),$(ISA_MODEL_INSTALL)/include,$(ISA_MODEL_INSTALL)/src/libs)
ISA_API_LIB ?= $(if $(wildcard $(ISA_MODEL_INSTALL)/lib/lib_ISA_api.so),$(ISA_MODEL_INSTALL)/lib,$(ISA_MODEL_INSTALL)/build)
# Resolve the two release files through wildcard().  A missing file then drops
# out of the prerequisite list instead of failing with make's bare "No rule to
# make target", so check_isa_abi reports the real problem and how to fix it.
ISA_API_HEADER := $(wildcard $(ISA_API_INC)/IsaApi.h)
# The active DPI adapter and platform configuration are project-owned sources.
ISA_DPI_DIR ?= $(ROOT_DIR)/dpi
# Keep the DPI shared object with the other build products for this SYS+TAG.
# Its compile stamp includes VCS_HOME so a different VCS ABI invalidates it.
ISA_DPI_BUILD ?= $(VCS_CACHE_ROOT)/dpi
ISA_DPI_PKG := $(ISA_DPI_DIR)/isa_dpi_pkg.sv
ISA_DPI_WRAPPER := $(ISA_DPI_DIR)/isa_dpi_wrapper.cc
ISA_DPI_LIB ?= $(ISA_DPI_BUILD)/libisa_dpi.so
ISA_DPI_AUTO_LIB := $(abspath $(ISA_DPI_BUILD)/libisa_dpi.so)
ISA_DPI_LIB_IS_AUTO := $(if $(filter $(ISA_DPI_AUTO_LIB),$(abspath $(ISA_DPI_LIB))),1,)
ISA_DPI_LIB_BASE := $(patsubst %.so,%,$(abspath $(ISA_DPI_LIB)))
ISA_MODEL_LIB := $(ISA_API_LIB)/lib_ISA_api.so
ISA_MODEL_LIBDIR := $(ISA_API_LIB)
# IsaApi.h is hand maintained next to the model sources, so the release pair can
# drift from this DPI wrapper.  check_isa_api_release.py derives the required
# declarations and symbols from ISA_DPI_WRAPPER, so the check follows the
# wrapper as it grows.
ISA_ABI_CHECKER := $(ROOT_DIR)/tools/check_isa_api_release.py
ISA_CFG ?= $(ISA_DPI_DIR)/rivai_0x80000000_1core_rom.yaml
ISA_CFG_ABS := $(abspath $(ISA_CFG))
export TEST LANES DUT_KIND ISA_CFG ISA_DPI_LIB OBJDUMP PLUSARGS VCS_CACHE_ROOT VCS_CACHE_KEY
export CACHE_LOAD_RETURN_DELAY_CYCLES CACHE_STORE_DONE_DELAY_CYCLES ERROR_LIMIT COSIM_ENABLE COSIM_BACKEND COSIM_DISABLE_CASE
export ISA_MODEL_ROOT ISA_MODEL_INSTALL ISA_API_INC ISA_API_LIB ISA_DPI_DIR ISA_DPI_BUILD VCS CXX VCS_HOME FSDB_PLI_DIR VCS_EXTRA_FLAGS

PYTHON ?= python3

# Regression input and generated control files.  ELF_DIR is intentionally
# separate from TC: TC remains the single-case interface used by run/sim.
# Discover ELF files by their file(1) signature, not by their filename.
ELF_DIR ?=
TC_LIST ?=
ELF_DIR_NORMALIZED := $(subst \,/,$(strip $(ELF_DIR)))
ELF_DIR_ABS :=
TC_TARGET :=
ifneq ($(strip $(ELF_DIR)),)
ELF_DIR_ABS := $(abspath $(ELF_DIR_NORMALIZED))
TC_LIST := $(shell find "$(ELF_DIR_ABS)" -type f -print0 2>/dev/null | \
	xargs -0 -r file 2>/dev/null | \
	egrep 'ELF' | cut -d: -f1)
TC_TARGET := $(addprefix tc_,$(TC_LIST))
endif
REGRESSION_RUNNER ?= $(ROOT_DIR)/tools/regression_runner.py
REGRESSION_MANIFEST ?= $(SYS_TAG_DIR)/regression_manifest.json
REGRESSION_REPORT_DIR ?= $(SIM_DIR)/regression_report
REGRESSION_REPORT ?= $(REGRESSION_REPORT_DIR)/$(SYS)_$(TAG)_regression_report.md
TASKS_FILE ?= $(SYS_TAG_DIR)/$(TAG)_tasks.txt
ENV_SETUP ?=
ENV_SETUP_EFFECTIVE := $(if $(strip $(ENV_SETUP)),$(ENV_SETUP),$(ROOT_DIR)/be_bt_env.sh)
# Kept for users of the old explicit helper target; normal regression runs
# now use the Python runner and these files are no longer generated.
REGRESSION_LIST ?= $(SYS_TAG_DIR)/regression.list
REGRESSION_SCRIPT ?= $(SYS_TAG_DIR)/regression.sh

# Case directories use only the filename portion before its first dot, so a
# file such as test.riscv and the corresponding single-case run share a log
# directory. Normalize Windows separators for WSL callers.
TC_NORMALIZED := $(subst \,/,$(strip $(TC)))
TC_ABS := $(abspath $(TC_NORMALIZED))
ELF_NAME := $(firstword $(subst ., ,$(notdir $(TC_NORMALIZED))))
ifeq ($(strip $(ELF_NAME)),)
ELF_NAME := no_elf
endif

CASE_DIR ?= $(LOG_DIR)/$(ELF_NAME)_$(SEED)
COMPILE_LOG ?= $(BUILD_DIR)/compile.log
SIM_LOG ?= $(CASE_DIR)/sim.log
FSDB_FILE ?= $(CASE_DIR)/$(FSDB_NAME)
ISA_RUN_LOG ?= $(CASE_DIR)/isa_run.log
ISA_COMMIT_LOG ?= $(CASE_DIR)/isa_commit.log
DUMP_FILE ?= $(CASE_DIR)/$(ELF_NAME).dump
SIM_TIMEOUT ?= 200
CACHE_LOAD_RETURN_DELAY_CYCLES ?=
CACHE_STORE_DONE_DELAY_CYCLES ?=
ERROR_LIMIT ?=
# Leave these unset by default so the `be_config::new()` defaults remain
# authoritative. An explicitly supplied Make variable becomes a runtime
# plusarg and intentionally overrides that SystemVerilog configuration.
COSIM_ENABLE ?=
COSIM_BACKEND ?=
COSIM_DISABLE_CASE ?=
DUMP_INPUT := $(wildcard $(TC_ABS))

VCS_CONFIG_STAMP := $(RTL_LIB_DIR)/.vcs_compile_config_$(VCS_CACHE_KEY).stamp
DPI_CONFIG_STAMP := $(ISA_DPI_BUILD)/.dpi_compile_config_$(VCS_CACHE_KEY).stamp
# Records a successful ISA model release pair check.  It is a real file, not a
# phony target, so depending on it does not force a DPI rebuild.
ISA_ABI_STAMP := $(ISA_DPI_BUILD)/.isa_abi_$(VCS_CACHE_KEY).stamp

# SYS selects the macro profile used by the VCS compile. Keep this table in
# common.mk so future systems can add a profile without changing Makefile
# rules. FCOV and PIPEVIEW add their optional feature defines.
SYS_VCS_FLAGS :=
SYS_DEFINES :=
ifeq ($(SYS),sys_be_new)
SYS_VCS_FLAGS += +incdir+/usr/lib64 +v2k +vc \
                 -debug_region+cell+encrypt -lca -LDFLAGS -Wl,--no-as-needed
SYS_DEFINES += +define+TB_SYS_BE
SYS_DEFINES += +define+USE_RRV64_MACRO
SYS_DEFINES += +define+FSDB
SYS_DEFINES += +define+RRV64_VPRF_64
SYS_DEFINES += +define+P600_ENABLE_VEC
SYS_DEFINES += +define+P600_ENABLE_FP
SYS_DEFINES += +define+COSIM_WITH_DPI_SPIKE
SYS_DEFINES += +define+CACHE_V3
SYS_DEFINES += +define+NEW_CACHE_AGENT
SYS_DEFINES += +define+SYNTHESIS
ifeq ($(FCOV),1)
SYS_DEFINES += +define+FCOV_EN
endif
ifeq ($(PIPEVIEW),1)
SYS_DEFINES += +define+PIPEVIEW_EN
endif
ifeq ($(MNEMONICS_DECODER),1)
SYS_DEFINES += +define+ORBE_EXTERNAL_MNEMONICS
endif
else
$(error Unsupported SYS='$(SYS)'; currently only SYS=sys_be_new is defined)
endif

ifeq ($(DUT_KIND),mock)
SYS_DEFINES += +define+ORBE_DUT_MOCK
else ifeq ($(DUT_KIND),rtl_v1)
SYS_DEFINES += +define+ORBE_DUT_RTL_V1
else
$(error Unsupported DUT_KIND='$(DUT_KIND)'; expected mock or rtl_v1)
endif

VCS_EXTRA_FLAGS ?=
VCS_FLAGS := -full64 -sverilog -timescale=1ns/1ps \
             -debug_access+all -kdb -l $(COMPILE_LOG) \
             -Mdir=$(VCS_OBJ_DIR) -Mupdate \
             -f $(COMMON_FILELIST) -f $(RTL_FILELIST) \
             $(ISA_DPI_PKG) -f $(TB_FILELIST) \
             -top $(TOP) -o $(SIM) \
             $(SYS_VCS_FLAGS) $(SYS_DEFINES) $(VCS_EXTRA_FLAGS)
COSIM_SIM_ARGS :=
ifneq ($(strip $(COSIM_ENABLE)),)
COSIM_SIM_ARGS += +COSIM_ENABLE=$(COSIM_ENABLE)
endif
ifneq ($(strip $(COSIM_BACKEND)),)
COSIM_SIM_ARGS += +COSIM_BACKEND=$(COSIM_BACKEND)
endif
ERROR_LIMIT_SIM_ARGS :=
ifneq ($(strip $(ERROR_LIMIT)),)
ERROR_LIMIT_SIM_ARGS += +ERROR_LIMIT=$(ERROR_LIMIT)
endif
CACHE_LOAD_RETURN_DELAY_SIM_ARGS :=
ifneq ($(strip $(CACHE_LOAD_RETURN_DELAY_CYCLES)),)
CACHE_LOAD_RETURN_DELAY_SIM_ARGS += +CACHE_LOAD_RETURN_DELAY_CYCLES=$(CACHE_LOAD_RETURN_DELAY_CYCLES)
endif
CACHE_STORE_DONE_DELAY_SIM_ARGS :=
ifneq ($(strip $(CACHE_STORE_DONE_DELAY_CYCLES)),)
CACHE_STORE_DONE_DELAY_SIM_ARGS += +CACHE_STORE_DONE_DELAY_CYCLES=$(CACHE_STORE_DONE_DELAY_CYCLES)
endif
CACHE_LOAD_RETURN_DELAY_REGRESSION_ARGS :=
ifneq ($(strip $(CACHE_LOAD_RETURN_DELAY_CYCLES)),)
CACHE_LOAD_RETURN_DELAY_REGRESSION_ARGS += --cache-load-return-delay-cycles "$(CACHE_LOAD_RETURN_DELAY_CYCLES)"
endif
CACHE_STORE_DONE_DELAY_REGRESSION_ARGS :=
ifneq ($(strip $(CACHE_STORE_DONE_DELAY_CYCLES)),)
CACHE_STORE_DONE_DELAY_REGRESSION_ARGS += --cache-store-done-delay-cycles "$(CACHE_STORE_DONE_DELAY_CYCLES)"
endif
SIM_ARGS := +TEST=$(TEST) +ntb_random_seed=$(SEED) \
            +SIM_TIMEOUT_CYCLES=$(SIM_TIMEOUT) \
            $(COSIM_SIM_ARGS) \
            $(CACHE_LOAD_RETURN_DELAY_SIM_ARGS) \
            $(CACHE_STORE_DONE_DELAY_SIM_ARGS) \
            $(ERROR_LIMIT_SIM_ARGS) \
            -sv_lib $(ISA_DPI_LIB_BASE) \
            +ISA_CFG=$(ISA_CFG_ABS) \
            +ISA_ELF=$(TC_ABS) \
            +ISA_RUN_LOG=$(abspath $(ISA_RUN_LOG)) \
            +ISA_COMMIT_LOG=$(abspath $(ISA_COMMIT_LOG)) \
            $(PLUSARGS)

# Compile every simulator with FSDB support.  WAVE is a runtime selection so
# an existing simv can switch between WAVE=none and WAVE=fsdb without VCS.
ifeq ($(strip $(FSDB_PLI_DIR)),)
ifeq ($(strip $(VERDI_HOME)),)
VERDI_HOME ?= $(NOVAS_HOME)
endif
ifneq ($(strip $(VERDI_HOME)),)
FSDB_PLI_DIR := $(VERDI_HOME)/share/PLI/VCS/LINUX64
endif
endif
VCS_FLAGS += +define+DUMP_FSDB \
             -P $(FSDB_PLI_DIR)/novas.tab $(FSDB_PLI_DIR)/pli.a
SIM_ARGS += +WAVE=$(WAVE)
ifeq ($(WAVE),fsdb)
SIM_ARGS += +FSDB_FILE=$(abspath $(FSDB_FILE))
endif

# Keep Make's dependency graph split as well: changing a TB file invokes VCS,
# but -Mupdate recompiles only that TB unit before elaborating a new simv.
#
# The DUT sources are exactly the entries cfg/filelist/rtl_<dut>.f names, and the
# VCS command below already compiles that filelist.  Deriving the dependency list
# from the same file keeps the filelist the single place that knows where the RTL
# tree lives, so no repository specific RTL path has to be repeated here and a
# checkout that keeps its RTL somewhere else only edits the filelist.  Set
# RTL_SOURCE_ROOTS to add extra trees that the filelist does not cover.
RTL_SOURCE_ROOTS ?=
RTL_FILELIST_ENTRIES := $(shell cat $(RTL_FILELIST) 2>/dev/null)
RTL_SOURCES := $(foreach src,$(filter %.sv %.v %.vh,$(RTL_FILELIST_ENTRIES)),$(if $(wildcard $(ROOT_DIR)/$(src)),$(abspath $(ROOT_DIR)/$(src)),))
RTL_SOURCES += $(shell for d in $(RTL_SOURCE_ROOTS); do \
	test ! -d "$$d" || find "$$d" -type f \( -name '*.sv' -o -name '*.v' -o -name '*.vh' \); \
done 2>/dev/null)
TB_SOURCES := $(shell find "$(ROOT_DIR)/tb" "$(ROOT_DIR)/tests" -type f \( -name '*.sv' -o -name '*.v' -o -name '*.vh' \) 2>/dev/null)
COMMON_DEPS := $(SIM_MAKEFILE) $(ROOT_DIR)/mk/common.mk $(COMMON_FILELIST) $(ISA_DPI_PKG) $(ISA_DPI_WRAPPER)
RTL_DEPS := $(RTL_FILELIST) $(RTL_SOURCES)
TB_DEPS := $(TB_FILELIST) $(TB_SOURCES)
VCS_DEPS := $(COMMON_DEPS) $(RTL_DEPS) $(TB_DEPS)

# Do not share a -Mdir across incompatible settings.  VCS_CACHE_KEY encodes
# the standard compile configuration; callers must set a new key when adding
# incompatible site-specific VCS options.
VCS_CACHE_CONFIG := CACHE_KEY=$(VCS_CACHE_KEY) VCS=$(VCS) TOP=$(TOP) DUT_KIND=$(DUT_KIND) LANES=$(LANES) SYS=$(SYS) FCOV=$(FCOV) PIPEVIEW=$(PIPEVIEW) TIMESCALE=1ns/1ps SYS_VCS_FLAGS=$(SYS_VCS_FLAGS) SYS_DEFINES=$(SYS_DEFINES) VCS_EXTRA_FLAGS=$(VCS_EXTRA_FLAGS) FSDB_PLI_DIR=$(FSDB_PLI_DIR)
DPI_CACHE_CONFIG := CXX=$(CXX) VCS_HOME=$(VCS_HOME) ISA_DPI_DIR=$(ISA_DPI_DIR) ISA_MODEL_INSTALL=$(ISA_MODEL_INSTALL) ISA_API_INC=$(ISA_API_INC) ISA_API_LIB=$(ISA_API_LIB) ISA_MODEL_LIB=$(ISA_MODEL_LIB)

.PHONY: all build build_all compile compile_rtl compile_tb compile_dpi sim run dump fsdb gen_task regression regression_report +tag clean clean_cache help check_isa_inputs check_regression_inputs check_isa_abi

all: run

# compile is the incremental compile phase used by run.  The three explicit
# entry points make dependency ownership clear while sharing one VCS cache;
# VCS itself selects the individual stale source units via -Mupdate.
compile: compile_dpi compile_rtl compile_tb
compile_rtl: $(SIM)
compile_tb: $(SIM)
compile_dpi: $(ISA_DPI_LIB)

# build is deliberately incremental.  Use clean or clean_cache only when a
# fresh image or a fresh compiler database is explicitly required.
build: compile

# Rebuild every VCS source and the DPI wrapper for the current SYS+TAG
# namespace.  Other SYS+TAG namespaces remain intact.
build_all:
	$(REMOVE) "$(BUILD_DIR)" "$(VCS_OBJ_DIR)" $(if $(ISA_DPI_LIB_IS_AUTO),"$(ISA_DPI_LIB)")
	$(MAKE) --no-print-directory -C "$(SIM_DIR)" compile \
		SYS="$(SYS)" TOP="$(TOP)" LANES="$(LANES)" FCOV="$(FCOV)" PIPEVIEW="$(PIPEVIEW)" TAG="$(TAG)" \
		DUT_KIND="$(DUT_KIND)" \
		VCS="$(VCS)" CXX="$(CXX)" VCS_EXTRA_FLAGS="$(VCS_EXTRA_FLAGS)" \
		FSDB_PLI_DIR="$(FSDB_PLI_DIR)" ISA_MODEL_INSTALL="$(ISA_MODEL_INSTALL)" ISA_DPI_DIR="$(ISA_DPI_DIR)" \
		ISA_DPI_BUILD="$(ISA_DPI_BUILD)" ISA_DPI_LIB="$(ISA_DPI_LIB)" \
		WAVE="$(WAVE)" FSDB_NAME="$(FSDB_NAME)" VCS_CACHE_ROOT="$(VCS_CACHE_ROOT)" \
		VCS_CACHE_KEY="$(VCS_CACHE_KEY)"

$(SIM): $(ISA_DPI_LIB) $(VCS_DEPS) $(VCS_CONFIG_STAMP)
	@test -n "$(FSDB_PLI_DIR)" || { echo "FSDB-capable builds require VERDI_HOME, NOVAS_HOME, or FSDB_PLI_DIR"; exit 1; }
	@test -r "$(FSDB_PLI_DIR)/novas.tab" || { echo "missing $(FSDB_PLI_DIR)/novas.tab"; exit 1; }
	@test -r "$(FSDB_PLI_DIR)/pli.a" || { echo "missing $(FSDB_PLI_DIR)/pli.a"; exit 1; }
	$(MKDIR_P) $(BUILD_DIR) $(VCS_OBJ_DIR)
	cd "$(ROOT_DIR)" && LD_LIBRARY_PATH=$(ISA_MODEL_LIBDIR)$${LD_LIBRARY_PATH:+:$${LD_LIBRARY_PATH}} \
	$(VCS) $(VCS_FLAGS) +define+BE_ISSUE_WIDTH=$(LANES) +vcs+

$(VCS_CONFIG_STAMP): $(SIM_MAKEFILE) $(ROOT_DIR)/mk/common.mk
	$(MKDIR_P) "$(RTL_LIB_DIR)"
	$(REMOVE) "$(VCS_OBJ_DIR)"
	@rm -f "$(RTL_LIB_DIR)"/.vcs_compile_config_*.stamp
	@printf '%s\n' '$(VCS_CACHE_CONFIG)' > "$@"

$(DPI_CONFIG_STAMP): $(SIM_MAKEFILE) $(ROOT_DIR)/mk/common.mk
	$(MKDIR_P) "$(ISA_DPI_BUILD)"
	@rm -f "$(ISA_DPI_BUILD)"/.dpi_compile_config_*.stamp
	@printf '%s\n' '$(DPI_CACHE_CONFIG)' > "$@"

# Verify the ISA model release pair before compiling against it.  A drifted
# IsaApi.h fails with a clear message here instead of an obscure error inside the
# wrapper, and a missing symbol is caught before the simulator starts.  These two
# rules are also the only place that reports an ISA model which was not provided
# at all, because the release files are resolved through wildcard() above.
check_isa_abi: $(ISA_ABI_STAMP)

$(ISA_ABI_STAMP): $(ISA_ABI_CHECKER) $(ISA_DPI_WRAPPER) $(ISA_API_HEADER) $(wildcard $(ISA_MODEL_LIB)) $(DPI_CONFIG_STAMP)
	$(MKDIR_P) "$(ISA_DPI_BUILD)"
	@$(PYTHON) "$(ISA_ABI_CHECKER)" --inc "$(ISA_API_INC)" --lib "$(ISA_MODEL_LIBDIR)"
	@printf '%s\\n' 'isa abi check passed' > "$@"

$(ISA_DPI_LIB): $(ISA_DPI_WRAPPER) $(ISA_API_HEADER) $(wildcard $(ISA_MODEL_LIB)) $(DPI_CONFIG_STAMP) $(ISA_ABI_STAMP)
	@test -n "$(VCS_HOME)" || { echo "VCS_HOME must name a VCS installation containing include/svdpi.h"; exit 1; }
	@test -r "$(VCS_HOME)/include/svdpi.h" || { echo "missing $(VCS_HOME)/include/svdpi.h"; exit 1; }
	$(MKDIR_P) $(ISA_DPI_BUILD)
	$(CXX) -std=c++17 -O2 -fPIC -shared \
	  -I"$(ISA_API_INC)" -I"$(VCS_HOME)/include" \
	  "$(ISA_DPI_WRAPPER)" -L"$(ISA_MODEL_LIBDIR)" -l_ISA_api \
	  -o "$(ISA_DPI_LIB)"

check_isa_inputs:
	@test -n "$(TC)" || { echo "TC=<test.elf> is required, for example: make run TC=/path/to/test.elf"; exit 1; }
	@test -r "$(TC_ABS)" || { echo "ELF is not readable: $(TC)"; exit 1; }
	@test -r "$(ISA_CFG_ABS)" || { echo "ISA config is not readable: $(ISA_CFG)"; exit 1; }

check_regression_inputs:
	@test -n "$(ELF_DIR)" || { echo "ELF_DIR=<directory> is required, for example: make regression ELF_DIR=/path/to/elfs"; exit 1; }
	@test -d "$(ELF_DIR_ABS)" || { echo "ELF directory does not exist: $(ELF_DIR)"; exit 1; }
	@command -v file >/dev/null 2>&1 || { echo "file(1) is required to identify ELF files"; exit 1; }
	@test -n "$(TC_LIST)" || { echo "No ELF files recognized by file(1) in: $(ELF_DIR_ABS)"; exit 1; }
	@test -r "$(ISA_CFG_ABS)" || { echo "ISA config is not readable: $(ISA_CFG)"; exit 1; }

dump: check_isa_inputs $(DUMP_FILE)

$(DUMP_FILE): $(DUMP_INPUT)
	@test -n "$(TC)" || { echo "TC=<test.elf> is required to generate a dump"; exit 1; }
	@test -r "$(TC_ABS)" || { echo "ELF is not readable: $(TC)"; exit 1; }
	$(MKDIR_P) $(CASE_DIR)
	$(OBJDUMP) -d "$(TC_ABS)" > "$@"

# sim is simulation-only and never has $(SIM) as a make prerequisite.
SIM_INPUTS :=
ifneq ($(TEST),smoke)
SIM_INPUTS += check_isa_inputs $(DUMP_FILE)
endif

sim: $(SIM_INPUTS)
	@test -f "$(SIM)" || { echo "simulation executable is missing: run 'make build' first"; exit 1; }
	$(MKDIR_P) $(CASE_DIR) $(SIM_WORK_DIR)
	cd "$(SIM_WORK_DIR)" && LD_LIBRARY_PATH=$(ISA_MODEL_LIBDIR)$${LD_LIBRARY_PATH:+:$${LD_LIBRARY_PATH}} \
	"$(SIM)" $(SIM_ARGS) -l $(SIM_LOG)

RUN_INPUTS :=
ifneq ($(TEST),smoke)
RUN_INPUTS += check_isa_inputs
endif

run: $(RUN_INPUTS) compile
	$(MAKE) --no-print-directory -C "$(SIM_DIR)" sim \
		SYS="$(SYS)" FCOV="$(FCOV)" PIPEVIEW="$(PIPEVIEW)" TAG="$(TAG)" \
		DUT_KIND="$(DUT_KIND)" \
		WAVE="$(WAVE)" FSDB_NAME="$(FSDB_NAME)" SIM_TIMEOUT="$(SIM_TIMEOUT)" \
		SIM_WORK_DIR="$(SIM_WORK_DIR)"

fsdb:
	$(MAKE) --no-print-directory -C "$(SIM_DIR)" run WAVE=fsdb FSDB_NAME=$(FSDB_NAME) \
		SYS="$(SYS)" FCOV="$(FCOV)" PIPEVIEW="$(PIPEVIEW)" TAG="$(TAG)" \
		DUT_KIND="$(DUT_KIND)" \
		SIM_TIMEOUT="$(SIM_TIMEOUT)"

gen_task: check_regression_inputs build
	@test -r "$(ENV_SETUP_EFFECTIVE)" || { echo "environment setup script is not readable: $(ENV_SETUP_EFFECTIVE)"; exit 1; }
	@test -r "$(REGRESSION_RUNNER)" || { echo "missing regression runner: $(REGRESSION_RUNNER)"; exit 1; }
	@$(PYTHON) "$(REGRESSION_RUNNER)" gen-task \
		--sys-tag-dir "$(SYS_TAG_DIR)" \
		--log-dir "$(LOG_DIR)" \
		--tasks-path "$(TASKS_FILE)" \
		--elf-dir "$(ELF_DIR_ABS)" \
		--seed "$(SEED)" \
		--test "$(TEST)" \
		--wave "$(WAVE)" \
		--fsdb-name "$(FSDB_NAME)" \
		--sim-timeout "$(SIM_TIMEOUT)" \
		--plusargs "$(PLUSARGS)" \
		--isa-cfg "$(ISA_CFG_ABS)" \
		--isa-dpi-lib "$(ISA_DPI_LIB)" \
		--simv "$(SIM)" \
		--python "$(PYTHON)" \
		--env-setup "$(ENV_SETUP_EFFECTIVE)" \
		--cosim-enable "$(COSIM_ENABLE)" \
		--cosim-backend "$(COSIM_BACKEND)" \
		--cache-load-return-delay-cycles "$(CACHE_LOAD_RETURN_DELAY_CYCLES)" \
		--cache-store-done-delay-cycles "$(CACHE_STORE_DONE_DELAY_CYCLES)" \
		--error-limit "$(ERROR_LIMIT)"

regression: check_regression_inputs
	@test -r "$(REGRESSION_RUNNER)" || { echo "missing regression runner: $(REGRESSION_RUNNER)"; exit 1; }
	@$(PYTHON) "$(REGRESSION_RUNNER)" run \
		--sim-dir "$(SIM_DIR)" \
		--sys-tag-dir "$(SYS_TAG_DIR)" \
		--log-dir "$(LOG_DIR)" \
		--report-path "$(REGRESSION_REPORT)" \
		--elf-dir "$(ELF_DIR_ABS)" \
		--sys "$(SYS)" \
		--tag "$(TAG)" \
		--seed "$(SEED)" \
		--wave "$(WAVE)" \
		--fsdb-name "$(FSDB_NAME)" \
		--sim-timeout "$(SIM_TIMEOUT)" \
		$(CACHE_LOAD_RETURN_DELAY_REGRESSION_ARGS) \
		$(CACHE_STORE_DONE_DELAY_REGRESSION_ARGS) \
		--error-limit "$(ERROR_LIMIT)" \
		--cosim-disable-case "$(COSIM_DISABLE_CASE)" \
		--report-interval "$(REGRESSION_REPORT_INTERVAL)" \
		--plusargs "$(PLUSARGS)" \
		--isa-cfg "$(ISA_CFG_ABS)" \
		--isa-dpi-lib "$(ISA_DPI_LIB)" \
		--make "$(MAKE)" \
		--lanes "$(LANES)" \
		--fcov "$(FCOV)" \
		--pipeview "$(PIPEVIEW)" \
		--jobs "$(REGRESSION_JOBS)"

regression_report:
	@test -r "$(REGRESSION_RUNNER)" || { echo "missing regression runner: $(REGRESSION_RUNNER)"; exit 1; }
	@$(PYTHON) "$(REGRESSION_RUNNER)" report --manifest "$(REGRESSION_MANIFEST)"

+tag: regression_report

ifneq ($(REGRESSION_LEGACY),)
regression_generate: check_regression_inputs
	@set -eu; \
	elf_dir="$(ELF_DIR_ABS)"; \
	log_dir="$(LOG_DIR)"; \
	list="$(REGRESSION_LIST)"; \
	controller="$(REGRESSION_SCRIPT)"; \
	$(MKDIR_P) "$$log_dir"; \
	: > "$$list"; \
	find "$$elf_dir" -type f -print0 | xargs -0 -r file 2>/dev/null | \
	egrep 'ELF' | cut -d: -f1 | LC_ALL=C sort | \
	while IFS= read -r elf; do \
		elf_name=$${elf##*/}; \
		elf_name=$${elf_name%%.*}; \
		case_dir="$$log_dir/$${elf_name}_$(SEED)"; \
		run_script="$$case_dir/run.sh"; \
		$(MKDIR_P) "$$case_dir"; \
		printf '%s\n' "$$elf" > "$$case_dir/elf.path"; \
		printf '%s\n' \
			'#!/usr/bin/env bash' \
			'set -eu' \
			'case_dir=$$(CDPATH= cd -- "$$(dirname -- "$$0")" && pwd)' \
			'tc=$$(cat "$$case_dir/elf.path")' \
			'sim_dir="$(SIM_DIR)"' \
			'exec make --no-print-directory -C "$$sim_dir" sim \' \
				'TC="$$tc" SEED="$(SEED)" \' \
				'WAVE="$(WAVE)" FSDB_NAME="$(FSDB_NAME)" \' \
				'SIM_TIMEOUT="$(SIM_TIMEOUT)"' \
			> "$$run_script"; \
		chmod +x "$$run_script"; \
		printf '%s\n' "$$run_script" >> "$$list"; \
	done; \
	test -s "$$list" || { echo "No .elf files found while generating regression list: $$elf_dir"; exit 1; }; \
	printf '%s\n' \
		'#!/usr/bin/env bash' \
		'set -u' \
		'list="$(REGRESSION_LIST)"' \
		'passed=0' \
		'failed=0' \
		'while IFS= read -r run_script; do' \
		'  [ -n "$$run_script" ] || continue' \
		'  printf "[REGRESSION] %s\\n" "$$run_script"' \
		'  if bash "$$run_script"; then' \
		'    passed=$$((passed + 1))' \
		'  else' \
		'    failed=$$((failed + 1))' \
		'  fi' \
		'done < "$$list"' \
		'printf "[REGRESSION] passed=%d failed=%d\\n" "$$passed" "$$failed"' \
		'[ "$$failed" -eq 0 ]' \
		> "$$controller"; \
	chmod +x "$$controller"; \
	printf '[REGRESSION] list: %s\n' "$$list"; \
	printf '[REGRESSION] controller: %s\n' "$$controller"
endif

clean:
	$(REMOVE) "$(SYS_TAG_DIR)"
	cd "$(ROOT_DIR)" && $(REMOVE) csrc DVEfiles ucli.key *.vpd *.fsdb *.key novas.rc

clean_cache:
	$(REMOVE) "$(VCS_CACHE_ROOT)"

help:
	@echo "make build                         # incremental VCS build"
	@echo "make build_all                     # rebuild all VCS and DPI sources"
	@echo "make compile_rtl|compile_tb|compile_dpi"
	@echo "make check_isa_abi                 # verify IsaApi.h + lib_ISA_api.so against the DPI wrapper"
	@echo "  ISA model lookup: ISA_MODEL_INSTALL/<include|src/libs> and ISA_MODEL_INSTALL/<lib|build>"
	@echo "  A binary release pair under include/ and lib/ wins over src/libs and build"
	@echo "  python3 tools/check_isa_api_release.py --install <isa_model>/install --smoke"
	@echo "make build DUT_KIND=rtl_v1         # build with the backend RTL DUT"
	@echo "make sim TC=/absolute/path/to/test.elf [SEED=1]"
	@echo "make sim TC=/absolute/path/to/test.elf PLUSARGS='+VERBOSITY=2'"
	@echo "make sim TC=/absolute/path/to/test.elf CACHE_LOAD_RETURN_DELAY_CYCLES=3"
	@echo "make sim TC=/absolute/path/to/test.elf CACHE_STORE_DONE_DELAY_CYCLES=3"
	@echo "VERBOSITY: 1=base (default), 2=COSIM/register dumps, 3=FE/BE/cache cycle tracing"
	@echo "make run TC=/absolute/path/to/test.elf"
	@echo "make run TC=/absolute/path/to/test.elf ISA_CFG=/absolute/path/to/platform.yaml"
	@echo "make run TC=/absolute/path/to/test.elf ISA_DPI_LIB=/path/to/libisa_dpi.so"
	@echo "make run TC=/absolute/path/to/test.elf COSIM_ENABLE=1 [COSIM_BACKEND=isa_step]"
	@echo "make run TC=/absolute/path/to/test.elf OBJDUMP=riscv64-unknown-elf-objdump"
	@echo "make sim TC=/absolute/path/to/test.elf WAVE=fsdb FSDB_NAME=waves.fsdb"
	@echo "make sim TC=/absolute/path/to/test.elf SIM_TIMEOUT=200"
	@echo "make run TC=/absolute/path/to/test.elf ERROR_LIMIT=3"
	@echo "make gen_task ELF_DIR=/absolute/path/to/elfs [TAG=local] [SEED=1] [ENV_SETUP=/path/to/env.sh]"
	@echo "make regression ELF_DIR=/absolute/path/to/elfs [SEED=1] [COSIM_DISABLE_CASE=<case[,case...]>] [REGRESSION_REPORT_INTERVAL=5] [REGRESSION_JOBS=1]"
	@echo "make regression_report TAG=<tag>      # rebuild Markdown report from logs"
	@echo "make +tag TAG=<tag>                   # alias of regression_report"
	@echo "SYS+TAG namespace: $(SYS_TAG_DIR)"
	@echo "Build root: $(VCS_CACHE_ROOT) (rtl_lib, tb_build, dpi)"
	@echo "Logs: $(LOG_DIR)"
	@echo "Tasks: $(TASKS_FILE)"
	@echo "Regression report: $(REGRESSION_REPORT)"
	@echo "Set VCS_CACHE_ROOT to a local SSD; VCS_CACHE_KEY identifies incompatible custom VCS options"
	@echo "SIM_TIMEOUT is the simulation timeout in clock cycles"
	@echo "FSDB_PLI_DIR, VERDI_HOME, or NOVAS_HOME is required for every build"
	@echo "make clean"
	@echo "make clean_cache                   # remove all persistent compile caches"
