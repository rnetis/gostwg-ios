/*
 * Minimal sys/proc_info.h for iOS builds.
 *
 * The iOS SDK does not ship <sys/proc_info.h> (macOS-only header), but the
 * underlying libproc interfaces exist in iOS libSystem. Only what
 * gopsutil/v3's darwin-cgo files reference is declared here.
 */
#ifndef GOSTWG_SHIM_SYS_PROC_INFO_H
#define GOSTWG_SHIM_SYS_PROC_INFO_H

#include <sys/cdefs.h>
#include <sys/types.h>
#include <sys/time.h>
#include <stdint.h>

#define PROC_PID_LISTFDS       1
#define PROC_PIDTASKINFO       4
#define PROC_PIDVNODEPATHINFO  9

struct vinfo_stat {
	uint64_t	vst_dev;
	uint32_t	vst_mode;
	uint32_t	vst_nlink;
	uint64_t	vst_ino;
	uint32_t	vst_uid;
	uint32_t	vst_gid;
	int64_t		vst_atime;
	int64_t		vst_atimensec;
	int64_t		vst_mtime;
	int64_t		vst_mtimensec;
	int64_t		vst_ctime;
	int64_t		vst_ctimensec;
	int64_t		vst_birthtime;
	int64_t		vst_birthtimensec;
	int64_t		vst_size;
	uint64_t	vst_blocks;
	uint32_t	vst_blksize;
	uint32_t	vst_flags;
	uint32_t	vst_gen;
	uint32_t	vst_rdev;
	uint64_t	vst_qspare[8];
};

struct vnode_info {
	struct vinfo_stat	vi_stat;
	uint64_t		vi_fsid[2];
};

struct vnode_info_path {
	struct vnode_info	vip_vi;
	char			vip_path[MAXPATHLEN];
};

struct proc_vnodepathinfo {
	struct vnode_info_path	pvi_cdir;
	struct vnode_info_path	pvi_rdir;
};

struct proc_taskinfo {
	uint64_t	pti_virtual_size;
	uint64_t	pti_resident_size;
	uint64_t	pti_total_user;
	uint64_t	pti_total_system;
	uint64_t	pti_threads_user;
	uint64_t	pti_threads_system;
	int32_t		pti_policy;
	int32_t		pti_faults;
	int32_t		pti_pageins;
	int32_t		pti_cow_faults;
	int32_t		pti_messages_sent;
	int32_t		pti_messages_received;
	int32_t		pti_syscalls_mach;
	int32_t		pti_syscalls_unix;
	int32_t		pti_csw;
	int32_t		pti_threadnum;
	int32_t		pti_numrunning;
	int32_t		pti_priority;
};

#endif /* GOSTWG_SHIM_SYS_PROC_INFO_H */
