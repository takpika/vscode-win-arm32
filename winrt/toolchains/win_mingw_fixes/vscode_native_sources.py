#!/usr/bin/env python3
"""Copies VSCode's native modules and their dependencies for the node-gyp pass.

usage: vscode_native_sources.py <node_modules> <dest node_modules> <modules list>
                                <depfile> <patches dir>

The native modules are the packages with a binding.gyp (what npm/yarn build
with node-gyp at install time): those at the top level of <node_modules> and,
among the packages they resolve to, any nested one. Their package.json
dependency closure (dependencies, and optionalDependencies that are present) is
resolved the way node's require() resolves it -- from the dependent package's
own node_modules up through its ancestors to the top level -- and the
top-level packages holding every resolved instance are copied to <dest>
(a nested instance is copied with the package that contains it).
The native modules' names are written to <modules list>, one per line, and
the source root, every copied directory and every copied file to <depfile> as
its dependencies (an edited file, an added or removed file or package re-runs
the copy and the build; ninja tracks a directory by its mtime, which changes
when an entry is added or removed). Computed from the fetched tree each run, so it
follows VSCode's lockfile.
Then <patches dir>/patches.json is applied to the copy: for each listed package,
every copy of it in the copied tree (top level or nested node_modules) must
have its version listed -- with a patch file, applied by `git apply` (exact
context, no fuzz; repository discovery stopped at the copy, and the result
verified by a reverse check), or null for a version that needs none -- and every
listed patch must have been applied to at least one copy of its own package and
version; anything else is an error.
The modules are built in a copy because the fetched tree is the build's
pinned input (the fetch-only `yarn install --ignore-scripts --frozen-lockfile`),
which the build must not modify, and a build's outputs (each module's build/)
belong under the build directory.
"""

import hashlib
import json
import re
import os
import shutil
import stat
import subprocess
import sys


def packages(node_modules):
  for entry in sorted(os.listdir(node_modules)):
    if entry.startswith('.'):
      continue
    if entry.startswith('@'):
      for sub in sorted(os.listdir(os.path.join(node_modules, entry))):
        yield entry + '/' + sub
    else:
      yield entry


def _tree_digest(root):
  h = hashlib.sha256()
  for d, dirs, files in sorted(os.walk(root)):
    dirs.sort()
    for f in sorted(files):
      p = os.path.join(d, f)
      if not os.path.islink(p):
        h.update(p.encode() + b'\0')
        with open(p, 'rb') as fh:
          h.update(hashlib.sha256(fh.read()).digest())
  return h.hexdigest()


def apply_patches(dest, patches_dir):
  with open(os.path.join(patches_dir, 'patches.json')) as f:
    table = json.load(f)
  used = []
  applied = set()  # (package, version)
  for package, versions in sorted(table.items()):
    copies = []
    for root, dirs, files in os.walk(dest):
      if os.path.basename(root) == 'node_modules' or root == dest:
        here = os.path.join(root, package)
        if os.path.isfile(os.path.join(here, 'package.json')):
          copies.append(here)
    for copy in sorted(copies):
      with open(os.path.join(copy, 'package.json')) as f:
        version = json.load(f)['version']
      if version not in versions:
        sys.exit('vscode_native_sources.py: %s %s at %s is not in patches.json'
                 % (package, version, copy))
      patch = versions[version]
      if patch is None:
        continue
      path = os.path.abspath(os.path.join(patches_dir, patch))
      # git apply is all-or-nothing and refuses inexact context (no fuzz).
      # Inside a git work tree (the build directory is one) it would take the
      # patch paths as relative to that repository's root and skip ignored
      # paths with exit status 0, so repository discovery is stopped at the
      # copy; the reverse check then proves the patch is in place.
      # (git ignores a relative GIT_CEILING_DIRECTORIES entry, so it is made
      # absolute; a patch that changes no file is an error as well.)
      copy = os.path.abspath(copy)
      env = dict(os.environ,
                 GIT_CEILING_DIRECTORIES=os.path.dirname(copy))
      before = _tree_digest(copy)
      subprocess.check_call(['git', 'apply', '-p1', path], cwd=copy, env=env)
      subprocess.check_call(['git', 'apply', '--reverse', '--check', '-p1',
                             path], cwd=copy, env=env)
      if _tree_digest(copy) == before:
        sys.exit('vscode_native_sources.py: %s changed nothing in %s'
                 % (patch, copy))
      used.append(path)
      applied.add((package, version))
    for version, patch in versions.items():
      if patch and (package, version) not in applied:
        sys.exit('vscode_native_sources.py: no copy of %s %s to apply %s to'
                 % (package, version, patch))
  return sorted(set(used))


def _make_writable(tree):
  for root, dirs, files in os.walk(tree):
    for name in [root] + [os.path.join(root, f) for f in files]:
      if not os.path.islink(name):
        os.chmod(name, os.stat(name).st_mode | stat.S_IWUSR)


def _top(inst):
  parts = inst.split('/')
  return '/'.join(parts[:2] if parts[0].startswith('@') else parts[:1])


def resolve(src, frm, name):
  """node's require() resolution of package `name` from the package at `frm`
  (paths relative to `src`): <frm>/node_modules/<name>, then each ancestor's
  node_modules, up to the top level of `src`."""
  d = frm
  while True:
    candidate = os.path.join(d, 'node_modules', name) if d else name
    if os.path.isfile(os.path.join(src, candidate, 'package.json')):
      return candidate
    if not d:
      return None
    # up one package: strip "<...>/node_modules/<pkg>" (scoped: two parts)
    head, _, _ = d.rpartition('node_modules/')
    d = head.rstrip('/')


def main():
  src, dest, modules_list, depfile, patches_dir = sys.argv[1:]
  # Package instances (paths under src) reachable from the native modules by
  # node's resolution of their package.json dependencies.
  closure, todo = set(), [p for p in packages(src)
                          if os.path.isfile(os.path.join(src, p, 'binding.gyp'))]
  while todo:
    inst = todo.pop()
    if inst in closure:
      continue
    closure.add(inst)
    with open(os.path.join(src, inst, 'package.json')) as f:
      manifest = json.load(f)
    for name in manifest.get('dependencies', {}):
      found = resolve(src, inst, name)
      if found is None:
        sys.exit('vscode_native_sources.py: %s (needed by %s) does not '
                 'resolve in %s' % (name, inst, src))
      todo.append(found)
    for name in manifest.get('optionalDependencies', {}):
      found = resolve(src, inst, name)  # npm/yarn skip an absent optional one
      if found is not None:
        todo.append(found)
  # The native modules: every resolved instance with a binding.gyp, nested ones
  # included (npm/yarn build each of them with node-gyp at install time).
  native = sorted(i for i in closure
                  if os.path.isfile(os.path.join(src, i, 'binding.gyp')))
  # Each instance is copied at its own location; a nested instance comes with
  # the top-level package directory that contains it.
  tops = sorted({_top(i) for i in closure})
  # The fetched tree may be read-only (a pinned input), and copytree copies
  # permissions; the copy is the build's own and is made writable for the owner
  # (patches are applied to it, node-gyp writes build/ into it).
  if os.path.exists(dest):
    _make_writable(dest)
    shutil.rmtree(dest)
  for name in tops:
    shutil.copytree(os.path.join(src, name), os.path.join(dest, name),
                    symlinks=True)
  _make_writable(dest)
  patched = apply_patches(dest, patches_dir)
  # Inside the copied tree: deleting or replacing the tree also removes it,
  # so the build notices and copies again.
  with open(os.path.join(dest, '.vscode_native_sources'), 'w') as f:
    f.write('copied from %s\n' % src)
  with open(modules_list, 'w') as f:
    f.write(''.join(m + '\n' for m in native))
  # Files (edits) and directories (added or removed entries, incl. the
  # top-level node_modules for added packages) of the copied packages.
  deps = [patches_dir, os.path.join(patches_dir, 'patches.json')] + patched
  deps += [src] + sorted({os.path.join(src, n.split('/')[0]) for n in tops})
  for name in tops:
    for root, dirs, files in os.walk(os.path.join(src, name)):
      dirs.sort()
      deps.append(root)
      deps += [os.path.join(root, f) for f in sorted(files)]
  esc = lambda d: re.sub(r'([ #\\])', r'\\\1', d).replace('$', '$$')
  with open(depfile, 'w') as f:
    f.write('%s: %s\n' % (modules_list, ' '.join(esc(d) for d in deps)))
  print('%d native modules, %d package instances in %d top-level packages'
        % (len(native), len(closure), len(tops)))


if __name__ == '__main__':
  sys.exit(main())
