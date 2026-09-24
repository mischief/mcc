/* SPDX-License-Identifier: ISC */
/* The unwinder interface of the Itanium C++ ABI, which libgcc_s and
   libunwind both provide.  A compiler ships this header, not libc. */
#ifndef _UNWIND_H
#define _UNWIND_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef uintptr_t _Unwind_Word;
typedef intptr_t _Unwind_Sword;
typedef uintptr_t _Unwind_Ptr;
typedef uintptr_t _Unwind_Internal_Ptr;
typedef uint64_t _Unwind_Exception_Class;

typedef enum {
	_URC_NO_REASON = 0,
	_URC_OK = 0,
	_URC_FOREIGN_EXCEPTION_CAUGHT = 1,
	_URC_FATAL_PHASE2_ERROR = 2,
	_URC_FATAL_PHASE1_ERROR = 3,
	_URC_NORMAL_STOP = 4,
	_URC_END_OF_STACK = 5,
	_URC_HANDLER_FOUND = 6,
	_URC_INSTALL_CONTEXT = 7,
	_URC_CONTINUE_UNWIND = 8,
	_URC_FAILURE = 9
} _Unwind_Reason_Code;

typedef int _Unwind_Action;
#define _UA_SEARCH_PHASE	1
#define _UA_CLEANUP_PHASE	2
#define _UA_HANDLER_FRAME	4
#define _UA_FORCE_UNWIND	8
#define _UA_END_OF_STACK	16

struct _Unwind_Context;
struct _Unwind_Exception;
typedef struct _Unwind_Exception _Unwind_Exception;

typedef void (*_Unwind_Exception_Cleanup_Fn)(_Unwind_Reason_Code,
    struct _Unwind_Exception *);

struct _Unwind_Exception {
	_Unwind_Exception_Class exception_class;
	_Unwind_Exception_Cleanup_Fn exception_cleanup;
	_Unwind_Word private_1;
	_Unwind_Word private_2;
} __attribute__((__aligned__(16)));

typedef _Unwind_Reason_Code (*_Unwind_Stop_Fn)(int, _Unwind_Action,
    _Unwind_Exception_Class, struct _Unwind_Exception *,
    struct _Unwind_Context *, void *);
typedef _Unwind_Reason_Code (*_Unwind_Trace_Fn)(struct _Unwind_Context *,
    void *);
typedef _Unwind_Reason_Code (*_Unwind_Personality_Fn)(int, _Unwind_Action,
    _Unwind_Exception_Class, struct _Unwind_Exception *,
    struct _Unwind_Context *);

_Unwind_Reason_Code _Unwind_RaiseException(struct _Unwind_Exception *);
_Unwind_Reason_Code _Unwind_ForcedUnwind(struct _Unwind_Exception *,
    _Unwind_Stop_Fn, void *);
_Unwind_Reason_Code _Unwind_Resume_or_Rethrow(struct _Unwind_Exception *);
void _Unwind_Resume(struct _Unwind_Exception *);
void _Unwind_DeleteException(struct _Unwind_Exception *);
_Unwind_Reason_Code _Unwind_Backtrace(_Unwind_Trace_Fn, void *);

_Unwind_Word _Unwind_GetGR(struct _Unwind_Context *, int);
void _Unwind_SetGR(struct _Unwind_Context *, int, _Unwind_Word);
_Unwind_Word _Unwind_GetIP(struct _Unwind_Context *);
_Unwind_Word _Unwind_GetIPInfo(struct _Unwind_Context *, int *);
void _Unwind_SetIP(struct _Unwind_Context *, _Unwind_Word);
_Unwind_Word _Unwind_GetCFA(struct _Unwind_Context *);
void *_Unwind_GetLanguageSpecificData(struct _Unwind_Context *);
_Unwind_Ptr _Unwind_GetRegionStart(struct _Unwind_Context *);
_Unwind_Ptr _Unwind_GetDataRelBase(struct _Unwind_Context *);
_Unwind_Ptr _Unwind_GetTextRelBase(struct _Unwind_Context *);
void *_Unwind_FindEnclosingFunction(void *);

#ifdef __cplusplus
}
#endif

#endif
