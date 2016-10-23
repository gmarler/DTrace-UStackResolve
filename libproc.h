/*
 * Interfaces available from the process control library, libproc.
 */

#ifndef	_LIBPROC_H
#define	_LIBPROC_H

#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <nlist.h>
#include <door.h>
#include <gelf.h>
#include <proc_service.h>
#include <rtld_db.h>
#include <procfs.h>
#include <ucred.h>
#include <rctl.h>
#include <libctf.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/auxv.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/utsname.h>
#include <sys/corectl.h>
#if defined(__i386) || defined(__amd64)
#include <sys/sysi86.h>
#endif

#ifdef	__cplusplus
extern "C" {
#endif

extern struct ps_prochandle *Pgrab_file(const char *, int *);

extern int Pobject_iter(struct ps_prochandle *, proc_map_f *, void *);
extern int Pobject_iter_resolved(struct ps_prochandle *, proc_map_f *, void *);

extern int Psymbol_iter(struct ps_prochandle *,
    const char *, int, int, proc_sym_f *, void *);

extern const char *Pgrab_error(int);

extern	void	Pfree(struct ps_prochandle *);

#ifdef	__cplusplus
}
#endif

#endif	/* _LIBPROC_H */
