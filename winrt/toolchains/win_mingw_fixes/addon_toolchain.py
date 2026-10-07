#!/usr/bin/env python3
"""CC / CXX / LINK / AR for Node native addons built for win-arm32 by node-gyp.

usage: addon_toolchain.py cc|cxx|link|ar <arguments from the gyp Makefile>
       addon_toolchain.py cxxlib <output .lib>

node-gyp generates the addon's Makefiles with gyp_make_win.py (gyp's make
generator plus gyp's own Windows translation of each target's msvs_settings).
Every flag in them is therefore cl / link syntax, as a Windows build of the
addon would use, and the only other arguments are the fixed forms of the make
generator's own rules (-o, -c, -MMD -MF for C/C++; -shared, -Wl,-soname=,
-Wl,--start-group/--end-group for links; `crs` for archives). This script turns
those rule forms into the Electron build's own commands and adds the
configuration every Electron object and image has, read from the Electron build
directory (not restated here):
  * compile: clang-cl with the values gn itself reports (gn desc --blame, see
    ABI_CONFIGS below) for the configs that define the platform every Electron
    object targets -- triple, MS compatibility, header search order, Chromium's
    libc++ (std::Cr) -- without their diagnostics and whole-program settings;
    the Makefile's own (msvs_settings) flags decide the rest, as for MSVC.
  * link: the Electron toolchain's own rules in toolchain.ninja (`link` for
    executables, `solink` for DLLs, `solink_module` for .node modules), with
    Chromium's C++ runtime that every C++ image of the build links (the objects
    of //buildtools/third_party/libc++ and libc++abi.lib).
  * archive: the Electron toolchain's `alink` rule (lld-link /lib).
Any argument outside those forms is an error, never dropped.

Each addon image carries its own static C/C++ runtime (static Microsoft CRT,
Chromium's libc++ objects, libc++abi.lib), as every Windows addon does under
node's common.gypi (RuntimeLibrary /MT); objects crossing the electron.exe
boundary are created and released through the V8/node API as on any Windows
build, and with the same libc++ (std::Cr) their std-typed V8 APIs have
electron.exe's layout and mangling.

WRT_ELECTRON_OUT: the Electron build directory (e.g. <src>/out/electron).
WRT_ADDON_ABI_DIR: directory with the gn desc --blame outputs (see ABI_DIR).
"""

import os
import re
import shlex
import subprocess
import sys

OUT = os.path.abspath(os.environ['WRT_ELECTRON_OUT'])
SRC = os.path.normpath(os.path.join(OUT, '..', '..'))
# `gn desc <out> <target> <what> --blame` output for cflags, cflags_c,
# cflags_cc, defines and include_dirs of a C++ target of the arm toolchain
# (vscode_native.ninja writes them as <dir>/<what>.txt).
ABI_DIR = os.environ['WRT_ADDON_ABI_DIR']

# The configs that define the target platform every Electron object is built
# for: //build/config/compiler:compiler (Chromium's per-platform compiler
# configuration; for win-arm32 the -gnu triple, MS compatibility, the port's
# header search order), :compiler_arm_fpu, and :runtime_library (Chromium's
# libc++ / libc++abi headers and __config_site -- _LIBCPP_ABI_NAMESPACE Cr --
# and the platform defines). Everything else a GN target gets (optimization,
# symbols, CRT flavour, /guard:cf, warnings, UNICODE, NDEBUG ...) is a per-
# target choice, which for an addon its msvs_settings make (as in an MSVC build).
ABI_CONFIGS = ('//build/config/compiler:compiler',
               '//build/config/compiler:compiler_arm_fpu',
               '//build/config/compiler:runtime_library')
# Within those configs, two kinds do not apply to a separately linked addon:
# diagnostics (the module's own warning settings apply, as in an MSVC build of
# it) and the electron.exe image's whole-program optimization (ThinLTO and
# whole-program vtables assume every derived class is in the image; across the
# electron.exe boundary that is false).
_DIAGNOSTIC = re.compile(r'^(-W|/W|-fcolor-diagnostics$|-fcrash-diagnostics-dir=)')
_WHOLE_PROGRAM = re.compile(r'^(-flto|-fsplit-lto-unit$|-fwhole-program-vtables$)')


def _rebase(arg):
  """Makes a build-directory-relative path inside an argument absolute."""
  i = arg.find('../')
  if i >= 0 and re.match(r'^(|-I|.*[:=])$', arg[:i]):
    return arg[:i] + os.path.normpath(os.path.join(OUT, arg[i:]))
  return arg


def _blamed(what):
  """The values of `what` that come from ABI_CONFIGS, in gn's order."""
  values, config = [], None
  for line in open(os.path.join(ABI_DIR, what + '.txt')):
    line = line.strip()
    if line.startswith('From '):
      config = line.split()[1]
    elif line and not line.startswith('(') and config in ABI_CONFIGS:
      values.append(line)
  return values


def _check_abi_configs():
  """Each of ABI_CONFIGS must be attributed some value by gn, so a renamed or
  removed config fails instead of silently emptying the target configuration."""
  seen = set()
  for what in ('cflags', 'cflags_c', 'cflags_cc', 'defines', 'include_dirs'):
    for line in open(os.path.join(ABI_DIR, what + '.txt')):
      if line.strip().startswith('From '):
        seen.add(line.split()[1])
  missing = [c for c in ABI_CONFIGS if c not in seen]
  if missing:
    sys.exit('addon_toolchain.py: gn attributes nothing to %s' % missing)
  # The ABI identity itself: the derived include dirs must reach Chromium's
  # libc++ (its __config_site sets _LIBCPP_ABI_NAMESPACE Cr, which electron.exe's
  # std-typed exports carry), else an addon would silently compile against
  # another libc++.
  dirs = [os.path.normpath(os.path.join(SRC, d[2:]))
          for d in _blamed('include_dirs')]
  dirs += [a[2:] for a in (_rebase(t) for t in _blamed('cflags_cc'))
           if a.startswith('-I')]
  site = [d for d in dirs if os.path.isfile(os.path.join(d, '__config_site'))]
  if not site or not re.search(r'^#define _LIBCPP_ABI_NAMESPACE Cr$',
                               open(os.path.join(site[0], '__config_site')).read(),
                               re.M) or not any(
      os.path.isfile(os.path.join(d, '__config')) for d in dirs):
    sys.exit('addon_toolchain.py: the derived configuration does not reach '
             "Chromium's libc++ (__config_site with _LIBCPP_ABI_NAMESPACE Cr)")


def _abi_flags(cxx):
  _check_abi_configs()
  toks = _blamed('cflags') + _blamed('cflags_cc' if cxx else 'cflags_c')
  flags, i = [], 0
  while i < len(toks):
    unit = toks[i:i + 2] if toks[i] in ('-Xclang', '-mllvm') else toks[i:i + 1]
    i += len(unit)
    if not (_DIAGNOSTIC.match(unit[-1]) or _WHOLE_PROGRAM.match(unit[-1])):
      flags += [_rebase(a) for a in unit]
  flags += ['-D' + d for d in _blamed('defines')]
  for d in _blamed('include_dirs'):  # source-absolute: //dir/
    flags.append('-I' + os.path.normpath(os.path.join(SRC, d[2:])))
  return flags


def _rule_command(rule):
  text = open(os.path.join(OUT, 'toolchain.ninja')).read()
  m = re.search(r'^rule %s\n  command = (.*)$' % rule, text, re.M)
  return [_rebase(t) for t in shlex.split(m.group(1))]


def _libcxx_objects():
  text = open(os.path.join(OUT, 'obj/buildtools/third_party/libc++/libc++.ninja')).read()
  return [os.path.join(OUT, m.group(1))
          for m in re.finditer(r'^build (\S+): cxx ', text, re.M)]


def _cxx_runtime():
  """Chromium's C++ runtime as libraries: libc++ archived (mode cxxlib, made by
  vscode_native.ninja) and libc++abi.lib. Linked as archives, an image takes
  only the members it needs, as a C++ runtime library is linked (Chromium's
  libc++ is a static_library on every platform but Windows, BUILD.gn:55-61,
  where it is a source_set; libc++abi is a static_library everywhere). Given as
  an object list every member is forced in, including functional.obj, whose
  out-of-line ~bad_function_call/vtable (_LIBCPP_BUILDING_LIBRARY key
  function, __config:159-170) collide with the COMDAT copies an
  exception-enabled addon TU emits for `throw bad_function_call()`
  (lld/COFF/SymbolTable.cpp addRegular/addComdat: regular vs COMDAT is a
  duplicate); Chromium's own TUs are built without exceptions and never emit
  them."""
  text = open(os.path.join(OUT, 'obj/buildtools/third_party/libc++abi/libc++abi.ninja')).read()
  abi = [os.path.join(OUT, m.group(1))
         for m in re.finditer(r'^build (\S+): alink ', text, re.M)]
  return [os.path.join(ABI_DIR, 'libc++.lib')] + abi


def compile_cmd(cxx, args):
  out = src = None
  rest = []
  i = 0
  while i < len(args):
    a = args[i]
    if a == '-o':
      out = args[i + 1]; i += 2; continue
    if a == '-MF':
      rest.append('/clang:-MF' + args[i + 1]); i += 2; continue
    if a == '-MMD':
      rest.append('/clang:-MMD')
    elif a == '-c':
      pass
    elif not a.startswith(('/', '-')) or os.path.isfile(a):
      if src is not None:
        sys.exit('addon_toolchain.py: two inputs: %s, %s' % (src, a))
      src = a
    elif a.startswith(('/', '-D', '-U', '-I', '-std:')):
      rest.append(a)  # cl syntax: gyp_make_win.py flags, gyp defines/includes
    else:
      sys.exit('addon_toolchain.py: unexpected compiler argument: ' + a)
    i += 1
  # Debug information format, as the product's own rule for this target
  # (build/config/compiler/BUILD.gn config("symbols"), target_cpu "arm"): the
  # *-windows-gnu triple's default debug format is DWARF, which lld-link
  # leaves in the image; with -gcodeview the debug information a module asks
  # for (/Z7, /Zi) is CodeView and goes into the PDB, as cl.exe's does.
  if any(f in ('/Z7', '/Zi', '/ZI') for f in rest):
    rest.append('-gcodeview')
  clang_cl = _rule_command('cxx' if cxx else 'cc')[0]
  return ([clang_cl, '/nologo', '-Werror=unknown-argument'] +
          _abi_flags(cxx) + rest + ['/c', src, '/Fo' + out])


def link_cmd(args):
  out = None
  shared = False
  whole = False
  rest = []
  i = 0
  while i < len(args):
    a = args[i]
    if a == '-o':
      out = args[i + 1]; i += 2; continue
    if a == '-shared':
      shared = True
    elif a in ('-Wl,--whole-archive', '-Wl,--no-whole-archive'):
      whole = a == '-Wl,--whole-archive'  # cmd_solink: link archives whole
    elif a.startswith('-Wl,-soname=') or a in ('-Wl,--start-group',
                                               '-Wl,--end-group'):
      pass  # POSIX soname / link-order forms of the make generator's rules
    elif whole and a.lower().endswith(('.a', '.lib')):
      rest.append('/WHOLEARCHIVE:' + a)
    elif a.startswith('/') and not os.path.isfile(a):
      rest.append(a)  # link syntax from gyp_make_win.py
    elif a.startswith('-'):
      sys.exit('addon_toolchain.py: unexpected linker argument: ' + a)
    elif a.lower().endswith('.dll'):
      rest.append(a + '.lib')  # a gyp shared_library dependency: its implib
    elif os.path.exists(a) or a.lower().endswith(('.lib', '.obj')):
      rest.append(a)  # an object/archive, or a library found by -libpath
    else:
      sys.exit('addon_toolchain.py: unexpected linker input %r in %r'
               % (a, args))
    i += 1
  if not shared:
    rule = 'link'
  elif out.endswith('.node'):
    rule = 'solink_module'
  else:
    rule = 'solink'
  cmd = []
  for t in _rule_command(rule):
    if t.startswith('@'):
      cmd += rest + _cxx_runtime()  # in the GN rule: the target's rsp
      continue
    t = t.replace('${output_dir}/${target_output_name}${output_extension}', out)
    t = t.replace('${output_dir}/${target_output_name}',
                  os.path.splitext(out)[0])
    cmd.append(t)
  return cmd


def cxxlib_cmd(out):
  """Archives Chromium's libc++ objects with the Electron toolchain's alink."""
  lib = _rule_command('alink')[0]
  return [lib, '/lib', '/OUT:' + out, '/nologo'] + _libcxx_objects()


def _linker_env():
  """lld-link, like link.exe, prepends the LINK and _LINK_ environment
  variables to its arguments unless /lldignoreenv is given
  (lld/COFF/DriverUtils.cpp:826-827, 921-930). Under make, LINK is the
  make/node-gyp variable naming this script, so it is not passed on."""
  return {k: v for k, v in os.environ.items() if k not in ('LINK', '_LINK_')}


def ar_cmd(args):
  if len(args) < 2 or args[0] != 'crs':
    sys.exit('addon_toolchain.py: unexpected archiver arguments: %s' % args)
  lib = _rule_command('alink')[0]
  return [lib, '/lib', '/OUT:' + args[1], '/nologo'] + args[2:]


def main():
  mode, args = sys.argv[1], sys.argv[2:]
  if mode in ('cc', 'cxx'):
    cmd = compile_cmd(mode == 'cxx', args)
  elif mode == 'link':
    cmd = link_cmd(args)
    if os.environ.get('WRT_ADDON_ECHO'):
      print(' '.join(shlex.quote(c) for c in cmd), file=sys.stderr)
    return subprocess.call(cmd, env=_linker_env())
  elif mode == 'ar':
    cmd = ar_cmd(args)
  elif mode == 'cxxlib':
    cmd = cxxlib_cmd(args[0])
  else:
    sys.exit('addon_toolchain.py: unknown mode ' + mode)
  if os.environ.get('WRT_ADDON_ECHO'):
    print(' '.join(shlex.quote(c) for c in cmd), file=sys.stderr)
  return subprocess.call(cmd, env=_linker_env())


if __name__ == '__main__':
  sys.exit(main())
