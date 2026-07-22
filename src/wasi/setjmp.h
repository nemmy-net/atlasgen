#ifndef ATLASGEN_WASI_SETJMP_H
#define ATLASGEN_WASI_SETJMP_H

/*
 * WASI Preview 1 has no setjmp/longjmp ABI.  FreeType uses it only to abort
 * internal parsing/rasterization after detecting malformed input.  Atlasgen
 * validates normal fonts through FreeType; an attempted non-local jump is an
 * unrecoverable malformed-font path in this CLI.
 */
typedef struct {
    unsigned char opaque[32];
} jmp_buf[1];

#define setjmp(environment) (0)
#define longjmp(environment, value) __builtin_trap()

#endif
