# The unix backend of mcc.sys, compiled by the mcc in this tree.  It
# does not exist yet while it builds, so the driver runs on the luaos
# backend and is told the system by name.
sysunix = custom_target('sysunix',
  input: ['unix.c', src / 'drive.lua'],
  output: 'unix.so',
  command: [lua, '@INPUT1@', '--target=' + host_cpu + '-' + host_sys,
            '-shared', '-fPIC', '-O'] + lua_cflags +
           ['-o', '@OUTPUT@', '@INPUT0@'],
  env: {'MCC_SYS': 'luaos', 'MCC_SYS_SYSTEM': host_sys,
        'MCC_SYS_MACHINE': host_cpu},
  build_by_default: true,
  install: true,
  install_dir: compdir / 'mcc' / 'sys')
