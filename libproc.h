/*
 * Interfaces available from the process control library, libproc.
 */

#ifndef	_LIBPROC_H
#define	_LIBPROC_H

#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <nlist.h>
#include <gelf.h>

#ifdef	__cplusplus
extern "C" {
#endif

/*
 * Opaque structure tag reference to a process control structure.
 * Clients of libproc cannot look inside the process control structure.
 * The implementation of struct ps_prochandle can change w/o affecting clients.
 */
struct ps_prochandle;

/*
 * Opaque structure tag reference to an lwp control structure.
 */
struct ps_lwphandle;

extern	int	_libproc_debug;	/* set non-zero to enable debugging fprintfs */
extern	int	_libproc_no_qsort;	/* set non-zero to inhibit sorting */
                                /* of symbol tables */
extern	int	_libproc_incore_elf;	/* only use in-core elf data */

/* Flags accepted by Pgrab() */
#define	PGRAB_RETAIN	0x01	/* Retain tracing flags, else clear flags */
#define	PGRAB_FORCE	0x02	/* Open the process w/o O_EXCL */
#define	PGRAB_RDONLY	0x04	/* Open the process or core w/ O_RDONLY */
#define	PGRAB_NOSTOP	0x08	/* Open the process but do not stop it */
#define	PGRAB_INCORE	0x10	/* Use in-core data to build symbol tables */

/* Error codes from Pgrab(), Pfgrab_core(), and Pgrab_core() */
#define	G_STRANGE	-1	/* Unanticipated error, errno is meaningful */
#define	G_NOPROC	1	/* No such process */
#define	G_NOCORE	2	/* No such core file */
#define	G_NOPROCORCORE	3	/* No such proc or core (for proc_arg_grab) */
#define	G_NOEXEC	4	/* Cannot locate executable file */
#define	G_ZOMB		5	/* Zombie process */
#define	G_PERM		6	/* No permission */
#define	G_BUSY		7	/* Another process has control */
#define	G_SYS		8	/* System process */
#define	G_SELF		9	/* Process is self */
#define	G_INTR		10	/* Interrupt received while grabbing */
#define	G_LP64		11	/* Process is _LP64, self is ILP32 */
#define	G_FORMAT	12	/* File is not an ELF format core file */
#define	G_ELF		13	/* Libelf error, elf_errno() is meaningful */
#define	G_NOTE		14	/* Required PT_NOTE Phdr not present in core */
#define	G_ISAINVAL	15	/* Wrong ELF machine type */
#define	G_BADLWPS	16	/* Bad '/lwps' specification */
#define	G_NOFD		17	/* No more file descriptors */


/*
 * Function prototypes for routines in the process control package.
 */
extern struct ps_prochandle *Pgrab(pid_t, int, int *);
extern struct ps_prochandle *Pgrab_file(const char *, int *);
extern const char *Pgrab_error(int);

extern	void	Pfree(struct ps_prochandle *);

/*
 * Symbol table interfaces.
 */

/*
 * Pseudo-names passed to Plookup_by_name() for well-known load objects.
 * NOTE: It is required that PR_OBJ_EXEC and PR_OBJ_LDSO exactly match
 * the definitions of PS_OBJ_EXEC and PS_OBJ_LDSO from <proc_service.h>.
 */
#define	PR_OBJ_EXEC	((const char *)0)	/* search the executable file */
#define	PR_OBJ_LDSO	((const char *)1)	/* search ld.so.1 */
#define	PR_OBJ_EVERY	((const char *)-1)	/* search every load object */

/*
 * 'object_name' is the name of a load object obtained from an
 * iteration over the process's address space mappings (Pmapping_iter),
 * or an iteration over the process's mapped objects (Pobject_iter),
 * or else it is one of the special PR_OBJ_* values above.
 */
extern int Plookup_by_name(struct ps_prochandle *,
    const char *, const char *, GElf_Sym *);

extern int Plookup_by_addr(struct ps_prochandle *,
    uintptr_t, char *, size_t, GElf_Sym *);

extern int Pmapping_iter(struct ps_prochandle *, void *, void *);
extern int Pmapping_iter_resolved(struct ps_prochandle *, void *, void *);
extern int Pobject_iter(struct ps_prochandle *, void *, void *);
extern int Pobject_iter_resolved(struct ps_prochandle *, void *, void *);

/*
 * Symbol table iteration interface.  The special lmid constants LM_ID_BASE,
 * LM_ID_LDSO, and PR_LMID_EVERY may be used with Psymbol_iter_by_lmid.
 */

extern int Psymbol_iter(struct ps_prochandle *,
                        const char *, int, int, void *, void *);
extern int Psymbol_iter_by_addr(struct ps_prochandle *,
    const char *, int, int, void *, void *);
extern int Psymbol_iter_by_name(struct ps_prochandle *,
    const char *, int, int, void *, void *);

/*
 * 'which' selects which symbol table and can be one of the following.
 */
#define	PR_SYMTAB	1
#define	PR_DYNSYM	2
/*
 * 'type' selects the symbols of interest by binding and type.  It is a bit-
 * mask of one or more of the following flags, whose order MUST match the
 * order of STB and STT constants in <sys/elf.h>.
 */
#define	BIND_LOCAL	0x0001
#define	BIND_GLOBAL	0x0002
#define	BIND_WEAK	0x0004
#define	BIND_ANY (BIND_LOCAL|BIND_GLOBAL|BIND_WEAK)
#define	TYPE_NOTYPE	0x0100
#define	TYPE_OBJECT	0x0200
#define	TYPE_FUNC	0x0400
#define	TYPE_SECTION	0x0800
#define	TYPE_FILE	0x1000
#define	TYPE_ANY (TYPE_NOTYPE|TYPE_OBJECT|TYPE_FUNC|TYPE_SECTION|TYPE_FILE)

/*
 * This should be called when an RD_DLACTIVITY event with the
 * RD_CONSISTENT state occurs via librtld_db's event mechanism.
 * This makes libproc's address space mappings and symbol tables current.
 * The variant Pupdate_syms() can be used to preload all symbol tables as well.
 */
extern void Pupdate_maps(struct ps_prochandle *);
extern void Pupdate_syms(struct ps_prochandle *);

/*
 * This must be called after the victim process performs a successful
 * exec() if any of the symbol table interface functions have been called
 * prior to that point.  This is essential because an exec() invalidates
 * all previous symbol table and address space mapping information.
 * It is always safe to call, but if it is called other than after an
 * exec() by the victim process it just causes unnecessary overhead.
 *
 * The rtld_db agent handle obtained from a previous call to Prd_agent() is
 * made invalid by Preset_maps() and Prd_agent() must be called again to get
 * the new handle.
 */
extern void Preset_maps(struct ps_prochandle *);

/*
 * Given an address, Ppltdest() determines if this is part of a PLT, and if
 * so returns a pointer to the symbol name that will be used for resolution.
 * If the specified address is not part of a PLT, the function returns NULL.
 */
extern const char *Ppltdest(struct ps_prochandle *, uintptr_t);

/*
 * See comments for Pissyscall(), in Pisadep.h
 */
extern int Pissyscall_prev(struct ps_prochandle *, uintptr_t, uintptr_t *);

/*
 * The following functions define a set of passive interfaces: libproc provides
 * default, empty definitions that are called internally.  If a client wishes
 * to override these definitions, it can simply provide its own version with
 * the same signature that interposes on the libproc definition.
 *
 * If the client program wishes to report additional error information, it
 * can provide its own version of Perror_printf.
 *
 * If the client program wishes to receive a callback after Pcreate forks
 * but before it execs, it can provide its own version of Pcreate_callback.
 */
extern void Perror_printf(struct ps_prochandle *P, const char *format, ...);
extern void Pcreate_callback(struct ps_prochandle *);

/*
 * Remove unprintable characters from psinfo.pr_psargs and replace with
 * whitespace characters so it is safe for printing.
 */

/*
 * Iterate over all open files.
 */
/*
typedef int proc_fdinfo_f(void *, prfdinfo_t *);
extern int Pfdinfo_iter(struct ps_prochandle *, proc_fdinfo_f *, void *);
*/

#ifdef	__cplusplus
}
#endif

#endif   /* _LIBPROC_H */
