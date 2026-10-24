/*
 * Minimal <libproc.h> for iOS builds: the iOS SDK omits this macOS header,
 * but proc_pidinfo()/proc_pidpath() exist in iOS libSystem. Pair with the
 * sys/proc_info.h shim in this directory.
 */
#ifndef GOSTWG_SHIM_LIBPROC_H
#define GOSTWG_SHIM_LIBPROC_H

#include <sys/cdefs.h>
#include <sys/types.h>
#include <sys/param.h>		/* MAXPATHLEN */
#include <sys/proc_info.h>

#define PROC_PIDPATHINFO_MAXSIZE	(4 * MAXPATHLEN)

__BEGIN_DECLS
int	proc_pidinfo(int pid, uint32_t flavor, uint64_t arg,
	    void *buffer, int buffersize);
int	proc_pidpath(int pid, void *buffer, uint32_t buffersize);
__END_DECLS

#endif /* GOSTWG_SHIM_LIBPROC_H */
