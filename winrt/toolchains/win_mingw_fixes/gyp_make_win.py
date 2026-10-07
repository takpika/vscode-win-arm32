"""gyp generator: Windows (OS=win) targets as Makefiles, for a cross build.

node-gyp runs gyp with this file as the format (-f <path>/gyp_make_win.py) when
it builds Node native addons for Windows on 32-bit ARM from a Linux host. gyp's
Windows generators (msvs, ninja-win) need a Windows host (MSBuild, `ninja -t
msvc`); its make generator runs anywhere but knows only POSIX flavors: it
ignores msvs_settings and names products the POSIX way. This generator is the
make generator plus, for every target, what gyp's own Windows translation
(gyp.msvs_emulation.MsvsSettings, the code its ninja-win generator uses) makes
of the target's msvs_settings -- compiler flags, computed defines, linker flags,
library names -- and Windows product names (.exe/.dll/.lib). The flags are cl /
link syntax; CC/CXX/LINK are addon_toolchain.py, which hands them to clang-cl /
lld-link.
"""

import copy
import os
import shutil
import tempfile

import gyp.MSVSUtil
import gyp.msvs_emulation
from gyp.generator import make as _make

generator_default_variables = copy.copy(_make.generator_default_variables)
generator_default_variables.update({
    'EXECUTABLE_PREFIX': '',
    'EXECUTABLE_SUFFIX': '.exe',
    'STATIC_LIB_PREFIX': '',
    'STATIC_LIB_SUFFIX': '.lib',
    'SHARED_LIB_PREFIX': '',
    'SHARED_LIB_SUFFIX': '.dll',
})
for _name in dir(_make):
  if _name.startswith('generator_') and _name not in globals():
    globals()[_name] = getattr(_make, _name)



def CalculateVariables(default_variables, params):
  _make.CalculateVariables(default_variables, params)
  default_variables['OS'] = 'win'
  gyp.msvs_emulation.CalculateCommonVariables(default_variables, params)


def _LocalizeAbsoluteSources(spec):
  """gyp's make generator writes object rules only for sources under the
  target's directory ($(srcdir)/%.cc) or generated into $(obj); an absolute
  source -- node-gyp's addon.gypi adds <(node_gyp_dir)/src/win_delay_load_hook.cc
  to every Windows addon -- gets an object path with no rule. The Windows
  generators compile it in the target's own intermediate directory; here each
  such source is copied by a gyp `copies` step to build/<target>/ (node-gyp's
  build directory, under the target's directory) and compiled from there."""
  sources = []
  for source in spec.get('sources', []):
    if os.path.isabs(source):
      dest = 'build/abs_sources/' + spec['target_name']
      spec.setdefault('copies', []).append(
          {'destination': dest, 'files': [source]})
      source = dest + '/' + os.path.basename(source)
    sources.append(source)
  if sources:
    spec['sources'] = sources


def GenerateOutput(target_list, target_dicts, data, params):
  generator_flags = params.get('generator_flags', {})
  # GetLdflags writes the manifest gyp's Windows generators would merge; this
  # generator has lld-link produce it (below), so those files go to a scratch
  # directory instead of the module tree.
  manifest_dir = tempfile.mkdtemp(prefix='gyp_make_win_')
  for qualified_target in target_list:
    spec = target_dicts[qualified_target]
    _LocalizeAbsoluteSources(spec)
    settings = gyp.msvs_emulation.MsvsSettings(spec, generator_flags)
    # Windows product names (gyp's own table; node-gyp's addon.gypi sets the
    # .node extension of addons itself).
    if spec['type'] in gyp.MSVSUtil.TARGET_TYPE_EXT:
      spec.setdefault('product_extension',
                      gyp.MSVSUtil.TARGET_TYPE_EXT[spec['type']])
      spec.setdefault('product_prefix', '')
    # Product layout: gyp's Windows generators link a DLL or loadable module
    # straight into the product directory (MSBuild OutDir / ninja-win
    # PRODUCT_DIR); the make generator links it into $(obj).<toolset>/ and
    # copies it to $(builddir), leaving a second copy of the binary among the
    # intermediates. With product_dir = $(builddir) (make's PRODUCT_DIR) its
    # output is its install path and it is linked there directly, as on
    # Windows; a product_dir the .gyp file sets is kept.
    if spec['type'] in ('loadable_module', 'shared_library'):
      spec.setdefault('product_dir', '$(builddir)')
    if 'libraries' in spec:
      # gyp quotes library paths for shells (node-gyp's -l"<node.lib>");
      # MsvsSettings.AdjustLibraries expects bare names, as in the ninja-win
      # generator after its own path expansion.
      # $(Configuration) is an MSBuild macro (node-gyp's node.lib path,
      # <nodedir>/$(Configuration)/node.lib); MSBuild expands it to the
      # configuration being built, node-gyp's default one.
      config_name = spec['default_configuration']
      spec['libraries'] = settings.AdjustLibraries(
          [lib.replace('"', '').replace('$(Configuration)', config_name)
           for lib in spec['libraries']])
    for name, config in spec['configurations'].items():
      # gyp's Windows generators compile and link with what msvs_settings
      # translate to; cflags/ldflags are POSIX-only gyp keys they ignore.
      config['defines'] = (config.get('defines', []) +
                           settings.GetComputedDefines(name))
      config['cflags'] = settings.GetCflags(name)
      config['cflags_c'] = settings.GetCflagsC(name)
      config['cflags_cc'] = settings.GetCflagsCC(name)
      ldflags, _, manifest_files = settings.GetLdflags(
          name, lambda p: p, lambda p, **kw: p, spec['target_name'],
          spec['target_name'], spec['type'] == 'executable', manifest_dir)
      # The manifest: gyp's Windows generators merge one manifest they
      # generate (trustInfo with the target's UAC settings; GetLdflags writes
      # it as <target>.generated.manifest) and any AdditionalManifestFiles,
      # and embed the result. lld-link generates and embeds that same trustInfo
      # itself from /MANIFESTUAC; additional manifests are not handled here.
      generated = spec['target_name'] + '.generated.manifest'
      if [f for f in manifest_files if f != generated]:
        raise Exception('gyp_make_win.py: %s: AdditionalManifestFiles %s are '
                        'not supported' % (spec['target_name'], manifest_files))
      # lld-link's defaults are gyp's: level='asInvoker' uiAccess='false'
      # (lld/COFF Config.h manifestLevel/manifestUIAccess); /MANIFESTUAC takes
      # one space-separated value, which the make generator does not quote.
      uac = []
      if manifest_files:
        if settings._Setting(('VCLinkerTool', 'EnableUAC'), name,
                             default='true') != 'true':
          uac = ['/MANIFESTUAC:NO']
        elif (settings._Setting(('VCLinkerTool', 'UACExecutionLevel'), name,
                                default='0') != '0' or
              settings._Setting(('VCLinkerTool', 'UACUIAccess'), name,
                                default='false') != 'false'):
          raise Exception('gyp_make_win.py: %s: non-default UAC settings are '
                          'not supported' % spec['target_name'])
      # The output and PDB come from the make rule.
      config['ldflags'] = [
          f for f in ldflags
          if not f.startswith(('/OUT:', '/PDB:', '/ManifestFile:'))
          and f not in ('/MANIFEST', '/MANIFESTUAC:NO')]
      if manifest_files:
        config['ldflags'] += ['/MANIFEST:EMBED'] + uac
  shutil.rmtree(manifest_dir)
  _make.GenerateOutput(target_list, target_dicts, data, params)
