/*
 * SystemVerilog DPI-C adapter for IsaApi.h.
 *
 * The FuncMultiCore pointer is deliberately kept private to this translation
 * unit.  SV never sees the C/C++ pointer.  Each exposed handle is
 * single-core oriented; the normal RTL-driven handle and the optional
 * commit-cosim handle are independent. APIs which retain a core selector
 * still receive model_core_id and should be called with 0 in this setup.
 */
#include "IsaApi.h"

#include <svdpi.h>

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <limits>

namespace {

static_assert(sizeof(decltype(IsaApiDecodeMetadata::is_lsu)) == 1);
static_assert(sizeof(decltype(IsaApiLsuIssueMetadata::req_property)) == 1);
static_assert(sizeof(decltype(IsaApiLsuIssueMetadata::exe_subop)) == 4);
static_assert(sizeof(decltype(IsaApiLsuIssueMetadata::rs1_data)) == 8);
static_assert(sizeof(decltype(IsaApiLsuIssueMetadata::imm_data)) == 8);
static_assert(sizeof(decltype(IsaApiCommitTrapInfo::trap_cause)) == 8);

FuncMultiCore* g_sim = nullptr;
FuncMultiCore* g_cosim_sim = nullptr;

FuncMultiCore* sim_for()
{
    if (g_sim == nullptr) {
        std::fprintf(stderr, "[isa_dpi] model has not been created\n");
        return nullptr;
    }
    return g_sim;
}

FuncMultiCore* cosim_sim_for()
{
    if (g_cosim_sim == nullptr) {
        std::fprintf(stderr, "[isa_cosim_dpi] model has not been created\n");
        return nullptr;
    }
    return g_cosim_sim;
}

bool to_size(std::uint64_t value, std::size_t* result)
{
    if (value > static_cast<std::uint64_t>(std::numeric_limits<std::size_t>::max()))
        return false;
    *result = static_cast<std::size_t>(value);
    return true;
}

void zero_trace(std::uint64_t* paddr,
                std::uint64_t* pte_paddr0, std::uint64_t* pte_paddr1,
                std::uint64_t* pte_paddr2, std::uint64_t* pte_paddr3,
                std::uint64_t* pte_paddr4,
                std::uint64_t* pte_value0, std::uint64_t* pte_value1,
                std::uint64_t* pte_value2, std::uint64_t* pte_value3,
                std::uint64_t* pte_value4,
                std::uint8_t* pte_update, std::uint8_t* levels,
                std::uint64_t* trap_type, std::uint64_t* trap_tval,
                std::uint8_t* trap_valid, std::uint8_t* fault_src,
                std::uint8_t* mem_type)
{
    *paddr = 0;
    *pte_paddr0 = *pte_paddr1 = *pte_paddr2 = *pte_paddr3 = *pte_paddr4 = 0;
    *pte_value0 = *pte_value1 = *pte_value2 = *pte_value3 = *pte_value4 = 0;
    *pte_update = *levels = 0;
    *trap_type = *trap_tval = 0;
    *trap_valid = *fault_src = *mem_type = 0;
}

bool array_has_bytes(svOpenArrayHandle array, std::uint64_t length,
                     void** data)
{
    if (array == nullptr || data == nullptr) return false;
    const int low = svLow(array, 1);
    const int high = svHigh(array, 1);
    const std::uint64_t count = high >= low
        ? static_cast<std::uint64_t>(high - low + 1)
        : 0;
    if (length > count) {
        std::fprintf(stderr,
                     "[isa_dpi] open byte array has %llu elements, requested %llu\n",
                     static_cast<unsigned long long>(count),
                     static_cast<unsigned long long>(length));
        return false;
    }
    *data = svGetArrayPtr(array);
    if (*data == nullptr && length != 0) {
        std::fprintf(stderr, "[isa_dpi] open byte array is not contiguous\n");
        return false;
    }
    return true;
}

} // namespace

extern "C" {

/* ---------- lifecycle ---------- */

int isa_dpi_create(std::uint64_t core_num, std::uint64_t rob_size)
{
    std::size_t cores = 0;
    std::size_t rob = 0;
    if (g_sim != nullptr ||
        !to_size(core_num, &cores) || !to_size(rob_size, &rob)) {
        std::fprintf(stderr, "[isa_dpi_create] model already exists or size is invalid\n");
        return ISA_API_FAIL;
    }
    g_sim = funcMultiCore_create(cores, rob);
    return g_sim != nullptr ? ISA_API_PASS : ISA_API_FAIL;
}

void isa_dpi_destroy()
{
    funcMultiCore_destroy(g_sim);
    g_sim = nullptr;
}

/* ---------- independent step-level cosim model ---------- */

int isa_cosim_dpi_create(std::uint64_t core_num, std::uint64_t rob_size)
{
    std::size_t cores = 0;
    std::size_t rob = 0;
    if (g_cosim_sim != nullptr ||
        !to_size(core_num, &cores) || !to_size(rob_size, &rob)) {
        std::fprintf(stderr,
                     "[isa_cosim_dpi_create] model already exists or size is invalid\n");
        return ISA_API_FAIL;
    }
    g_cosim_sim = funcMultiCore_create(cores, rob);
    return g_cosim_sim != nullptr ? ISA_API_PASS : ISA_API_FAIL;
}

void isa_cosim_dpi_destroy()
{
    funcMultiCore_destroy(g_cosim_sim);
    g_cosim_sim = nullptr;
}

int isa_cosim_dpi_load_config(const char* yaml_path)
{
    FuncMultiCore* sim = cosim_sim_for();
    return sim == nullptr ? ISA_API_FAIL : funcMultiCore_loadConfigFile(sim, yaml_path);
}

int isa_cosim_dpi_load_elf(const char* elf_path)
{
    FuncMultiCore* sim = cosim_sim_for();
    return sim == nullptr ? ISA_API_FAIL : funcMultiCore_loadElf(sim, elf_path);
}

void isa_cosim_dpi_add_arg(const char* arg)
{
    FuncMultiCore* sim = cosim_sim_for();
    if (sim != nullptr) funcMultiCore_addArg(sim, arg);
}

int isa_cosim_dpi_finalize_config()
{
    FuncMultiCore* sim = cosim_sim_for();
    return sim == nullptr ? ISA_API_FAIL : funcMultiCore_finalizeConfig(sim);
}

std::uint8_t isa_cosim_dpi_is_config_ready()
{
    const FuncMultiCore* sim = cosim_sim_for();
    return sim != nullptr && funcMultiCore_isConfigReady(sim) ? 1 : 0;
}

void isa_cosim_dpi_step(std::int64_t steps)
{
    FuncMultiCore* sim = cosim_sim_for();
    if (sim != nullptr) funcMultiCore_step(sim, steps);
}

std::uint8_t isa_cosim_dpi_is_to_exit()
{
    const FuncMultiCore* sim = cosim_sim_for();
    return sim != nullptr && funcMultiCore_isToExit(sim) ? 1 : 0;
}

std::uint8_t isa_cosim_dpi_is_good()
{
    const FuncMultiCore* sim = cosim_sim_for();
    return sim != nullptr && funcMultiCore_isGood(sim) ? 1 : 0;
}

std::uint64_t isa_cosim_dpi_get_gpr(std::uint32_t model_core_id,
                                    std::uint16_t index)
{
    const FuncMultiCore* sim = cosim_sim_for();
    return sim == nullptr ? 0 : funcMultiCore_getGpr(sim, model_core_id, index);
}

std::uint64_t isa_cosim_dpi_get_fpr(std::uint32_t model_core_id,
                                    std::uint16_t index)
{
    const FuncMultiCore* sim = cosim_sim_for();
    return sim == nullptr ? 0 : funcMultiCore_getFpr(sim, model_core_id, index);
}

std::uint64_t isa_cosim_dpi_get_csr(std::uint32_t model_core_id,
                                    std::uint16_t csr_index)
{
    const FuncMultiCore* sim = cosim_sim_for();
    return sim == nullptr ? 0 : funcMultiCore_getCsrValue(sim, model_core_id, csr_index);
}

std::uint64_t isa_cosim_dpi_get_committed_pc(std::uint32_t model_core_id)
{
    const FuncMultiCore* sim = cosim_sim_for();
    return sim == nullptr ? 0 : funcMultiCore_getCoreCommittedPc(sim, model_core_id);
}

/* ---------- single-model layout ---------- */

std::uint64_t isa_dpi_core_count()
{
    FuncMultiCore* sim = sim_for();
    return sim == nullptr ? 0 : static_cast<std::uint64_t>(funcMultiCore_coreCount(sim));
}

void isa_dpi_set_core_count(std::uint64_t core_num)
{
    FuncMultiCore* sim = sim_for();
    std::size_t cores = 0;
    if (sim != nullptr && to_size(core_num, &cores)) funcMultiCore_setCoreCount(sim, cores);
}

void isa_dpi_set_rob_size(std::uint64_t rob_size)
{
    FuncMultiCore* sim = sim_for();
    std::size_t rob = 0;
    if (sim != nullptr && to_size(rob_size, &rob)) funcMultiCore_setRobSize(sim, rob);
}

void isa_dpi_set_core_pc(std::uint32_t model_core_id,
                         std::uint64_t pc)
{
    FuncMultiCore* sim = sim_for();
    if (sim != nullptr) funcMultiCore_setCorePc(sim, model_core_id, pc);
}

/* ---------- memory and translation ---------- */

std::uint64_t isa_dpi_read_mem(std::uint64_t addr)
{
    FuncMultiCore* sim = sim_for();
    return sim == nullptr ? 0 : funcMultiCore_readMem(sim, addr);
}

int isa_dpi_read_mem_bank(std::uint64_t addr,
                          std::uint64_t length, svOpenArrayHandle target,
                          std::uint64_t* trap_type)
{
    FuncMultiCore* sim = sim_for();
    void* data = nullptr;
    if (sim == nullptr || !array_has_bytes(target, length, &data)) {
        if (trap_type != nullptr) *trap_type = 0;
        return ISA_API_FAIL;
    }
    return funcMultiCore_readMemBank(sim, addr, length, data, trap_type);
}

int isa_dpi_read_mem_bank_virt(std::uint32_t model_core_id,
                               std::uint64_t addr, std::uint64_t length,
                               svOpenArrayHandle target,
                               std::uint64_t* trap_type)
{
    FuncMultiCore* sim = sim_for();
    void* data = nullptr;
    if (sim == nullptr || !array_has_bytes(target, length, &data)) {
        if (trap_type != nullptr) *trap_type = 0;
        return ISA_API_FAIL;
    }
    return funcMultiCore_readMemBankVirt(sim, model_core_id, addr, length,
                                         data, trap_type);
}

int isa_dpi_fetch_mem_bank_virt(std::uint32_t model_core_id,
                                std::uint64_t addr, std::uint64_t length,
                                svOpenArrayHandle target,
                                std::uint64_t* trap_type)
{
    FuncMultiCore* sim = sim_for();
    void* data = nullptr;
    if (sim == nullptr || !array_has_bytes(target, length, &data)) {
        if (trap_type != nullptr) *trap_type = 0;
        return ISA_API_FAIL;
    }
    return funcMultiCore_fetchMemBankVirt(sim, model_core_id, addr, length,
                                          data, trap_type);
}

int isa_dpi_translate_pte(
    std::uint32_t model_core_id,
    std::uint64_t vaddr, std::uint64_t priv, std::int32_t mem_op_type,
    std::uint64_t length,
    std::uint64_t* paddr,
    std::uint64_t* pte_paddr0, std::uint64_t* pte_paddr1,
    std::uint64_t* pte_paddr2, std::uint64_t* pte_paddr3,
    std::uint64_t* pte_paddr4,
    std::uint64_t* pte_value0, std::uint64_t* pte_value1,
    std::uint64_t* pte_value2, std::uint64_t* pte_value3,
    std::uint64_t* pte_value4,
    std::uint8_t* pte_update, std::uint8_t* levels,
    std::uint64_t* trap_type, std::uint64_t* trap_tval,
    std::uint8_t* trap_valid, std::uint8_t* fault_src,
    std::uint8_t* mem_type)
{
    FuncMultiCore* sim = sim_for();
    if (sim == nullptr) {
        zero_trace(paddr, pte_paddr0, pte_paddr1, pte_paddr2, pte_paddr3,
                   pte_paddr4, pte_value0, pte_value1, pte_value2,
                   pte_value3, pte_value4, pte_update, levels, trap_type,
                   trap_tval, trap_valid, fault_src, mem_type);
        return ISA_API_FAIL;
    }
    if (model_core_id >= funcMultiCore_coreCount(sim) ||
        mem_op_type < ISA_API_MEMOP_FETCH ||
        mem_op_type > ISA_API_MEMOP_NOOP || length == 0 || length > 0xffffu) {
        std::fprintf(stderr, "[isa_dpi_translate_pte] invalid core/op/length\n");
        zero_trace(paddr, pte_paddr0, pte_paddr1, pte_paddr2, pte_paddr3,
                   pte_paddr4, pte_value0, pte_value1, pte_value2,
                   pte_value3, pte_value4, pte_update, levels, trap_type,
                   trap_tval, trap_valid, fault_src, mem_type);
        return ISA_API_FAIL;
    }
    const IsaApiMmuTrace trace = funcMultiCore_translatePte(
        sim, model_core_id, vaddr, priv, mem_op_type, length);
    *paddr = trace.paddr;
    *pte_paddr0 = trace.pte_paddr[0]; *pte_paddr1 = trace.pte_paddr[1];
    *pte_paddr2 = trace.pte_paddr[2]; *pte_paddr3 = trace.pte_paddr[3];
    *pte_paddr4 = trace.pte_paddr[4];
    *pte_value0 = trace.pte_value[0]; *pte_value1 = trace.pte_value[1];
    *pte_value2 = trace.pte_value[2]; *pte_value3 = trace.pte_value[3];
    *pte_value4 = trace.pte_value[4];
    *pte_update = trace.pte_update; *levels = trace.levels;
    *trap_type = trace.trap.trap_type; *trap_tval = trace.trap.tval;
    *trap_valid = trace.trap.valid; *fault_src = trace.fault_src;
    *mem_type = trace.mem_type;
    return ISA_API_PASS;
}

/* ---------- register and state queries ---------- */

std::uint64_t isa_dpi_get_gpr(std::uint32_t model_core_id,
                              std::uint16_t index)
{
    const FuncMultiCore* sim = sim_for();
    return sim == nullptr ? 0 : funcMultiCore_getGpr(sim, model_core_id, index);
}

std::uint64_t isa_dpi_get_fpr(std::uint32_t model_core_id,
                              std::uint16_t index)
{
    const FuncMultiCore* sim = sim_for();
    return sim == nullptr ? 0 : funcMultiCore_getFpr(sim, model_core_id, index);
}

std::uint64_t isa_dpi_get_spec_gpr(std::uint32_t model_core_id,
                                   std::uint16_t index)
{
    const FuncMultiCore* sim = sim_for();
    return sim == nullptr ? 0 : funcMultiCore_getSpecGpr(sim, model_core_id, index);
}

std::uint64_t isa_dpi_get_spec_fpr(std::uint32_t model_core_id,
                                   std::uint16_t index)
{
    const FuncMultiCore* sim = sim_for();
    return sim == nullptr ? 0 : funcMultiCore_getSpecFpr(sim, model_core_id, index);
}

std::uint64_t isa_dpi_get_spec_pc(std::uint32_t model_core_id)
{
    const FuncMultiCore* sim = sim_for();
    return sim == nullptr ? 0 : funcMultiCore_getCoreSpecPc(sim, model_core_id);
}

std::uint64_t isa_dpi_get_committed_pc(std::uint32_t model_core_id)
{
    const FuncMultiCore* sim = sim_for();
    return sim == nullptr ? 0 : funcMultiCore_getCoreCommittedPc(sim, model_core_id);
}

std::uint64_t isa_dpi_get_csr(std::uint32_t model_core_id, std::uint16_t csr_index)
{
    const FuncMultiCore* sim = sim_for();
    return sim == nullptr ? 0 : funcMultiCore_getCsrValue(sim, model_core_id, csr_index);
}

std::uint8_t isa_dpi_get_priv(std::uint32_t model_core_id)
{
    const FuncMultiCore* sim = sim_for();
    return sim == nullptr ? 0 : funcMultiCore_getPriv(sim, model_core_id);
}

/* ---------- configuration ---------- */

int isa_dpi_parse_isa(const char* isa_string)
{
    FuncMultiCore* sim = sim_for();
    return sim == nullptr ? ISA_API_FAIL : funcMultiCore_parseIsaString(sim, isa_string);
}

int isa_dpi_load_elf(const char* elf_path)
{
    FuncMultiCore* sim = sim_for();
    return sim == nullptr ? ISA_API_FAIL : funcMultiCore_loadElf(sim, elf_path);
}

int isa_dpi_load_bin(const char* bin_path,
                     std::uint64_t address)
{
    FuncMultiCore* sim = sim_for();
    return sim == nullptr ? ISA_API_FAIL : funcMultiCore_loadBin(sim, bin_path, address);
}

void isa_dpi_set_term_file(const char* file_path)
{
    FuncMultiCore* sim = sim_for();
    if (sim != nullptr) funcMultiCore_setTermFile(sim, file_path);
}

void isa_dpi_add_arg(const char* arg)
{
    FuncMultiCore* sim = sim_for();
    if (sim != nullptr) funcMultiCore_addArg(sim, arg);
}

int isa_dpi_set_clint(std::uint64_t base_addr,
                      std::uint64_t mtime_offset, std::uint64_t mtimecmp_offset,
                      std::uint64_t time_step_offset, std::uint64_t soft_offset)
{
    FuncMultiCore* sim = sim_for();
    return sim == nullptr ? ISA_API_FAIL : funcMultiCore_setClint(
        sim, base_addr, mtime_offset, mtimecmp_offset, time_step_offset, soft_offset);
}

int isa_dpi_set_plic(std::uint64_t base_addr)
{
    FuncMultiCore* sim = sim_for();
    return sim == nullptr ? ISA_API_FAIL : funcMultiCore_setPlic(sim, base_addr);
}

int isa_dpi_set_uart(std::uint64_t base_addr)
{
    FuncMultiCore* sim = sim_for();
    return sim == nullptr ? ISA_API_FAIL : funcMultiCore_setUart(sim, base_addr);
}

void isa_dpi_register_memory_segment(std::uint64_t start, std::uint64_t length,
                                     std::uint8_t readonly)
{
    FuncMultiCore* sim = sim_for();
    if (sim != nullptr) funcMultiCore_registerMemorySegment(sim, start, length,
                                                             readonly != 0);
}

int isa_dpi_set_core_isa(std::uint32_t model_core_id,
                         const char* isa_string)
{
    FuncMultiCore* sim = sim_for();
    return sim == nullptr ? ISA_API_FAIL : funcMultiCore_setCoreIsaString(
        sim, model_core_id, isa_string);
}

int isa_dpi_load_config(const char* yaml_path)
{
    FuncMultiCore* sim = sim_for();
    return sim == nullptr ? ISA_API_FAIL : funcMultiCore_loadConfigFile(sim, yaml_path);
}

int isa_dpi_finalize_config()
{
    FuncMultiCore* sim = sim_for();
    return sim == nullptr ? ISA_API_FAIL : funcMultiCore_finalizeConfig(sim);
}

std::uint8_t isa_dpi_is_run_started()
{
    const FuncMultiCore* sim = sim_for();
    return sim != nullptr && funcMultiCore_isRunStarted(sim) ? 1 : 0;
}

std::uint8_t isa_dpi_is_config_ready()
{
    const FuncMultiCore* sim = sim_for();
    return sim != nullptr && funcMultiCore_isConfigReady(sim) ? 1 : 0;
}

/* ---------- self-driven run/status ---------- */

void isa_dpi_step(std::int64_t steps)
{
    FuncMultiCore* sim = sim_for();
    if (sim != nullptr) funcMultiCore_step(sim, steps);
}

void isa_dpi_step_spec(std::int64_t steps)
{
    FuncMultiCore* sim = sim_for();
    if (sim != nullptr) funcMultiCore_stepSpec(sim, steps);
}

void isa_dpi_tick_finish(std::uint8_t force_htif_poll)
{
    FuncMultiCore* sim = sim_for();
    if (sim != nullptr) funcMultiCore_tickFinish(sim, force_htif_poll != 0);
}

std::uint8_t isa_dpi_is_to_exit()
{
    const FuncMultiCore* sim = sim_for();
    return sim != nullptr && funcMultiCore_isToExit(sim) ? 1 : 0;
}

std::uint8_t isa_dpi_is_good()
{
    const FuncMultiCore* sim = sim_for();
    return sim != nullptr && funcMultiCore_isGood(sim) ? 1 : 0;
}

void isa_dpi_reset()
{
    FuncMultiCore* sim = sim_for();
    if (sim != nullptr) funcMultiCore_reset(sim);
}

/* ---------- RTL-driven external interface ---------- */

std::int64_t isa_dpi_decode_and_issue(std::uint32_t model_core_id,
                                      std::uint64_t rob_idx, std::uint64_t pc,
                                      std::uint32_t encoding,
                                      std::uint8_t force_rvc)
{
    FuncMultiCore* sim = sim_for();
    return sim == nullptr ? ISA_API_INVALID_INSN_ID : funcMultiCore_decodeAndIssue(
        sim, model_core_id, rob_idx, pc, encoding, force_rvc != 0);
}

int isa_dpi_execute_insn(std::uint32_t model_core_id,
                         std::uint64_t rob_idx)
{
    FuncMultiCore* sim = sim_for();
    return sim == nullptr ? ISA_API_FAIL : funcMultiCore_executeInsn(sim, model_core_id, rob_idx);
}

int isa_dpi_proc_mem_req(std::uint32_t model_core_id,
                         std::uint64_t rob_idx)
{
    FuncMultiCore* sim = sim_for();
    return sim == nullptr ? ISA_API_FAIL : funcMultiCore_procMemReq(sim, model_core_id, rob_idx);
}

int isa_dpi_proc_mem_load(std::uint32_t model_core_id,
                          std::uint64_t rob_idx)
{
    FuncMultiCore* sim = sim_for();
    return sim == nullptr ? ISA_API_FAIL : funcMultiCore_procMemLoad(sim, model_core_id, rob_idx);
}

int isa_dpi_store_commit(std::uint32_t model_core_id)
{
    FuncMultiCore* sim = sim_for();
    return sim == nullptr ? ISA_API_FAIL : funcMultiCore_storeCommit(sim, model_core_id);
}

int isa_dpi_flush(std::uint32_t model_core_id,
                  std::uint64_t rob_idx)
{
    FuncMultiCore* sim = sim_for();
    return sim == nullptr ? ISA_API_FAIL : funcMultiCore_flush(sim, model_core_id, rob_idx);
}

int isa_dpi_flush_all(std::uint32_t model_core_id)
{
    FuncMultiCore* sim = sim_for();
    return sim == nullptr ? ISA_API_FAIL : funcMultiCore_flushAll(sim, model_core_id);
}

int isa_dpi_clear_mem_reserve(std::uint32_t model_core_id)
{
    FuncMultiCore* sim = sim_for();
    return sim == nullptr ? ISA_API_FAIL : funcMultiCore_clearMemReserve(sim, model_core_id);
}

void isa_dpi_check_interrupt()
{
    FuncMultiCore* sim = sim_for();
    if (sim != nullptr) funcMultiCore_checkInterrupt(sim);
}

std::uint8_t isa_dpi_has_pending_interrupt(std::uint32_t model_core_id)
{
    const FuncMultiCore* sim = sim_for();
    return sim != nullptr && funcMultiCore_hasValidPendingInterrupt(
        sim, model_core_id) ? 1 : 0;
}

int isa_dpi_take_interrupt(std::uint32_t model_core_id,
                           std::uint64_t* next_pc, std::uint8_t* redirect)
{
    FuncMultiCore* sim = sim_for();
    if (sim == nullptr) {
        *next_pc = 0;
        *redirect = 0;
        return ISA_API_FAIL;
    }
    const IsaApiDirReq req = funcMultiCore_takeInterrupt(sim, model_core_id);
    *next_pc = req.next_pc;
    *redirect = req.redirect;
    return ISA_API_PASS;
}

int isa_dpi_commit(std::uint32_t model_core_id,
                   std::uint64_t rob_idx)
{
    FuncMultiCore* sim = sim_for();
    return sim == nullptr ? ISA_API_FAIL : funcMultiCore_commit(sim, model_core_id, rob_idx);
}

int isa_dpi_commit_auto(std::uint32_t model_core_id,
                        std::uint64_t rob_idx)
{
    FuncMultiCore* sim = sim_for();
    return sim == nullptr ? ISA_API_FAIL : funcMultiCore_commitAuto(sim, model_core_id, rob_idx);
}

void isa_dpi_take_trap(std::uint32_t model_core_id,
                       std::uint64_t rob_idx)
{
    FuncMultiCore* sim = sim_for();
    if (sim != nullptr) funcMultiCore_takeTrap(sim, model_core_id, rob_idx);
}

int isa_dpi_take_interrupt_now(std::uint32_t model_core_id,
                               std::uint64_t value, std::uint64_t mask)
{
    FuncMultiCore* sim = sim_for();
    return sim == nullptr ? ISA_API_FAIL : funcMultiCore_takeInterruptNow(
        sim, model_core_id, value, mask);
}

/* ---------- per-instruction queries and trap injection ---------- */

int isa_dpi_get_decode_metadata(std::uint32_t model_core_id, std::uint64_t rob_idx,
                                std::uint8_t* is_lsu, std::uint8_t* trap_valid,
                                std::uint64_t* trap_cause, std::uint64_t* trap_tval)
{
    const FuncMultiCore* sim = sim_for();
    if (sim == nullptr)
        return ISA_API_FAIL;
    const IsaApiDecodeMetadata m =
        funcMultiCore_getDecodeMetadata(sim, model_core_id, rob_idx);
    *is_lsu = m.is_lsu;
    *trap_valid = m.trap_valid;
    *trap_cause = m.trap_cause;
    *trap_tval = m.trap_tval;
    return ISA_API_PASS;
}

int isa_dpi_get_lsu_issue_metadata(
    std::uint32_t model_core_id, std::uint64_t rob_idx,
    std::uint8_t* req_property, std::uint32_t* exe_subop,
    std::uint8_t* mem_funct3, std::uint8_t* rd_is_fp,
    std::uint64_t* rs1_data, std::uint64_t* rs2_data,
    std::uint8_t* imm_valid, std::int64_t* imm_data, std::uint8_t* is_store)
{
    const FuncMultiCore* sim = sim_for();
    if (sim == nullptr)
        return ISA_API_FAIL;
    const IsaApiLsuIssueMetadata m =
        funcMultiCore_getLsuIssueMetadata(sim, model_core_id, rob_idx);
    *req_property = m.req_property;
    *exe_subop = m.exe_subop;
    *mem_funct3 = m.mem_funct3;
    *rd_is_fp = m.rd_is_fp;
    *rs1_data = m.rs1_data;
    *rs2_data = m.rs2_data;
    *imm_valid = m.imm_valid;
    *imm_data = m.imm_data;
    *is_store = m.is_store;
    return *req_property != 0 ? ISA_API_PASS : ISA_API_FAIL;
}

int isa_dpi_get_execute_metadata(std::uint32_t model_core_id, std::uint64_t rob_idx,
                                 std::uint8_t* trap_valid,
                                 std::uint64_t* trap_cause,
                                 std::uint64_t* trap_tval)
{
    const FuncMultiCore* sim = sim_for();
    if (sim == nullptr)
        return ISA_API_FAIL;
    const IsaApiExecuteMetadata m =
        funcMultiCore_getExecuteMetadata(sim, model_core_id, rob_idx);
    *trap_valid = m.trap_valid;
    *trap_cause = m.trap_cause;
    *trap_tval = m.trap_tval;
    return ISA_API_PASS;
}

int isa_dpi_get_commit_auto_trap_info(std::uint32_t model_core_id,
                                      std::uint64_t rob_idx,
                                      std::uint8_t* trap_record_valid,
                                      std::uint64_t* trap_cause,
                                      std::uint64_t* trap_tval)
{
    const FuncMultiCore* sim = sim_for();
    if (sim == nullptr)
        return ISA_API_FAIL;
    const IsaApiCommitTrapInfo m =
        funcMultiCore_getCommitAutoTrapInfo(sim, model_core_id, rob_idx);
    *trap_record_valid = m.trap_record_valid;
    *trap_cause = m.trap_cause;
    *trap_tval = m.trap_tval;
    return ISA_API_PASS;
}

int isa_dpi_get_insn_metadata(std::uint32_t model_core_id,
                              std::uint64_t rob_idx,
                              std::uint8_t* rd_valid,
                              std::uint8_t* rd_is_fp,
                              std::uint8_t* rd_write_enable,
                              std::uint32_t* rd_idx,
                              std::uint64_t* rd_value,
                              std::uint8_t* recovery_kind)
{
    const FuncMultiCore* sim = sim_for();
    if (sim == nullptr)
        return ISA_API_FAIL;
    const IsaApiInsnMetadata m =
        funcMultiCore_getInsnMetadata(sim, model_core_id, rob_idx);
    *rd_valid = m.rd_valid;
    *rd_is_fp = m.rd_is_fp;
    *rd_write_enable = m.rd_write_enable;
    *rd_idx = m.rd_idx;
    *rd_value = m.rd_value;
    *recovery_kind = m.recovery_kind;
    return ISA_API_PASS;
}

int isa_dpi_get_decode_semantic(std::uint32_t model_core_id,
                                std::uint64_t rob_idx,
                                std::uint8_t* rs1_valid,
                                std::uint8_t* rs2_valid,
                                std::uint8_t* rs3_valid,
                                std::uint8_t* rs1_is_fp,
                                std::uint8_t* rs2_is_fp,
                                std::uint8_t* rs3_is_fp,
                                std::uint32_t* rs1_idx,
                                std::uint32_t* rs2_idx,
                                std::uint32_t* rs3_idx,
                                std::uint8_t* is_store,
                                std::uint8_t* imm_valid,
                                std::int64_t* imm_data,
                                std::uint32_t* exe_subop)
{
    const FuncMultiCore* sim = sim_for();
    if (sim == nullptr)
        return ISA_API_FAIL;
    const IsaApiDecodeSemantic m =
        funcMultiCore_getDecodeSemantic(sim, model_core_id, rob_idx);
    *rs1_valid = m.rs1_valid;
    *rs2_valid = m.rs2_valid;
    *rs3_valid = m.rs3_valid;
    *rs1_is_fp = m.rs1_is_fp;
    *rs2_is_fp = m.rs2_is_fp;
    *rs3_is_fp = m.rs3_is_fp;
    *rs1_idx = m.rs1_idx;
    *rs2_idx = m.rs2_idx;
    *rs3_idx = m.rs3_idx;
    *is_store = m.is_store;
    *imm_valid = m.imm_valid;
    *imm_data = m.imm_data;
    *exe_subop = m.exe_subop;
    return ISA_API_PASS;
}

std::uint64_t isa_dpi_get_insn_pc(std::uint32_t model_core_id,
                                  std::uint64_t rob_idx)
{
    const FuncMultiCore* sim = sim_for();
    return sim == nullptr ? 0 : funcMultiCore_getInsnPc(sim, model_core_id, rob_idx);
}

std::int64_t isa_dpi_decode_mnemonic(std::uint32_t encoding,
                                     std::uint8_t force_rvc)
{
    FuncMultiCore* sim = sim_for();
    return sim == nullptr ? ISA_API_INVALID_MNEMONIC
                          : funcMultiCore_decodeMnemonic(sim, 0, encoding,
                                                          force_rvc != 0);
}

const char* isa_dpi_mnemonic_name(std::int64_t mnemonic)
{
    return decoder_getInsnName(static_cast<std::uint64_t>(mnemonic));
}

std::uint64_t isa_dpi_get_insn_rd_value(std::uint32_t model_core_id,
                                        std::uint64_t rob_idx)
{
    const FuncMultiCore* sim = sim_for();
    return sim == nullptr ? 0 : funcMultiCore_getInsnRdValue(sim, model_core_id, rob_idx);
}

std::uint64_t isa_dpi_get_next_pc_of_insn(std::uint32_t model_core_id,
                                          std::uint64_t rob_idx)
{
    const FuncMultiCore* sim = sim_for();
    return sim == nullptr ? 0 : funcMultiCore_getNextPcOfInst(sim, model_core_id, rob_idx);
}

std::uint8_t isa_dpi_is_insn_redirect(std::uint32_t model_core_id,
                                      std::uint64_t rob_idx)
{
    const FuncMultiCore* sim = sim_for();
    return sim != nullptr && funcMultiCore_isInsnRedirect(
        sim, model_core_id, rob_idx) ? 1 : 0;
}

int isa_dpi_trigger_trap(std::uint32_t model_core_id,
                         std::uint64_t rob_idx, std::uint64_t trap_type,
                         std::uint64_t tvalue)
{
    FuncMultiCore* sim = sim_for();
    return sim == nullptr ? ISA_API_FAIL : funcMultiCore_triggerTrap(
        sim, model_core_id, rob_idx, trap_type, tvalue);
}

int isa_dpi_has_trap(std::uint32_t model_core_id,
                     std::uint64_t rob_idx)
{
    FuncMultiCore* sim = sim_for();
    return sim == nullptr ? 0 : funcMultiCore_hasTrap(sim, model_core_id, rob_idx);
}

void isa_dpi_log_run(std::uint32_t model_core_id,
                     std::uint64_t rob_idx)
{
    FuncMultiCore* sim = sim_for();
    if (sim != nullptr) funcMultiCore_log_run(sim, model_core_id, rob_idx);
}

void isa_dpi_log_commit(std::uint32_t model_core_id,
                        std::uint64_t rob_idx)
{
    FuncMultiCore* sim = sim_for();
    if (sim != nullptr) funcMultiCore_log_commit(sim, model_core_id, rob_idx);
}

/* ---------- global log controls ---------- */

void isa_dpi_enable_run_log(std::int32_t core_id) { enable_run_log(core_id); }
void isa_dpi_disable_run_log(std::int32_t core_id) { disable_run_log(core_id); }
std::uint8_t isa_dpi_run_log_enabled(std::int32_t core_id)
{
    return run_log_enabled(core_id) ? 1 : 0;
}
void isa_dpi_set_run_log(const char* log_path) { set_run_log(log_path); }

void isa_dpi_enable_commit_log(std::int32_t core_id) { enable_commit_log(core_id); }
void isa_dpi_disable_commit_log(std::int32_t core_id) { disable_commit_log(core_id); }
std::uint8_t isa_dpi_commit_log_enabled(std::int32_t core_id)
{
    return commit_log_enabled(core_id) ? 1 : 0;
}
void isa_dpi_set_commit_log(const char* log_path) { set_commit_log(log_path); }

} // extern "C"
