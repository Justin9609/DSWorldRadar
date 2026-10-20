/* DSWorldRadar WCX bridge 2802, 2026-10-15.
 * This is the project's auxiliary WorldComplete bridge, not MnM Radar's core.
 * Win64 / pinned UE4SS LuaJIT ABI: lua_State.top at +0x10, 16-byte TValue,
 * integer tag 3. Same exports and return ordering as bridge 2801.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include "wcx_resolver.h"

#define API __declspec(dllexport)
#define PATCH_SIZE 16
typedef struct { int64_t value; uint64_t tag; } LuaValue;
typedef uintptr_t (*IncrementFn)(void *, uint32_t, uint32_t);
typedef int32_t (*CountFn)(void *, uint32_t, uint32_t);
static SRWLOCK state_lock = SRWLOCK_INIT;
static volatile LONG installed = 0;
static int64_t status = 0, seq = 0, opened = -1, total = -1;
static uint32_t fog = 0, mission = 0;
static uintptr_t handler = 0, target_rva = 0, current_rva = 0, total_rva = 0;
static uint8_t *target = NULL, *trampoline = NULL;
static uint8_t saved[PATCH_SIZE], patch[PATCH_SIZE];
static CountFn get_current = NULL, get_total = NULL;
static const uint32_t regions[] = {
  100000,10101,10102,10103,10104,10105,10106,10107,10108,10109,10110,10111
};

static void push_integer(void *L, int64_t n) {
  LuaValue **top = (LuaValue **)((uint8_t *)L + 0x10);
  (*top)->value = n;
  (*top)->tag = 3;
  ++(*top);
}
static void absolute_jump(uint8_t *dst, const void *address) {
  /* RIP-indirect jump preserves RAX, including instructions replayed by the
   * trampoline. It is 14 bytes, followed by padding when patching 16 bytes. */
  dst[0]=0xff; dst[1]=0x25;
  dst[2]=dst[3]=dst[4]=dst[5]=0;
  uintptr_t p=(uintptr_t)address;
  memcpy(dst+6,&p,sizeof p);
}
static uintptr_t on_increment(void *self, uint32_t section, uint32_t type) {
  uintptr_t result=((IncrementFn)(void *)trampoline)(self,section,type);
  int64_t a=0,b=0;
  if (!self || type < 1 || type > 255 || !get_current || !get_total) {
    a=b=-1;
  } else {
    for (size_t i=0;i<sizeof regions/sizeof regions[0];++i) {
      int32_t x=get_current(self,regions[i],type);
      int32_t y=get_total(self,regions[i],type);
      if (x<0 || y<0 || x>y || y>5000) { a=b=-1; break; }
      a+=x; b+=y;
    }
  }
  AcquireSRWLockExclusive(&state_lock);
  handler=(uintptr_t)self; fog=section; mission=type;
  opened=a; total=b; ++seq;
  ReleaseSRWLockExclusive(&state_lock);
  return result;
}

static int find_game_text(uint8_t *base, uint8_t **text, size_t *size) {
  if (!base) return -1;
  IMAGE_DOS_HEADER *dos=(IMAGE_DOS_HEADER *)base;
  if (dos->e_magic!=IMAGE_DOS_SIGNATURE || dos->e_lfanew<0x40 || dos->e_lfanew>0x100000) return -3;
  IMAGE_NT_HEADERS64 *nt=(IMAGE_NT_HEADERS64 *)(base+dos->e_lfanew);
  if (nt->Signature!=IMAGE_NT_SIGNATURE || nt->OptionalHeader.Magic!=IMAGE_NT_OPTIONAL_HDR64_MAGIC ||
      nt->FileHeader.Machine!=IMAGE_FILE_MACHINE_AMD64 || nt->FileHeader.NumberOfSections>96) return -3;
  IMAGE_SECTION_HEADER *s=IMAGE_FIRST_SECTION(nt);
  for (unsigned i=0;i<nt->FileHeader.NumberOfSections;++i,++s) {
    if (memcmp(s->Name,".text\0",6)) continue;
    size_t n=s->Misc.VirtualSize;
    if (!(s->Characteristics & IMAGE_SCN_MEM_EXECUTE) || n<sizeof WCX_TOTAL_SIG ||
        s->VirtualAddress>=nt->OptionalHeader.SizeOfImage ||
        n>nt->OptionalHeader.SizeOfImage-s->VirtualAddress) return -3;
    *text=base+s->VirtualAddress; *size=n; return 1;
  }
  return -3;
}

API int wcx_bridge_version(void *L) { push_integer(L,2802); return 1; }
API int wcx_install(void *L) {
  int64_t result;
  if (InterlockedCompareExchange(&installed,2,0)!=0) {
    result=(installed==1)?2:-7;
  } else {
    uint8_t *base=(uint8_t *)GetModuleHandleW(NULL),*text=NULL;
    size_t size=0;
    result=find_game_text(base,&text,&size);
    WcxTargets t;
    if (result==1) result=wcx_resolve(text,size,&t);
    if (result==1) {
      target=text+t.increment;
      get_current=(CountFn)(void *)(text+t.current);
      get_total=(CountFn)(void *)(text+t.total);
      target_rva=(uintptr_t)(target-base);
      current_rva=(uintptr_t)((text+t.current)-base);
      total_rva=(uintptr_t)((text+t.total)-base);
      /* These 16 verified bytes end at an instruction boundary and have no
       * relative operands. Do not broaden the signature without rechecking. */
      memcpy(saved,target,PATCH_SIZE);
      trampoline=(uint8_t *)VirtualAlloc(NULL,32,MEM_COMMIT|MEM_RESERVE,PAGE_READWRITE);
      if (!trampoline) result=-6;
      if (result==1) {
        memcpy(trampoline,saved,PATCH_SIZE);
        absolute_jump(trampoline+PATCH_SIZE,target+PATCH_SIZE);
        DWORD previous;
        if (!VirtualProtect(trampoline,32,PAGE_EXECUTE_READ,&previous) ||
            !FlushInstructionCache(GetCurrentProcess(),trampoline,32)) result=-6;
      }
      HMODULE pinned=NULL;
      if (result==1 && !GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_PIN,
                         (LPCWSTR)(const void *)&on_increment,&pinned)) result=-6;
      if (result==1) {
        memset(patch,0x90,sizeof patch);
        absolute_jump(patch,(const void *)&on_increment);
        DWORD previous,ignored;
        if (!VirtualProtect(target,PATCH_SIZE,PAGE_EXECUTE_READWRITE,&previous)) result=-6;
        else {
          memcpy(target,patch,PATCH_SIZE);
          FlushInstructionCache(GetCurrentProcess(),target,PATCH_SIZE);
          VirtualProtect(target,PATCH_SIZE,previous,&ignored);
        }
      }
    }
    if (result!=1 && trampoline) { VirtualFree(trampoline,0,MEM_RELEASE); trampoline=NULL; }
    status=result;
    InterlockedExchange(&installed,result==1?1:0);
  }
  push_integer(L,result); push_integer(L,(int64_t)target_rva);
  push_integer(L,(int64_t)current_rva); push_integer(L,(int64_t)total_rva);
  return 4;
}
API int wcx_poll(void *L) {
  AcquireSRWLockShared(&state_lock);
  push_integer(L,seq); push_integer(L,fog); push_integer(L,mission);
  push_integer(L,status); push_integer(L,opened); push_integer(L,total);
  push_integer(L,(int64_t)handler);
  ReleaseSRWLockShared(&state_lock);
  return 7;
}
API int wcx_uninstall(void *L) {
  int result=0;
  if (installed==1 && target) {
    if (memcmp(target,patch,PATCH_SIZE)) result=-8;
    else {
      DWORD previous,ignored;
      if (VirtualProtect(target,PATCH_SIZE,PAGE_EXECUTE_READWRITE,&previous)) {
        memcpy(target,saved,PATCH_SIZE);
        FlushInstructionCache(GetCurrentProcess(),target,PATCH_SIZE);
        VirtualProtect(target,PATCH_SIZE,previous,&ignored);
        InterlockedExchange(&installed,0); status=0; result=1;
        /* A callback may still be returning through the trampoline. Retain
         * this tiny allocation and the pinned module until process exit. */
      } else result=-6;
    }
  }
  push_integer(L,result); return 1;
}
