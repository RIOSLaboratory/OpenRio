# User-facing verification parameters. Build implementation is in ../mk/.
VCS      ?= vcs
CXX      ?= g++
OBJDUMP  ?= riscv64-unknown-elf-objdump
PYTHON   ?= python3

TOP      ?= be_tb_top
DUT_KIND ?= mock
TEST     ?= elf
SYS      ?= sys_be_new
FCOV     ?= 0
PIPEVIEW ?= 0
TAG      ?= $(shell date +%Y%m%d)
TAG      := $(TAG)
SEED     ?= 1
LANES    ?= 4
TC       ?=
PLUSARGS ?=
WAVE     ?= none
FSDB_NAME ?= waves.fsdb
SIM_TIMEOUT ?= 200
# Delay a completed read-side result before Cache Agent presents it to DUT.
# Leave unset to preserve be_config's default of zero cycles.
CACHE_LOAD_RETURN_DELAY_CYCLES ?=
# Delay only the Cache Agent ROB-done response for store-side operations.
# Leave unset to preserve be_config's default of zero cycles.
CACHE_STORE_DONE_DELAY_CYCLES ?=
# A positive value stops simulation once the reporter has emitted this many
# errors. Leave unset to keep the SystemVerilog default of zero (disabled).
ERROR_LIMIT ?=
# Leave cosim unset unless the caller explicitly overrides the SystemVerilog
# defaults in be_config::new().
COSIM_ENABLE ?=
COSIM_BACKEND ?=
# During regression, force cosim off for normalized case names in this
# comma-separated list. The runner owns the per-case comparison.
COSIM_DISABLE_CASE ?=
REGRESSION_REPORT_INTERVAL ?= 5
REGRESSION_JOBS ?= 1

MAKEFILE_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
SIM_WORK_DIR ?= $(abspath $(MAKEFILE_DIR)..)

# Keep recursive make invocations on the same user-selected namespace and
# expose the regression controls to the Python runner.
export SYS FCOV PIPEVIEW TAG WAVE FSDB_NAME SIM_TIMEOUT DUT_KIND CACHE_LOAD_RETURN_DELAY_CYCLES CACHE_STORE_DONE_DELAY_CYCLES ERROR_LIMIT COSIM_ENABLE COSIM_BACKEND COSIM_DISABLE_CASE SIM_WORK_DIR \
	REGRESSION_REPORT_INTERVAL REGRESSION_JOBS

include $(MAKEFILE_DIR)../mk/common.mk
