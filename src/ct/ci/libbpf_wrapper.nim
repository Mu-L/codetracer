## Minimal Nim FFI bindings for libbpf.
##
## Wraps only the libbpf C API functions needed by ``bpf_monitor_native.nim``
## for loading BPF programs, managing maps, and polling ring buffers.
##
## Nim does not allow consecutive underscores in identifiers, so the C
## functions with ``__`` in their names (e.g. ``bpf_object__open_file``)
## are exposed with single underscores (e.g. ``bpfObjectOpenFile``) and
## use ``importc`` to specify the exact C symbol name.
##
## libbpf documentation: https://libbpf.readthedocs.io/en/latest/api.html
##
## Link-time dependencies: ``-lbpf -lelf -lz``

# Link and include flags for libbpf.
# In the Nix dev shell, these are resolved via LIBRARY_PATH and C_INCLUDE_PATH.
# For standalone builds, ensure libbpf development headers are installed.
{.passL: "-lbpf".}
{.passL: "-lelf".}
{.passL: "-lz".}

# pkg-config is the portable way to find libbpf headers. The Nix shell
# sets PKG_CONFIG_PATH so this works automatically.
when defined(usePkgConfig):
  {.passC: gorge("pkg-config --cflags libbpf").}
  {.passL: gorge("pkg-config --libs libbpf").}

type
  ## Opaque libbpf types — never dereferenced from Nim, only passed as pointers.
  BpfObject* {.importc: "struct bpf_object", header: "<bpf/libbpf.h>", incompleteStruct.} = object
  BpfProgram* {.importc: "struct bpf_program", header: "<bpf/libbpf.h>", incompleteStruct.} = object
  BpfMap* {.importc: "struct bpf_map", header: "<bpf/libbpf.h>", incompleteStruct.} = object
  BpfLink* {.importc: "struct bpf_link", header: "<bpf/libbpf.h>", incompleteStruct.} = object
  RingBuffer* {.importc: "struct ring_buffer", header: "<bpf/libbpf.h>", incompleteStruct.} = object

  ## Callback type for ring buffer event processing.
  RingBufferCallback* = proc(ctx: pointer, data: pointer, size: csize_t): cint {.cdecl.}

# ---------------------------------------------------------------------------
# BPF object lifecycle
# ---------------------------------------------------------------------------

proc bpfObjectOpenFile*(path: cstring, opts: pointer): ptr BpfObject
  {.importc: "bpf_object__open_file", header: "<bpf/libbpf.h>".}
  ## Opens a BPF ELF object file and parses it.
  ## Returns NULL on failure (check errno).

proc bpfObjectLoad*(obj: ptr BpfObject): cint
  {.importc: "bpf_object__load", header: "<bpf/libbpf.h>".}
  ## Loads all BPF programs and creates all maps in the kernel.
  ## Returns 0 on success, negative errno on failure.

proc bpfObjectClose*(obj: ptr BpfObject)
  {.importc: "bpf_object__close", header: "<bpf/libbpf.h>".}
  ## Releases all resources associated with the BPF object.

# ---------------------------------------------------------------------------
# Program lookup and attachment
# ---------------------------------------------------------------------------

proc bpfObjectFindProgramByName*(obj: ptr BpfObject, name: cstring): ptr BpfProgram
  {.importc: "bpf_object__find_program_by_name", header: "<bpf/libbpf.h>".}
  ## Finds a BPF program by its function name.
  ## Returns NULL if not found.

proc bpfProgramAttach*(prog: ptr BpfProgram): ptr BpfLink
  {.importc: "bpf_program__attach", header: "<bpf/libbpf.h>".}
  ## Auto-detects the program type and attaches it.
  ## Returns NULL on failure.

proc bpfProgramAttachTracepoint*(prog: ptr BpfProgram,
    tpCategory: cstring, tpName: cstring): ptr BpfLink
  {.importc: "bpf_program__attach_tracepoint", header: "<bpf/libbpf.h>".}
  ## Attaches a BPF program to a kernel tracepoint.
  ## Returns NULL on failure.

proc bpfProgramAttachKprobe*(prog: ptr BpfProgram,
    retprobe: bool, funcName: cstring): ptr BpfLink
  {.importc: "bpf_program__attach_kprobe", header: "<bpf/libbpf.h>".}
  ## Attaches to a kprobe (retprobe=false) or kretprobe (retprobe=true).
  ## Returns NULL on failure.

proc bpfLinkDestroy*(link: ptr BpfLink): cint
  {.importc: "bpf_link__destroy", header: "<bpf/libbpf.h>".}
  ## Detaches and destroys a BPF link.

# ---------------------------------------------------------------------------
# Map lookup and manipulation
# ---------------------------------------------------------------------------

proc bpfObjectFindMapByName*(obj: ptr BpfObject, name: cstring): ptr BpfMap
  {.importc: "bpf_object__find_map_by_name", header: "<bpf/libbpf.h>".}
  ## Finds a BPF map by its variable name.
  ## Returns NULL if not found.

proc bpfMapFd*(map: ptr BpfMap): cint
  {.importc: "bpf_map__fd", header: "<bpf/libbpf.h>".}
  ## Returns the file descriptor of a loaded BPF map.

proc bpfMapUpdateElem*(fd: cint, key: pointer, value: pointer,
    flags: uint64): cint
  {.importc: "bpf_map_update_elem", header: "<bpf/bpf.h>".}
  ## Updates (or creates) an element in a BPF map.
  ## flags: 0 = BPF_ANY, 1 = BPF_NOEXIST, 2 = BPF_EXIST.

proc bpfMapLookupElem*(fd: cint, key: pointer, value: pointer): cint
  {.importc: "bpf_map_lookup_elem", header: "<bpf/bpf.h>".}
  ## Looks up a value in a BPF map by key.

proc bpfMapDeleteElem*(fd: cint, key: pointer): cint
  {.importc: "bpf_map_delete_elem", header: "<bpf/bpf.h>".}
  ## Deletes an element from a BPF map by key.

# ---------------------------------------------------------------------------
# Ring buffer
# ---------------------------------------------------------------------------

proc ringBufferNew*(mapFd: cint, cb: RingBufferCallback,
    ctx: pointer, opts: pointer): ptr RingBuffer
  {.importc: "ring_buffer__new", header: "<bpf/libbpf.h>".}
  ## Creates a new ring buffer consumer.

proc ringBufferPoll*(rb: ptr RingBuffer, timeoutMs: cint): cint
  {.importc: "ring_buffer__poll", header: "<bpf/libbpf.h>".}
  ## Polls for new events (invokes callback for each).
  ## timeoutMs: -1=block, 0=non-blocking, >0=timeout in ms.

proc ringBufferFree*(rb: ptr RingBuffer)
  {.importc: "ring_buffer__free", header: "<bpf/libbpf.h>".}
  ## Frees a ring buffer consumer.

# ---------------------------------------------------------------------------
# Error handling
# ---------------------------------------------------------------------------

proc libbpfStrerror*(err: cint, buf: cstring, size: csize_t): cint
  {.importc: "libbpf_strerror", header: "<bpf/libbpf.h>".}
  ## Converts a libbpf error code to a human-readable string.

proc libbpfError*(err: cint): string =
  ## Converts a negative errno from libbpf to a human-readable error string.
  var buf: array[256, char]
  let rc = libbpfStrerror(err, cast[cstring](addr buf[0]), csize_t(sizeof(buf)))
  if rc == 0:
    result = $cast[cstring](addr buf[0])
  else:
    result = "libbpf error " & $err
