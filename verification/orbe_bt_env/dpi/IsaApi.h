/* IsaApi.h
 *
 * Public C ABI for the ISA model. Library users include this header and
 * link against `lib_ISA_api.so`. The simulator object is exposed as an
 * opaque struct (`FuncMultiCore`) — the underlying C++ definition is NOT
 * included here, so library users cannot reach into private model state.
 *
 * Compatible with both C and C++. All declarations are `extern "C"`.
 *
 * Note: this header is hand-maintained alongside the source-of-truth
 * extern-"C" declarations in src/libs/lib_FuncMultiCore.cpp; if you add or
 * change a public symbol there, update this header to match.
 */
#ifndef ISA_API_H
#define ISA_API_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------- public constants (C-style macros) ----------
 *
 * Mirror of the internal `RunResult` enum used by all int-returning APIs.
 * Library users compare against these instead of magic numbers.
 */
#define ISA_API_PASS              0
#define ISA_API_SKIP              1
#define ISA_API_PENDING           2
#define ISA_API_FAIL            (-1)

/* Returned by funcMultiCore_decodeAndIssue on failure. */
#define ISA_API_INVALID_INSN_ID ((int64_t)-1)
#define ISA_API_INVALID_MNEMONIC ((int64_t)-1)

/* core_id sentinel for log control: "global / all device". */
#define ISA_API_LOG_GLOBAL      (-1)

/* Architectural register-file sizes (used to bounds-check idx in the
 * register-query APIs). RISC-V GPR / FPR are both 32 entries. */
#define ISA_API_NXPR             32
#define ISA_API_NFPR             32

/* Memory-op selectors for translation-query APIs. Keep the values stable in
 * the public C ABI; the C++ wrapper maps them explicitly to internal
 * ISA_RISCV::MemOpType values. */
#define ISA_API_MEMOP_FETCH      0
#define ISA_API_MEMOP_LOAD       1
#define ISA_API_MEMOP_STORE      2
#define ISA_API_MEMOP_AMOSWAP    3
#define ISA_API_MEMOP_AMOADD     4
#define ISA_API_MEMOP_AMOAND     5
#define ISA_API_MEMOP_AMOOR      6
#define ISA_API_MEMOP_AMOXOR     7
#define ISA_API_MEMOP_AMOMAX     8
#define ISA_API_MEMOP_AMOMIN     9
#define ISA_API_MEMOP_AMOMAXU    10
#define ISA_API_MEMOP_AMOMINU    11
#define ISA_API_MEMOP_LOAD_RSV   12
#define ISA_API_MEMOP_STORE_CND  13
#define ISA_API_MEMOP_FENCE      14
#define ISA_API_MEMOP_CBO_ZERO   15
#define ISA_API_MEMOP_NOOP       16

/* Post-execute actions required by an RTL-driven in-flight instruction. */
#define ISA_API_INSN_ACTION_MEM_LOAD     (1u << 0)
#define ISA_API_INSN_ACTION_STORE_COMMIT (1u << 1)

/* ---------- opaque handle ----------
 *
 * `FuncMultiCore` is forward-declared as an opaque struct — only its
 * pointer is part of the public ABI. The full definition lives in
 * arch/processors/FuncMultiCore.hpp and is intentionally NOT exposed here,
 * preventing library users from depending on internal layout.
 */
typedef struct FuncMultiCore FuncMultiCore;

const char* decoder_getInsnName(uint64_t mnemonic);

/* ---------- MMU/PTW trace query ---------- */
typedef struct IsaApiTrapInfo
{
    uint64_t trap_type;
    uint64_t tval;
    uint8_t  valid;
} IsaApiTrapInfo;

typedef struct IsaApiMmuTrace
{
    uint64_t       paddr;
    uint64_t       pte_paddr[5];
    uint64_t       pte_value[5];
    uint8_t        pte_update;
    uint8_t        levels;
    IsaApiTrapInfo trap;
    uint8_t        fault_src;
    uint8_t        mem_type;
} IsaApiMmuTrace;

typedef struct IsaApiDirReq
{
    uint64_t next_pc;
    uint8_t  redirect;
} IsaApiDirReq;

/* Read-only metadata used by the RTL reference-model path.  These structs
 * deliberately describe lifecycle phases separately: decode never freezes
 * operands, while the LSU query resolves operands only when the target entry
 * is ready to issue. */
typedef struct IsaApiDecodeMetadata
{
    uint8_t  is_lsu;
    uint8_t  trap_valid;
    uint64_t trap_cause;
    uint64_t trap_tval;
} IsaApiDecodeMetadata;

typedef struct IsaApiLsuIssueMetadata
{
    uint8_t  req_property;
    uint32_t exe_subop;
    uint8_t  mem_funct3;
    uint8_t  rd_is_fp;
    uint64_t rs1_data;
    uint64_t rs2_data;
    uint8_t  imm_valid;
    int64_t  imm_data;
    uint8_t  is_store;
} IsaApiLsuIssueMetadata;

typedef struct IsaApiExecuteMetadata
{
    uint8_t  trap_valid;
    uint64_t trap_cause;
    uint64_t trap_tval;
} IsaApiExecuteMetadata;

typedef struct IsaApiCommitTrapInfo
{
    uint8_t  trap_record_valid;
    uint64_t trap_cause;
    uint64_t trap_tval;
} IsaApiCommitTrapInfo;

typedef struct IsaApiInsnMetadata
{
    uint8_t  rd_valid;
    uint8_t  rd_is_fp;
    uint8_t  rd_write_enable;
    uint32_t rd_idx;
    uint64_t rd_value;
    uint8_t  recovery_kind;
} IsaApiInsnMetadata;

typedef struct IsaApiDecodeSemantic
{
    uint8_t rs1_valid;
    uint8_t rs2_valid;
    uint8_t rs3_valid;
    uint8_t rs1_is_fp;
    uint8_t rs2_is_fp;
    uint8_t rs3_is_fp;
    uint16_t rs1_idx;
    uint16_t rs2_idx;
    uint16_t rs3_idx;
    uint8_t is_store;
    uint8_t imm_valid;
    int64_t imm_data;
    uint32_t exe_subop;
} IsaApiDecodeSemantic;

/* ---------- lifecycle ---------- */
FuncMultiCore* funcMultiCore_create (size_t core_num, size_t rob_size);
void           funcMultiCore_destroy(FuncMultiCore* sim_ptr);

/* ---------- per-core layout config ---------- */
size_t  funcMultiCore_coreCount   (const FuncMultiCore* sim_ptr);
void    funcMultiCore_setCoreCount(FuncMultiCore* sim_ptr, size_t core_num);
void    funcMultiCore_setRobSize  (FuncMultiCore* sim_ptr, size_t rob_size);

/* Override a specific core's program counter. Useful right after loadElf
 * when the desired entry point differs from the ELF's stored start_pc. */
void    funcMultiCore_setCorePc   (FuncMultiCore* sim_ptr, size_t core_id, uint64_t pc);

/* ---------- shared memory read (RTL data-compare convenience) ----------
 *
 * Memory writes are intentionally NOT exposed: the simulator owns the
 * memory model, and externally driving writes would let RTL silently
 * desync the model. Use loadElf/loadBin for image loading.
 *
 * funcMultiCore_readMem        : single 8-byte physical-address read.
 * funcMultiCore_readMemBank    : bulk physical read; chunks across clint /
 *                                plic / memory. trap_type out is one of
 *                                NO_TRAP / LOAD_ACCESS_FAULT (encoded as
 *                                ISA_RISCV::TrapType cast to uint64_t).
 * funcMultiCore_readMemBankVirt: per-core bulk VA read; splits at the
 *                                4KiB page boundary, translates each
 *                                chunk independently. First trap returns
 *                                FAIL with trap_type set.
 * funcMultiCore_fetchMemBankVirt: per-core fetch read; memory-only (incl.
 *                                ROM/RAM), 2-byte chunks, odd addr ->
 *                                INSN_ADDR_MISSALIGN. First trap returns.
 */
uint64_t funcMultiCore_readMem        (const FuncMultiCore* sim_ptr, uint64_t addr);
int      funcMultiCore_readMemBank    (const FuncMultiCore* sim_ptr,
                                       uint64_t addr, uint64_t len,
                                       void* target, uint64_t* trap_type);
int      funcMultiCore_readMemBankVirt(const FuncMultiCore* sim_ptr, size_t core_id,
                                       uint64_t addr, uint64_t len,
                                       void* target, uint64_t* trap_type);
int      funcMultiCore_fetchMemBankVirt(FuncMultiCore* sim_ptr, size_t core_id,
                                        uint64_t addr, uint64_t len,
                                        void* target, uint64_t* trap_type);
/* translatePte: query-only VA translation / PTW trace for RTL-driven mode.
 * This API never mutates model state: it uses the MMU's const translate path
 * and only reports the translation result plus the PTW/PTE information that
 * would be relevant to an external timing model. Even if the walk discovers
 * that A/D bits should be updated, the API only reports that need through the
 * returned trace (`pte_update` / `pte_value`) and does not write memory. */
IsaApiMmuTrace funcMultiCore_translatePte(FuncMultiCore* sim_ptr, size_t core_id,
                                          uint64_t vaddr, uint64_t priv,
                                          int mem_op_type, uint64_t length);

/* ---------- per-core register query (RTL data-compare convenience) ----------
 *
 * All read-only. core_id and idx are bounds-checked; out-of-range queries
 * print a diagnostic on stderr and return 0. Callers typically use the
 * "committed" variants (getGpr / getFpr / getCsrValue / getCoreCommittedPc) at retire
 * boundaries; the "spec" variants (getSpecGpr / getSpecFpr) project all
 * in-flight written entries forward over the committed register file —
 * useful when comparing against an out-of-order RTL pipeline mid-flight.
 */
uint64_t funcMultiCore_getGpr     (const FuncMultiCore* sim_ptr, size_t core_id, uint16_t idx);
uint64_t funcMultiCore_getFpr     (const FuncMultiCore* sim_ptr, size_t core_id, uint16_t idx);
uint64_t funcMultiCore_getSpecGpr (const FuncMultiCore* sim_ptr, size_t core_id, uint16_t idx);
uint64_t funcMultiCore_getSpecFpr (const FuncMultiCore* sim_ptr, size_t core_id, uint16_t idx);
/* getCoreSpecPc: speculative next-PC. Walks the rob tail→head; first
 * in-flight entry with a resolved redirect (output.dir.redirect == true)
 * wins, returning its next_pc. If no resolved redirect exists, falls back
 * to CoreState::pc — which decodeAndIssue advances naively by +2/+4 per
 * issue and which commit anchors to next_pc at retire. Use this when the
 * caller wants to know "where would the model fetch next, considering
 * speculative branches that have computed targets but not yet committed".
 *
 * getCoreCommittedPc: the raw CoreState::pc field. Updated by decodeAndIssue
 * (naive +2/+4 frontier advance) and by commit (writeBack(output.dir)
 * anchors it to next_pc on branches). Use this when the caller wants
 * exactly what the model's PC field reads, without the rob walk. */
uint64_t funcMultiCore_getCoreSpecPc    (const FuncMultiCore* sim_ptr, size_t core_id);
uint64_t funcMultiCore_getCoreCommittedPc(const FuncMultiCore* sim_ptr, size_t core_id);
uint64_t funcMultiCore_getCsrValue(const FuncMultiCore* sim_ptr, size_t core_id, uint16_t csr_idx);
uint8_t  funcMultiCore_getPriv(const FuncMultiCore* sim_ptr, size_t core_id);

/* ---------- configuration ---------- */
int  funcMultiCore_parseIsaString       (FuncMultiCore* sim_ptr, const char* isa_string);
int  funcMultiCore_loadElf              (FuncMultiCore* sim_ptr, const char* elf_path);
int  funcMultiCore_loadBin              (FuncMultiCore* sim_ptr, const char* bin_path, uint64_t address);
void funcMultiCore_setTermFile          (FuncMultiCore* sim_ptr, const char* file_path);
void funcMultiCore_addArg               (FuncMultiCore* sim_ptr, const char* arg);
int  funcMultiCore_setClint             (FuncMultiCore* sim_ptr,
                                         uint64_t base_addr,
                                         uint64_t mtime_offset,
                                         uint64_t mtimecmp_offset,
                                         uint64_t time_step_offset,
                                         uint64_t soft_offset);
int  funcMultiCore_setPlic              (FuncMultiCore* sim_ptr, uint64_t base_addr);
int  funcMultiCore_setUart              (FuncMultiCore* sim_ptr, uint64_t base_addr);
/* registerMemorySegment: register a DDR address segment. `readonly` marks it
 * as a ROM region; after finalizeConfig() writes into a ROM region are refused. */
void funcMultiCore_registerMemorySegment(FuncMultiCore* sim_ptr, uint64_t start, uint64_t len, bool readonly);
/* setCoreIsaString: override one core's ISA string (call after parseIsaString). */
int  funcMultiCore_setCoreIsaString     (FuncMultiCore* sim_ptr, size_t core_id, const char* isa_string);
/* loadConfigFile: parse a narrow-YAML platform config and apply it (= the
 * full setter chain, EXCLUDING finalizeConfig and ELF loading). The caller
 * still calls loadElf (payload) and finalizeConfig afterwards. */
int  funcMultiCore_loadConfigFile       (FuncMultiCore* sim_ptr, const char* yaml_path);
int  funcMultiCore_finalizeConfig       (FuncMultiCore* sim_ptr);
bool funcMultiCore_isRunStarted         (const FuncMultiCore* sim_ptr);
bool funcMultiCore_isConfigReady        (const FuncMultiCore* sim_ptr);

/* ---------- run / status ---------- */
void funcMultiCore_step       (FuncMultiCore* sim_ptr, int64_t steps);
void funcMultiCore_stepSpec   (FuncMultiCore* sim_ptr, int64_t steps);
void funcMultiCore_tickFinish (FuncMultiCore* sim_ptr, bool force_htif_poll);
bool funcMultiCore_isToExit   (const FuncMultiCore* sim_ptr);
bool funcMultiCore_isGood     (const FuncMultiCore* sim_ptr);
void funcMultiCore_reset      (FuncMultiCore* sim_ptr);

/* ---------- RTL-driven external interface ---------- */
int64_t funcMultiCore_decodeMnemonic(FuncMultiCore* sim_ptr,
                                     size_t core_id,
                                     uint32_t encoding,
                                     bool force_rvc);
int64_t funcMultiCore_decodeAndIssue(FuncMultiCore* sim_ptr,
                                     size_t core_id,
                                     uint64_t rob_idx,
                                     uint64_t pc,
                                     uint32_t encoding,
                                     bool force_rvc);
int     funcMultiCore_executeInsn   (FuncMultiCore* sim_ptr, size_t core_id, uint64_t rob_idx);
/* The memory access is split into a read/decision side (procMemLoad) and a
 * write side (storeCommit); the address is translated once, at executeInsn
 * (the AGU->MMU step), so neither stage translates again.
 *
 * procMemLoad: the read / decision side. Runs for everything that has one —
 *   LOAD/LR (read memory, then overlay in-flight stores from the per-core
 *   storeBuffer for a "youngest store wins per byte" speculative view), AMO
 *   (read old value -> rd, compute the new value), and SC (test the
 *   reservation, set rd = 0/1). For AMO/SC it normalizes the buffered store so
 *   storeCommit can later write it blindly. A *plain* store has no read side
 *   and is rejected with a diagnostic — drive executeInsn + storeCommit for it.
 *
 *   AMO read does NOT forward from in-flight stores (it reads coherent memory).
 *   If an AMO must observe an inflight store to the same address, the RTL
 *   caller drives that older store's storeCommit before issuing the AMO. */
int     funcMultiCore_procMemReq    (FuncMultiCore* sim_ptr, size_t core_id, uint64_t rob_idx);
int     funcMultiCore_procMemLoad   (FuncMultiCore* sim_ptr, size_t core_id, uint64_t rob_idx);
/* storeCommit: the write side. Drains the oldest in-flight entry of `core_id`'s
 * storeBuffer by writing its (already normalized + physically addressed) MemReq
 * to device/memory, then pops it. A failed SC was normalized to a no-write
 * entry by procMemLoad, so storeCommit pops it without writing. This is the
 * ONLY way an entry takes effect + leaves the buffer (flush only pops). Returns
 * FAIL on:
 *   - empty buffer (a cosim mismatch — the RTL expected a buffered store);
 *   - head not data-ready (executeInsn for that store hasn't run yet);
 *   - memory-dispatch failure at drain time. */
int     funcMultiCore_storeCommit   (FuncMultiCore* sim_ptr, size_t core_id);
int     funcMultiCore_flush         (FuncMultiCore* sim_ptr, size_t core_id, uint64_t rob_idx);
/* flushAll: squash every in-flight entry on `core_id` (rob becomes empty;
 * the committed-count carried by headId_ is preserved). Idempotent on an
 * already-empty rob. Returns PASS (0) on success, FAIL (-1) on bad core_id. */
int     funcMultiCore_flushAll      (FuncMultiCore* sim_ptr, size_t core_id);
/* clearMemReserve: invalidate `core_id`'s LR/SC reservation
 * (cores[core_id].mem_rsv.valid = false). For RTL-driven mode where the
 * pipeline decides an SC must fail or a context switch clears the monitor.
 * Returns PASS (0) on success, FAIL (-1) on bad core_id. */
int     funcMultiCore_clearMemReserve(FuncMultiCore* sim_ptr, size_t core_id);
/* checkInterrupt: sample all internal device interrupt sources and record any
 * pending interrupt into the cores they target. This does NOT take the
 * interrupt; callers decide whether to call takeInterruptNow /
 * timing-model-side takeInterrupt afterwards. */
void    funcMultiCore_checkInterrupt(FuncMultiCore* sim_ptr);
bool    funcMultiCore_hasValidPendingInterrupt(const FuncMultiCore* sim_ptr, size_t core_id);
IsaApiDirReq funcMultiCore_takeInterrupt(FuncMultiCore* sim_ptr, size_t core_id);
int     funcMultiCore_commit        (FuncMultiCore* sim_ptr, size_t core_id, uint64_t rob_idx);
int     funcMultiCore_commitAuto    (FuncMultiCore* sim_ptr, size_t core_id, uint64_t rob_idx);
void    funcMultiCore_takeTrap      (FuncMultiCore* sim_ptr, size_t core_id, uint64_t rob_idx);

/* takeInterruptNow: raise an interrupt on `core_id` and immediately apply
 * it to that core's committed state (not speculative). The interrupt is
 * described as a 64-bit (value, mask) pair — `value` is the bit pattern
 * of the interrupt cause(s), `mask` selects which of its bits are valid.
 * Returns RunResult::PASS (0) on success, FAIL (-1) on bad core_id.
 */
int     funcMultiCore_takeInterruptNow(FuncMultiCore* sim_ptr,
                                       size_t core_id,
                                       uint64_t value,
                                       uint64_t mask);

/* ---------- per-insn debug getters / RTL-driven trap injection ----------
 *
 * getInsnPc / getNextPcOfInst / isInsnRedirect: per-(core, rob_idx) inspectors;
 * out-of-range or empty rob slot prints a diagnostic and returns 0/false.
 *   getInsnPc        : inst.inst_pc
 *   getNextPcOfInst  : output.dir.next_pc if redirect, else inst_pc + 2/4
 *   isInsnRedirect   : output.dir.redirect
 *
 * triggerTrap: mark a trap on the entry at (core_id, rob_idx). Intended for
 * fetch-stage exceptions reported by RTL (INSN_ACCESS_FAULT /
 * INSN_ADDR_MISSALIGN / INSN_PAGE_FAULT). trap_type is ISA_RISCV::TrapType
 * cast to uint64_t. Returns 0 on success, -1 on bad core_id / rob_idx.
 */
uint64_t funcMultiCore_getInsnPc       (const FuncMultiCore* sim_ptr,
                                        size_t core_id, uint64_t rob_idx);
uint64_t funcMultiCore_getInsnRdValue  (const FuncMultiCore* sim_ptr,
                                        size_t core_id, uint64_t rob_idx);
uint64_t funcMultiCore_getNextPcOfInst (const FuncMultiCore* sim_ptr,
                                        size_t core_id, uint64_t rob_idx);
bool     funcMultiCore_isInsnRedirect  (const FuncMultiCore* sim_ptr,
                                        size_t core_id, uint64_t rob_idx);
uint32_t funcMultiCore_getInsnActions  (const FuncMultiCore* sim_ptr,
                                        size_t core_id, uint64_t rob_idx);
int      funcMultiCore_triggerTrap     (FuncMultiCore* sim_ptr,
                                        size_t core_id, uint64_t rob_idx,
                                        uint64_t trap_type, uint64_t tvalue);
/* hasTrap: post-commitAuto inspection. After commitAuto auto-handles a
 * trap, the entry is no longer in the in-flight window, but it still lives
 * at its physical slot. Returns 1 if entries_[rob_idx].insn.trap.trap_type
 * != NO_TRAP (i.e. the just-retired insn was a trap), 0 otherwise.
 * Returns 0 on bad core_id / rob_idx. */
int      funcMultiCore_hasTrap         (FuncMultiCore* sim_ptr,
                                        size_t core_id, uint64_t rob_idx);
IsaApiDecodeMetadata funcMultiCore_getDecodeMetadata(const FuncMultiCore* sim_ptr,
                                        size_t core_id, uint64_t rob_idx);
IsaApiLsuIssueMetadata funcMultiCore_getLsuIssueMetadata(const FuncMultiCore* sim_ptr,
                                        size_t core_id, uint64_t rob_idx);
IsaApiExecuteMetadata funcMultiCore_getExecuteMetadata(const FuncMultiCore* sim_ptr,
                                        size_t core_id, uint64_t rob_idx);
IsaApiCommitTrapInfo funcMultiCore_getCommitAutoTrapInfo(const FuncMultiCore* sim_ptr,
                                        size_t core_id, uint64_t rob_idx);
IsaApiInsnMetadata funcMultiCore_getInsnMetadata(const FuncMultiCore* sim_ptr,
                                        size_t core_id, uint64_t rob_idx);
IsaApiDecodeSemantic funcMultiCore_getDecodeSemantic(const FuncMultiCore* sim_ptr,
                                        size_t core_id, uint64_t rob_idx);

/* On-demand per-insn log emission for an in-flight ROB entry.
 *
 *   funcMultiCore_log_run    — emit the run-log line for the insn at
 *                              (core_id, rob_idx), formatted up to the
 *                              latest pipeline stage that entry has reached
 *                              (decode / read-reg / calc / mem / writeback).
 *                              Caller must have enabled the per-core run log
 *                              first (`enable_run_log(core_id)`); otherwise
 *                              this is a fast no-op.
 *   funcMultiCore_log_commit — emit the commit-log line for the same entry.
 *                              Gated by `commit_log_enabled(core_id)`.
 *
 * Both are intended for RTL-driven mode: typically called once per insn
 * after the RTL has finished its commit-stage observation, mirroring what
 * step() / step_spec() emit internally. */
void     funcMultiCore_log_run         (FuncMultiCore* sim_ptr,
                                        size_t core_id, uint64_t rob_idx);
void     funcMultiCore_log_commit      (FuncMultiCore* sim_ptr,
                                        size_t core_id, uint64_t rob_idx);

/* ---------- log control (per-core / global) ---------- */
/* core_id == -1 means "global / all device"; core_id >= 0 means a specific core. */
void enable_run_log     (int core_id);
void disable_run_log    (int core_id);
bool run_log_enabled    (int core_id);
void set_run_log        (const char* log_path);

void enable_commit_log  (int core_id);
void disable_commit_log (int core_id);
bool commit_log_enabled (int core_id);
void set_commit_log     (const char* log_path);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ISA_API_H */
