# Standalone VCS + Verdi FSDB flow for the ORBE COSIM testbench.
#
# This directory is intentionally independent of:
#   - verification/or_cosim/tools/verilator_cosim.sh
#   - verification/or_cosim/tools/regress.sh
#
# It only *reads* the existing TB/RTL filelists and DPI wrapper:
#   verification/or_cosim/cfg/filelist/*
#   verification/or_cosim/dpi/*
# It does not modify the Verilator flow.
#
# Usage on a VCS-capable host (cad21):
#   source env.sh                     # VCS_HOME / VERDI_HOME / gcc14 / ISA_MODEL_ROOT
#   make check
#   make build TAG=vcs1 DUT_KIND=rtl_full
#   make fsdb  TAG=vcs1 DUT_KIND=rtl_full TC=$ISA_MODEL_ROOT/isa_case/rv64ui/rv64ui-p-add.riscv
#
# Design notes borrowed from openrios/verification/beta_be_bt_new:
#   * every simv is compiled with the FSDB PLI, and WAVE only selects at runtime;
#     one build therefore serves both a silent run and an FSDB run.
#   * -Mupdate keeps the VCS -Mdir database and recompiles only stale units.
#   * LD_LIBRARY_PATH must cover both the DPI library and the ISA model library
#     at VCS link time and at simv run time, because -sv_lib is a dlopen.
#   * the ISA model is built on the same host, with the gcc14 toolchain that
#     the function-model env.sh exports; a .so built on another glibc cannot
#     be loaded here.

MK_DIR      := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
REPO_ROOT   := $(abspath $(MK_DIR)/../..)
OR_COSIM    := $(REPO_ROOT)/verification/or_cosim
CFG_DIR     := $(OR_COSIM)/cfg/filelist
DPI_DIR     := $(OR_COSIM)/dpi

VCS         ?= vcs
VCS_EXTRA_FLAGS ?=
CXX         ?= g++
TOP         ?= be_tb_top
DUT_KIND    ?= rtl_full
# 1 = pass +define+SYNTHESIS (site default, matches the RTL team's flow).
# 0 = keep the `ifndef SYNTHESIS` assertions alive: use it to debug a stall,
# because with 1 the RTL assertions are compiled out and can only mask bugs.
DEFINE_SYNTHESIS ?= 1
TAG         ?= $(shell date +%Y%m%d)
SEED        ?= 1
WAVE        ?= fsdb
TC          ?=
PLUSARGS    ?=

# VCS/Verdi installation roots.  Override on the command line or export them:
#   export VCS_HOME=/eda/synopsys/vcs/T-2022.06-SP2
#   export VERDI_HOME=/eda/synopsys/verdi/T-2022.06-SP2-3
VCS_BIN_PATH ?= $(shell command -v $(VCS) 2>/dev/null)
VCS_HOME    ?= $(if $(VCS_BIN_PATH),$(shell dirname $$(dirname $(VCS_BIN_PATH)) 2>/dev/null),)
VCS_INCLUDE_DIR ?= $(VCS_HOME)/include
VERDI_HOME  ?= $(NOVAS_HOME)
FSDB_PLI_DIR ?= $(VERDI_HOME)/share/PLI/VCS/LINUX64

# ISA model.  Two layouts are accepted and detected from the tree itself:
#   build tree   : $(ISA_MODEL_ROOT)/src/libs/IsaApi.h + build/lib_ISA_api.so
#   install tree : $(ISA_MODEL_ROOT)/include/IsaApi.h  + lib/lib_ISA_api.so
# The header must be the revision the DPI wrapper was written against; the
# internal function-model tree moved its BE metadata into include/ext and is
# NOT interchangeable with this wrapper.
ISA_MODEL_ROOT ?= $(HOME)/isa_model
ifeq ($(wildcard $(ISA_MODEL_ROOT)/include/IsaApi.h),)
  ISA_MODEL_LAYOUT ?= build
  ISA_API_INC ?= $(ISA_MODEL_ROOT)/src/libs
  ISA_API_LIB ?= $(ISA_MODEL_ROOT)/build
else
  ISA_MODEL_LAYOUT ?= install
  ISA_API_INC ?= $(ISA_MODEL_ROOT)/include
  ISA_API_LIB ?= $(ISA_MODEL_ROOT)/lib
endif
ISA_CFG        ?= $(DPI_DIR)/rivai_0x80000000_1core_rom.yaml

# Verilator-equivalent runtime knobs.  Defaults mirror the COSIM flow.
SIM_TIMEOUT      ?= 2000000
VERBOSITY        ?= 3
COSIM_ENABLE     ?= 1
COSIM_BACKEND    ?= isa_step
COSIM_OB_LOG     ?= 1
ISA_LOG          ?= all

# Per-DUT filelist and defines.  Keep this table in sync with
# verification/or_cosim/tools/verilator_cosim.sh.
ifeq ($(DUT_KIND),agent)
  RTL_FILE    := rtl_agent.f
  DUT_DEFINES := +define+ORBE_DUT_AGENT
else ifeq ($(DUT_KIND),rtl_v1)
  RTL_FILE    := rtl_v1.f
  DUT_DEFINES := +define+ORBE_DUT_RTL_V1
else ifeq ($(DUT_KIND),rtl_fe)
  RTL_FILE    := rtl_fe.f
  DUT_DEFINES := +define+ORBE_DUT_RTL_V1 +define+ORBE_FE_RTL
else ifeq ($(DUT_KIND),rtl_cache)
  RTL_FILE    := rtl_cache.f
  DUT_DEFINES := +define+ORBE_DUT_RTL_V1 +define+ORBE_CACHE_RTL
else ifeq ($(DUT_KIND),rtl_full)
  RTL_FILE    := rtl_full.f
  DUT_DEFINES := +define+ORBE_DUT_RTL_V1 +define+ORBE_FE_RTL +define+ORBE_CACHE_RTL
else
  $(error unsupported DUT_KIND='$(DUT_KIND)'; expected agent, rtl_v1, rtl_fe, rtl_cache, rtl_full)
endif

CFG_COMMON := $(CFG_DIR)/common.f
CFG_RTL    := $(CFG_DIR)/$(RTL_FILE)
CFG_TB     := $(CFG_DIR)/tb.f
DPI_PKG    := $(DPI_DIR)/isa_dpi_pkg.sv
DPI_WRAPPER := $(DPI_DIR)/isa_dpi_wrapper.cc

# tb/agents/be/be_bfm.sv is the RTL stand-in for DUT_KIND=agent (see the header
# of cfg/filelist/rtl_agent.f).  Under the rtl_* kinds be_tb_top.sv never
# instantiates it -- the instantiation sits inside `elsif ORBE_DUT_AGENT -- yet
# tb.f lists it unconditionally, and VCS rejects its parameterized interface
# port (ob_cosim_if #(...) in an ANSI port list) with a syntax error.  Filter
# the file out unless the agent DUT is selected; Verilator tolerates it, so the
# shared tb.f stays untouched.
TB_FILELIST := $(CFG_TB)
ifneq ($(DUT_KIND),agent)
  TB_FILELIST := $(MK_DIR)sim/filelist/tb_$(DUT_KIND).f
endif

# isa_dpi_pkg.sv must precede common.f: orbe_predictor_pkg imports it.
SV_INPUTS := $(DPI_PKG) -f $(CFG_COMMON) -f $(CFG_RTL) -f $(TB_FILELIST)

# Artifacts live next to the Verilator ones so the two engines can be compared
# file by file:
#   or_cosim/sim/verilator_<TAG>/{log,regress}/...      (verilator_cosim.sh)
#   or_cosim/sim/vcs_<TAG>/{build,log,regress}/...      (this Makefile)
# VCS_WORK_ROOT can still be pointed elsewhere (a scratch disk, or a test rig).
# WAVE is deliberately NOT part of the namespace: the build is FSDB-capable and
# WAVE only selects the runtime behaviour, so one simv covers both modes.
VCS_WORK_ROOT ?= $(OR_COSIM)/sim
BUILD_DIR     := $(VCS_WORK_ROOT)/vcs_$(TAG)/build/$(DUT_KIND)
OBJ_DIR       := $(BUILD_DIR)/obj
SIMV          := $(BUILD_DIR)/simv
COMPILE_LOG   := $(BUILD_DIR)/compile.log
DPI_LIB       := $(BUILD_DIR)/dpi/libisa_dpi.so
DPI_LIB_BASE  := $(patsubst %.so,%,$(DPI_LIB))

LOG_DIR       := $(VCS_WORK_ROOT)/vcs_$(TAG)/log
TC_ABS        := $(abspath $(TC))
ELF_NAME      := $(firstword $(subst ., ,$(notdir $(TC))))
ifeq ($(strip $(ELF_NAME)),)
  ELF_NAME := no_elf
endif
CASE_DIR      := $(LOG_DIR)/$(DUT_KIND)/$(ELF_NAME)_$(SEED)
SIM_LOG       := $(CASE_DIR)/sim.log
FSDB_FILE     := $(CASE_DIR)/$(ELF_NAME).fsdb
ISA_RUN_LOG   := $(CASE_DIR)/isa_run.log
ISA_COMMIT_LOG:= $(CASE_DIR)/isa_commit.log

# FSDB support is compiled in unconditionally.  The TB block sits behind
# `ifdef VCS_FSDB and checks +WAVE at runtime, so WAVE=none simply skips the
# dump call without needing a different simv.
ifneq ($(filter $(WAVE),fsdb none),$(WAVE))
  $(error unsupported WAVE='$(WAVE)'; expected fsdb or none)
endif
FSDB_FLAGS    := +define+VCS_FSDB \
                 -P $(FSDB_PLI_DIR)/novas.tab $(FSDB_PLI_DIR)/pli.a
# Recursive (=) so the fsdb target can override WAVE without a second build.
FSDB_RUN_ARGS = $(if $(filter fsdb,$(WAVE)),\
                   +WAVE=fsdb +FSDB_FILE=$(abspath $(FSDB_FILE)),+WAVE=none)

ifeq ($(ISA_LOG),all)
  ISA_LOG_ARGS := +ISA_RUN_LOG=$(abspath $(ISA_RUN_LOG)) \
                  +ISA_COMMIT_LOG=$(abspath $(ISA_COMMIT_LOG))
else ifeq ($(ISA_LOG),commit)
  ISA_LOG_ARGS := +ISA_COMMIT_LOG=$(abspath $(ISA_COMMIT_LOG))
else ifeq ($(ISA_LOG),none)
  ISA_LOG_ARGS :=
else
  $(error unsupported ISA_LOG='$(ISA_LOG)'; expected all, commit, none)
endif

# Recursive expansion: WAVE can be overridden per target (see the fsdb rule).
SIM_ARGS = +TEST=elf \
            +ntb_random_seed=$(SEED) \
            +SIM_TIMEOUT_CYCLES=$(SIM_TIMEOUT) \
            +VERBOSITY=$(VERBOSITY) \
            +COSIM_ENABLE=$(COSIM_ENABLE) \
            +COSIM_BACKEND=$(COSIM_BACKEND) \
            +COSIM_OB_LOG=$(COSIM_OB_LOG) \
            +ISA_CFG=$(abspath $(ISA_CFG)) \
            +ISA_ELF=$(TC_ABS) \
            $(ISA_LOG_ARGS) \
            $(FSDB_RUN_ARGS) \
            $(PLUSARGS)

# -Mupdate reuses the persistent -Mdir database and recompiles only the stale
# compilation units, which is what makes an incremental TB edit cheap.
VCS_FLAGS := -full64 -sverilog -timescale=1ns/1ps \
             -debug_access+all -kdb \
             -top $(TOP) \
             -Mdir=$(OBJ_DIR) -Mupdate \
             -o $(SIMV) \
             -l $(COMPILE_LOG) \
             $(if $(filter 1,$(DEFINE_SYNTHESIS)),+define+SYNTHESIS,) \
             +define+ORBE_EXTERNAL_MNEMONICS \
             $(DUT_DEFINES) \
             $(FSDB_FLAGS) \
             $(VCS_EXTRA_FLAGS) \
             $(SV_INPUTS)

VCS_DEPS := $(DPI_PKG) $(CFG_COMMON) $(CFG_RTL) $(CFG_TB) $(TB_FILELIST) $(DPI_WRAPPER) \
            $(ISA_API_INC)/IsaApi.h $(ISA_API_LIB)/lib_ISA_api.so

# Regenerate the filtered tb filelist whenever the shared one changes.  Keeping
# the filter in a build artefact means the tracked cfg/filelist/tb.f (shared
# with the Verilator flow) is never rewritten.
$(MK_DIR)sim/filelist/tb_$(DUT_KIND).f: $(CFG_TB)
	@mkdir -p $(dir $@)
	@grep -v 'agents/be/be_bfm\.sv' $< > $@
	@echo "[vcs] DUT_KIND=$(DUT_KIND): be_bfm.sv excluded -> $@"

.PHONY: all check build run fsdb clean help

all: build

check:
	@test -n "$(VCS_HOME)" || { echo "error: set VCS_HOME (VCS installation root)"; exit 1; }
	@test -r "$(VCS_INCLUDE_DIR)/svdpi.h" || { echo "error: missing $(VCS_INCLUDE_DIR)/svdpi.h; set VCS_INCLUDE_DIR to the directory that contains svdpi.h"; exit 1; }
	@test -r "$(ISA_API_INC)/IsaApi.h" || { echo "error: missing $(ISA_API_INC)/IsaApi.h; set ISA_MODEL_ROOT (layout=$(ISA_MODEL_LAYOUT))"; exit 1; }
	@test -r "$(ISA_API_LIB)/lib_ISA_api.so" || { echo "error: missing $(ISA_API_LIB)/lib_ISA_api.so; set ISA_MODEL_ROOT (layout=$(ISA_MODEL_LAYOUT))"; exit 1; }
	@test -r "$(ISA_CFG)" || { echo "error: missing ISA config: $(ISA_CFG)"; exit 1; }
	@test -r "$$($(CXX) -print-file-name=crti.o 2>/dev/null)" || { echo "error: $(CXX) cannot locate crti.o -- build on the host whose toolchain matches (cad21), not on the Verilator host (dev2)"; exit 1; }
	@test -n "$(VERDI_HOME)" || { echo "error: set VERDI_HOME; every simv is compiled with the FSDB PLI"; exit 1; }
	@test -r "$(FSDB_PLI_DIR)/novas.tab" || { echo "error: missing $(FSDB_PLI_DIR)/novas.tab"; exit 1; }
	@test -r "$(FSDB_PLI_DIR)/pli.a" || { echo "error: missing $(FSDB_PLI_DIR)/pli.a"; exit 1; }
	@echo "layout=$(ISA_MODEL_LAYOUT) inc=$(ISA_API_INC) lib=$(ISA_API_LIB) wave=$(WAVE)"

build: check $(SIMV)

# The DPI library is dlopen-ed by simv, so the ISA model library directory must
# be on the runtime path; @rpath alone is not enough when LD_LIBRARY_PATH is set.
$(DPI_LIB): $(DPI_WRAPPER) $(ISA_API_INC)/IsaApi.h $(ISA_API_LIB)/lib_ISA_api.so
	@mkdir -p $(dir $@)
	$(CXX) -std=c++17 -O2 -fPIC -shared \
	  -I$(ISA_API_INC) -I$(VCS_INCLUDE_DIR) \
	  $(DPI_WRAPPER) -L$(ISA_API_LIB) -l_ISA_api \
	  -Wl,-rpath,$(ISA_API_LIB) -o $@

# VCS elaborates -sv_lib at link time too, so the runtime path is applied here
# as well as in the run rule.
# A changed VCS_FLAGS must force a rebuild: without this stamp, editing
# DEFINE_SYNTHESIS / VCS_EXTRA_FLAGS silently reuses the previous simv and the
# experiment runs against the old binary (found the hard way).
FLAGS_STAMP := $(BUILD_DIR)/.vcs_flags

$(FLAGS_STAMP): FORCE
	@mkdir -p $(dir $@)
	@printf '%s\n' '$(VCS_FLAGS)' | cmp -s - $@ || printf '%s\n' '$(VCS_FLAGS)' > $@

FORCE:

$(SIMV): $(DPI_LIB) $(VCS_DEPS) $(FLAGS_STAMP)
	@mkdir -p $(BUILD_DIR) $(OBJ_DIR)
	cd $(OR_COSIM) && \
	  LD_LIBRARY_PATH=$(ISA_API_LIB):$(dir $(DPI_LIB))$${LD_LIBRARY_PATH:+:$${LD_LIBRARY_PATH}} \
	  $(VCS) $(VCS_FLAGS)

# bash + pipefail so a non-zero simv exit status survives the tee.  A -l file
# only records simulator-managed output, so DPI printf would be lost without
# capturing the process streams here.
run: SHELL := /bin/bash
run: .SHELLFLAGS := -o pipefail -c
run: check $(SIMV)
	@test -n "$(TC)" || { echo "error: TC=<path/to/*.riscv> is required"; exit 1; }
	@test -r "$(TC_ABS)" || { echo "error: ELF is not readable: $(TC)"; exit 1; }
	@mkdir -p "$(CASE_DIR)"
	cd $(OR_COSIM) && \
	  LD_LIBRARY_PATH=$(ISA_API_LIB):$(dir $(DPI_LIB))$${LD_LIBRARY_PATH:+:$${LD_LIBRARY_PATH}} \
	  $(SIMV) -sv_lib $(DPI_LIB_BASE) $(SIM_ARGS) 2>&1 | tee $(SIM_LOG)
	@echo "sim_log: $(abspath $(SIM_LOG))"
	@if [ "$(WAVE)" = "fsdb" ]; then echo "fsdb: $(abspath $(FSDB_FILE))"; fi

# Runtime-only switch: no recompilation, the same simv produces the FSDB.
fsdb: WAVE := fsdb
fsdb: run

# Only this tag's own artefacts. Never rm -rf $(VCS_WORK_ROOT): that root is
# or_cosim/sim, which also holds every verilator_<TAG> tree.
clean:
	rm -rf $(VCS_WORK_ROOT)/vcs_$(TAG)

help:
	@echo "Standalone VCS flow (does not touch the Verilator flow)"
	@echo ""
	@echo "Required:"
	@echo "  VCS_HOME, VERDI_HOME, ISA_MODEL_ROOT, CC, CXX (gcc14)"
	@echo ""
	@echo "Targets:"
	@echo "  make check                                  # validate tools and paths"
	@echo "  make build TAG=vcs1 DUT_KIND=rtl_full       # FSDB-capable simv"
	@echo "  make fsdb  TAG=vcs1 DUT_KIND=rtl_full TC=...  # runtime FSDB switch"
	@echo "  make run   TAG=vcs1 DUT_KIND=rtl_full TC=... WAVE=none  # no waveform"
	@echo "  vcs_cosim/regress.sh rtl_full vcs1 16       # batch 239, same output as the Verilator flow"
	@echo "  make clean"
	@echo ""
	@echo "WAVE is a runtime choice: the same simv serves WAVE=none and WAVE=fsdb."
	@echo "The default WAVE is fsdb; pass WAVE=none for a silent run."
	@echo ""
	@echo "Artifacts live under or_cosim/sim, mirroring the Verilator engine:"
	@echo "  build : $(BUILD_DIR)"
	@echo "  logs  : $(LOG_DIR)"
	@echo ""
	@echo "Current values:"
	@echo "  VCS              = $(VCS)"
	@echo "  VCS_EXTRA_FLAGS  = $(VCS_EXTRA_FLAGS)"
	@echo "  VCS_HOME         = $(VCS_HOME)"
	@echo "  VCS_INCLUDE_DIR  = $(VCS_INCLUDE_DIR)"
	@echo "  VERDI_HOME       = $(VERDI_HOME)"
	@echo "  FSDB_PLI_DIR     = $(FSDB_PLI_DIR)"
	@echo "  ISA_MODEL_ROOT   = $(ISA_MODEL_ROOT)"
	@echo "  ISA_API_INC      = $(ISA_API_INC)"
	@echo "  ISA_API_LIB      = $(ISA_API_LIB)"
	@echo "  DUT_KIND         = $(DUT_KIND)"
	@echo "  RTL_FILE         = $(RTL_FILE)"
	@echo "  WAVE             = $(WAVE)"
