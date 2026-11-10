// Resolves flow ownership through SDK-defined libproc structures without private PCB offsets.
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <net/if.h>
#include <SystemConfiguration/SystemConfiguration.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <errno.h>

// Carries SDK socket identity and a normalized tuple across the native adapter boundary.
struct hy2_flow_owner {
    uint64_t start_seconds, start_microseconds, socket_identity;
    int32_t pid, descriptor;
    uint16_t source_port, destination_port;
    uint8_t ipv6, udp, unconnected, reserved;
    uint8_t source[16], destination[16];
};

// Checks the fixed-width adapter layout independently from the Rust compiler.
_Static_assert(sizeof(struct hy2_flow_owner) == 72, "unexpected flow owner ABI");

// Emits one socket owner while the caller retains all callback buffers synchronously.
typedef int (*hy2_owner_callback)(const struct hy2_flow_owner *, const char *, void *);

// Returns a monotonic timestamp for bounding one kernel metadata scan.
static uint64_t monotonic_ns(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return (uint64_t)value.tv_sec * 1000000000ULL + (uint64_t)value.tv_nsec;
}

// Resolves the pre-TUN primary interface without changing routes or network preferences.
unsigned int hy2_direct_interface(int ipv6) {
    int family = ipv6 ? AF_INET6 : AF_INET;
    CFStringRef key = family == AF_INET6 ? CFSTR("State:/Network/Global/IPv6") : CFSTR("State:/Network/Global/IPv4");
    CFDictionaryRef settings = SCDynamicStoreCopyValue(NULL, key);
    if (!settings || CFGetTypeID(settings) != CFDictionaryGetTypeID()) { if (settings) CFRelease(settings); return 0; }
    CFStringRef name = CFDictionaryGetValue(settings, CFSTR("PrimaryInterface"));
    char text[IF_NAMESIZE] = {0};
    unsigned int index = 0;
    if (name && CFGetTypeID(name) == CFStringGetTypeID() && CFStringGetCString(name, text, sizeof(text), kCFStringEncodingUTF8)
        && strncmp(text, "utun", 4) && strcmp(text, "lo0")) index = if_nametoindex(text);
    CFRelease(settings);
    return index;
}

// Reads a stable process start time without retaining a reusable PID as an identity.
static int process_identity(pid_t pid, struct proc_bsdinfo *info) {
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, info, sizeof(*info)) == (int)sizeof(*info);
}

// Extracts one protocol and address-family view from a public SDK socket record.
static int socket_owner(pid_t pid, int fd, int ipv6, const struct socket_fdinfo *info,
                        const struct proc_bsdinfo *process, struct hy2_flow_owner *owner) {
    if (info->psi.soi_protocol != IPPROTO_TCP && info->psi.soi_protocol != IPPROTO_UDP) return 0;
    if (info->psi.soi_family != AF_INET && info->psi.soi_family != AF_INET6) return 0;
    const struct in_sockinfo *inet = info->psi.soi_kind == SOCKINFO_TCP ? &info->psi.soi_proto.pri_tcp.tcpsi_ini :
                                   info->psi.soi_kind == SOCKINFO_IN ? &info->psi.soi_proto.pri_in : NULL;
    if (!inet || !(inet->insi_vflag & (ipv6 ? INI_IPV6 : INI_IPV4)) || !inet->insi_lport) return 0;
    memset(owner, 0, sizeof(*owner));
    owner->pid = pid; owner->descriptor = fd; owner->ipv6 = ipv6;
    owner->start_seconds = process->pbi_start_tvsec; owner->start_microseconds = process->pbi_start_tvusec;
    owner->socket_identity = info->psi.soi_so;
    owner->udp = info->psi.soi_protocol == IPPROTO_UDP;
    owner->source_port = ntohs((uint16_t)inet->insi_lport); owner->destination_port = ntohs((uint16_t)inet->insi_fport);
    int size = ipv6 ? 16 : 4;
    const void *local = ipv6 ? (const void *)&inet->insi_laddr.ina_6 : (const void *)&inet->insi_laddr.ina_46.i46a_addr4;
    const void *remote = ipv6 ? (const void *)&inet->insi_faddr.ina_6 : (const void *)&inet->insi_faddr.ina_46.i46a_addr4;
    memcpy(owner->source, local, (size_t)size); memcpy(owner->destination, remote, (size_t)size);
    static const uint8_t zero[16] = {0};
    owner->unconnected = owner->udp && !owner->destination_port && !memcmp(owner->destination, zero, sizeof(zero));
    return owner->unconnected || owner->destination_port != 0;
}

// Collects a complete bounded socket snapshot without deciding or caching routing policy in C.
int hy2_collect_flow_owners(hy2_owner_callback emit, void *context) {
    uint64_t deadline = monotonic_ns() + 150000000ULL;
    int count = proc_listallpids(NULL, 0);
    if (count <= 0 || count > 8192) return 0;
    count += 64;
    pid_t *pids = calloc((size_t)count, sizeof(pid_t));
    if (!pids) return 0;
    int actual = proc_listallpids(pids, count * (int)sizeof(pid_t));
    if (actual <= 0 || actual >= count) { free(pids); return 0; }
    unsigned int emitted = 0;
    for (int i = 0; i < actual; i++) {
        if (monotonic_ns() >= deadline) { free(pids); return 0; }
        pid_t pid = pids[i];
        if (pid <= 0 || pid == getpid()) continue;
        struct proc_bsdinfo before, after;
        if (!process_identity(pid, &before)) continue;
        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (proc_pidpath(pid, path, sizeof(path)) <= 0) continue;
        int bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
        if (bytes <= 0) continue;
        if (bytes > 16384 * (int)sizeof(struct proc_fdinfo)) { free(pids); return 0; }
        bytes += 32 * (int)sizeof(struct proc_fdinfo);
        struct proc_fdinfo *fds = malloc((size_t)bytes);
        if (!fds) { free(pids); return 0; }
        int used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, bytes);
        if (used >= bytes) { free(fds); free(pids); return 0; }
        if (!process_identity(pid, &after) || before.pbi_start_tvsec != after.pbi_start_tvsec || before.pbi_start_tvusec != after.pbi_start_tvusec) {
            free(fds); continue;
        }
        for (int f = 0; used > 0 && f < used / (int)sizeof(*fds); f++) {
            if ((f & 31) == 0 && monotonic_ns() >= deadline) { free(fds); free(pids); return 0; }
            if (fds[f].proc_fdtype != PROX_FDTYPE_SOCKET) continue;
            struct socket_fdinfo info;
            if (proc_pidfdinfo(pid, fds[f].proc_fd, PROC_PIDFDSOCKETINFO, &info, sizeof(info)) != (int)sizeof(info)) continue;
            for (int ipv6 = 0; ipv6 <= 1; ipv6++) {
                struct hy2_flow_owner owner;
                if (!socket_owner(pid, fds[f].proc_fd, ipv6, &info, &before, &owner)) continue;
                if (++emitted > 32768 || !emit(&owner, path, context)) { free(fds); free(pids); return 0; }
            }
        }
        free(fds);
    }
    free(pids);
    return monotonic_ns() < deadline;
}

// Revalidates PID start time, executable path, socket identity and tuple before any cached direct decision.
int hy2_validate_flow_owner(const struct hy2_flow_owner *expected, const char *expected_path) {
    struct proc_bsdinfo before, after;
    struct socket_fdinfo info;
    struct hy2_flow_owner current;
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (!expected->socket_identity || !process_identity(expected->pid, &before) ||
        before.pbi_start_tvsec != expected->start_seconds || before.pbi_start_tvusec != expected->start_microseconds ||
        proc_pidpath(expected->pid, path, sizeof(path)) <= 0 || strcmp(path, expected_path) ||
        proc_pidfdinfo(expected->pid, expected->descriptor, PROC_PIDFDSOCKETINFO, &info, sizeof(info)) != (int)sizeof(info) ||
        !socket_owner(expected->pid, expected->descriptor, expected->ipv6, &info, &before, &current) ||
        memcmp(expected, &current, sizeof(current)) || !process_identity(expected->pid, &after)) return 0;
    return before.pbi_start_tvsec == after.pbi_start_tvsec && before.pbi_start_tvusec == after.pbi_start_tvusec;
}

// Binds only the owned outgoing socket to the captured physical interface to avoid TUN recursion.
int hy2_bind_direct_socket(int descriptor, int ipv6, unsigned int index) {
    if (!index) { errno = ENETUNREACH; return -1; }
    return setsockopt(descriptor, ipv6 ? IPPROTO_IPV6 : IPPROTO_IP,
                      ipv6 ? IPV6_BOUND_IF : IP_BOUND_IF, &index, sizeof(index));
}

// Checks SDK-defined socket metadata access before a worker promises application routing support.
int hy2_process_lookup_available(void) {
    int descriptor = socket(AF_INET, SOCK_STREAM, 0);
    if (descriptor < 0) return 0;
    struct socket_fdinfo info;
    int result = proc_pidfdinfo(getpid(), descriptor, PROC_PIDFDSOCKETINFO, &info, sizeof(info));
    close(descriptor);
    return result == (int)sizeof(info);
}
