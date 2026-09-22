# mcc is Lua, so there is nothing here to compile.  What meson is for is
# running the tests -- all of them at once, emulators included -- reading
# their TAP, and installing the compiler somewhere.
project('mcc', version: '0.3',
  license: 'ISC',
  meson_version: '>=1.1')

lua = find_program('lua5.4', 'lua')
src = meson.current_source_dir()

# What a differential test needs.  A target with no toolchain is left out
# here rather than failed: the answer does not change between runs, so it
# is settled at setup instead of by starting a test that only reports the
# same thing.
rv_gcc = find_program('riscv64-linux-gnu-gcc', required: false)
a64_gcc = find_program('aarch64-linux-gnu-gcc', required: false)
a64_as = find_program('aarch64-linux-gnu-as', required: false)
qemu_a64 = find_program('qemu-aarch64', required: false)
rv_as = find_program('riscv64-linux-gnu-as', required: false)
qemu_rv = find_program('qemu-riscv64', required: false)
qemu_xt = find_program('qemu-system-xtensa', required: false)

xt_gcc = run_command('sh', '-c',
  'ls "$HOME"/.espressif/tools/xtensa-esp*-elf/*/xtensa-esp*-elf/bin/' +
  'xtensa-esp32-elf-gcc 2>/dev/null | head -1',
  check: true).stdout().strip()

# 32-bit x86 runs here, so it needs no emulator; what it needs is the
# system compiler's 32-bit half, which not every install has.
m32 = run_command('sh', '-c',
  'd=$(mktemp -d) || exit 1; echo "int main(void){return 0;}" > "$d/a.c"; ' +
  'gcc -m32 -o "$d/a" "$d/a.c" >/dev/null 2>&1; r=$?; rm -rf "$d"; exit $r',
  check: false)

have_rv = rv_gcc.found() and qemu_rv.found()
have_a64 = a64_gcc.found() and qemu_a64.found()
have_xt = qemu_xt.found() and xt_gcc != ''

lua_src = get_option('lua_src')
if lua_src == ''
  lua_src = run_command('sh', '-c', 'printf %s "${LUA_SRC:-}"',
    check: true).stdout()
endif

env = environment()
if lua_src != ''
  env.set('LUA_SRC', lua_src)
endif

compdir = get_option('datadir') / 'mcc'

ready = {'amd64': true, 'riscv64': have_rv, 'riscv32': rv_as.found(),
         'xtensa': have_xt, 'arm64': have_a64,
         'i386': m32.returncode() == 0}
suite = {'amd64': 'amd64', 'riscv64': 'riscv', 'riscv32': 'riscv',
         'xtensa': 'xtensa', 'arm64': 'arm64', 'i386': 'i386'}

# ---- what of C this compiler takes ----
#
# One small program per feature, against gcc's build of the same lines.  A
# whole project is a slow way to find out that a designated initialiser is
# not supported; this says so in a second.
test('ldscript', lua, args: [files('test/ldscript.lua')],
  protocol: 'tap', suite: 'unit', workdir: src, timeout: 120)
test('ar', lua, args: [files('test/ar.lua')],
  protocol: 'tap', suite: 'unit', workdir: src, timeout: 120)
test('compat', lua, args: [files('test/compat.lua')],
  protocol: 'tap', suite: 'unit', workdir: src, timeout: 300)
test('lua55', lua, args: [files('test/lua55.lua')],
  protocol: 'tap', suite: 'unit', workdir: src, timeout: 60)

# The 16-bit half, on the machine.  Everything else here runs code the
# processor reads in 32 or 64-bit mode, and `.code16gcc` is a
# different encoding of the same instructions: a boot sector and qemu
# are the only way to find out whether it is the right one.
qemu_x86 = find_program('qemu-system-x86_64', required: false)
if qemu_x86.found()
  test('rmode', lua, args: [files('test/rmode.lua')],
    protocol: 'tap', suite: 'unit', workdir: src, timeout: 180)
endif

# And the same instructions against gas, for everything the compiler
# makes in 16-bit mode.  What is compared is which instructions they
# are, not the bytes: gas picks a shorter form for a load from a
# fixed address, which is a byte and not a difference.
test('as16', lua, args: [files('test/as16.lua')],
  protocol: 'tap', suite: 'unit', workdir: src, timeout: 600)

# The instructions that take no operand and whose size letter is the
# only thing that says how wide they are.  The prefix asks for the
# width the mode does not give, so one letter means opposite bytes in
# 16-bit and 32-bit code.
test('asbare', lua, args: [files('test/asbare.lua')],
  protocol: 'tap', suite: 'unit', workdir: src, timeout: 120)

# A name in a 16-bit immediate, and the relocation over it.  The
# relocation has to be as wide as the field or it writes past the
# immediate and into the instruction after it.
test('as16rel', lua, args: [files('test/as16rel.lua')],
  protocol: 'tap', suite: 'unit', workdir: src, timeout: 120)

# Spellings a test program cannot hold: CRLF endings, a splice inside a
# comment, digraphs, and what a name and a wide literal may be written
# with.
test('lex', lua, args: [files('test/lex.lua')],
  protocol: 'tap', suite: 'unit', workdir: src, timeout: 300)

# The blocks read off a recorded function: a straight run, an if with
# two arms, a loop with a back edge, and a label straight after a
# branch.  Written as records by hand, so nothing is compiled.
test('ir', lua, args: [files('test/ir.lua')],
  protocol: 'tap', suite: 'unit', workdir: src, timeout: 300)

# What the peephole promises about the code it leaves behind.  A rule
# that stops firing costs bytes and fails nothing else.
test('peep', lua, args: [files('test/peep.lua')],
  protocol: 'tap', suite: 'unit', workdir: src, timeout: 600)

# The one place this compiler leaves Lua.  Each backend has to answer
# every question, and the posix one has to give the same answers with
# luaposix and without it -- that fallback is what a box with nothing
# but stock Lua uses and nothing else exercises it.
test('sys', lua, args: [files('test/sys.lua')],
  protocol: 'tap', suite: 'unit', workdir: src, timeout: 300)

# The promises the driver makes about the machine flags it takes and
# does not implement.  Each one is a claim about what the emitter
# never does, and a claim in a comment is a claim nobody checks.
test('invariants', lua, args: [files('test/invariants.lua')],
  protocol: 'tap', suite: 'unit', workdir: src, timeout: 600)

# ---- the driver, as a build system would use it ----
if ready['amd64']
  test('foreign', lua, args: [files('test/foreign.lua')],
    protocol: 'tap', suite: 'amd64', workdir: src, timeout: 300)
  test('elfobj', lua, args: [files('test/elfobj.lua')],
    protocol: 'tap', suite: 'amd64', workdir: src, timeout: 300)
endif

test('asdata', lua, args: [files('test/asdata.lua')],
  protocol: 'tap', suite: 'lua', workdir: src, timeout: 120, env: env)

# ---- reading an object back ----
#
# The reader against nm and readelf, and the disassembler against
# objdump and against this compiler's own assembler.
if ready['amd64']
  test('elfread', lua, args: [files('test/elfread.lua')],
    protocol: 'tap', suite: 'amd64', workdir: src, timeout: 300)
  test('disas', lua, args: [files('test/disas.lua')],
    protocol: 'tap', suite: 'amd64', workdir: src, timeout: 600)
endif

test('drive', lua, args: [files('test/drive.lua')],
  protocol: 'tap', suite: 'unit', workdir: src, timeout: 300)

# Code nothing can reach is not compiled, on every target.
foreach tgt : ['amd64', 'riscv64', 'riscv32', 'xtensa', 'arm64', 'i386']
  test(tgt + '-dead', lua, args: [files('test/dead.lua'), tgt],
    protocol: 'tap', suite: 'unit', workdir: src, timeout: 120, env: env)
endforeach

# ---- the code generator on its own ----
foreach t : ['amd64', 'riscv']
  test(t + '-codegen', lua, args: [files('test/' + t + '.lua')],
    protocol: 'tap', suite: 'unit', workdir: src)
endforeach

# ---- generated code, assembled and run ----
foreach tgt : ['amd64', 'riscv64', 'riscv32', 'arm64']
  if ready[tgt]
    test(tgt + '-exec', lua, args: [files('test/exec.lua'), tgt],
      protocol: 'tap', suite: suite[tgt], workdir: src, timeout: 120)
  endif
endforeach

# position independent code reaching an object another unit owns
foreach tgt : ['amd64', 'riscv64', 'arm64']
  if ready[tgt]
    test(tgt + '-pic', lua, args: [files('test/pic.lua'), tgt],
      protocol: 'tap', suite: suite[tgt], workdir: src, timeout: 120)
  endif
endforeach

# ---- whole programs against the system compiler ----
#
# `wide` forces the lowering a 32-bit target uses onto a 64-bit one, which
# is the only way to run it against a compiler that has the type natively.
cases = ['prog', 'types', 'flt', 'init', 'va', 'abi', 'lang', 'asm', 'wide',
         'rec', 'recint', 'wstr', 'atomic', 'cplx', 'vla', 'cleanup', 'implicit',
         'brret']
widecases = ['prog', 'types', 'flt', 'init', 'va', 'abi', 'lang', 'wide']

# Why a case does not run on a target.
skip = {}

# Xtensa runs nothing here.  The simulator takes minutes over what the
# other three do in seconds, and it is the slowest thing in the suite by
# a wide margin, so waiting on it costs more than it finds.  What xtensa
# still gets is everything that needs no simulator: the code generator
# tests, the assembler against the real one, and a whole Lua tree
# compiled one file at a time.
foreach tgt : ['amd64', 'riscv64', 'arm64', 'i386']
  if ready[tgt]
    out = skip.get(tgt, {})
    foreach c : cases
      if out.get(c, '') == ''
        test(tgt + '-' + c, lua, args: [files('test/cc.lua'), tgt, c],
          protocol: 'tap', suite: suite[tgt], workdir: src, timeout: 300)
      endif
    endforeach
  endif
endforeach

# The peephole must not change what a program answers, so every case
# runs again with it switched on.
foreach tgt : ['amd64', 'riscv64', 'arm64', 'i386']
  if ready[tgt]
    out = skip.get(tgt, {})
    foreach c : cases
      if out.get(c, '') == ''
        test(tgt + '-' + c + '-opt', lua,
          args: [files('test/cc.lua'), tgt, c, 'opt'],
          protocol: 'tap', suite: suite[tgt], workdir: src, timeout: 300)
      endif
    endforeach
  endif
endforeach

# The x87 extended type, which only amd64 has.
if ready['amd64']
  test('amd64-ldbl', lua, args: [files('test/cc.lua'), 'amd64', 'ldbl'],
    protocol: 'tap', suite: 'amd64', workdir: src, timeout: 300)
  test('amd64-ldbl-opt', lua,
    args: [files('test/cc.lua'), 'amd64', 'ldbl', 'opt'],
    protocol: 'tap', suite: 'amd64', workdir: src, timeout: 300)
endif

# A 128-bit scalar, which every 64-bit target here claims to have.
foreach tgt : ['amd64', 'riscv64', 'arm64']
  if ready[tgt]
    test(tgt + '-i128', lua, args: [files('test/cc.lua'), tgt, 'i128'],
      protocol: 'tap', suite: suite[tgt], workdir: src, timeout: 300)
    test(tgt + '-i128-opt', lua,
      args: [files('test/cc.lua'), tgt, 'i128', 'opt'],
      protocol: 'tap', suite: suite[tgt], workdir: src, timeout: 300)
  endif
endforeach

# The hardening a kernel builds with must not change an answer either.
if ready['amd64']
  out = skip.get('amd64', {})
  foreach c : cases
    if out.get(c, '') == ''
      test('amd64-' + c + '-hard', lua,
        args: [files('test/cc.lua'), 'amd64', c, 'hard'],
        protocol: 'tap', suite: 'amd64', workdir: src, timeout: 300)
    endif
  endforeach
endif

foreach tgt : ['amd64', 'riscv64']
  if ready[tgt]
    foreach c : widecases
      test(tgt + '-' + c + '-wide', lua,
        args: [files('test/cc.lua'), tgt, c, 'wide'],
        protocol: 'tap', suite: suite[tgt], workdir: src, timeout: 300)
    endforeach
  endif
endforeach

# ---- the assembler against the real one ----
test('amd64-as', lua, args: [files('test/asdiff.lua'), 'amd64'],
  protocol: 'tap', suite: 'amd64', workdir: src, timeout: 900, env: env)
if rv_as.found()
  test('riscv-as', lua, args: [files('test/asdiff.lua'), 'riscv'],
    protocol: 'tap', suite: 'riscv', workdir: src, timeout: 900, env: env)
endif
if a64_as.found()
  test('arm64-as', lua, args: [files('test/asdiff.lua'), 'arm64'],
    protocol: 'tap', suite: 'arm64', workdir: src, timeout: 900, env: env)
endif
if have_xt
  test('xtensa-as', lua, args: [files('test/asdiff.lua'), 'xtensa'],
    protocol: 'tap', suite: 'xtensa', workdir: src, timeout: 900, env: env)
endif

# ---- a program built by nothing but this compiler ----
selfcases = {
  'amd64': ['prog', 'types', 'lang', 'va', 'init'],
  'arm64': ['prog', 'types', 'lang', 'va', 'init'],
  'riscv64': ['prog', 'types', 'lang', 'va', 'init'],
  'i386': ['prog', 'types', 'lang', 'va', 'init'],
}
foreach tgt, list : selfcases
  if ready[tgt]
    foreach c : list
      test(tgt + '-self-' + c, lua, args: [files('test/self.lua'), tgt, c],
        protocol: 'tap', suite: suite[tgt], workdir: src, timeout: 600)
    endforeach
  endif
endforeach

# `-mregparm=3` and a four byte stack boundary are the conventions a
# kernel's real mode code is built with, and they can only be measured
# against a build of everything: libc and libgcc do not speak them.
if ready['i386']
  foreach c : selfcases['i386']
    foreach v : ['regparm', 'boot']
      test('i386-self-' + c + '-' + v, lua,
        args: [files('test/self.lua'), 'i386', c, v],
        protocol: 'tap', suite: 'i386', workdir: src, timeout: 600)
    endforeach
  endforeach
endif

# ---- a whole Lua tree, one source at a time ----
#
# The list is taken at setup so that each file is its own test and the lot
# of them run side by side.
if lua_src != ''
  # meson has no glob of its own on purpose; the shell has one
  sources = run_command('sh', '-c', 'ls ' + lua_src + '/*.c 2>/dev/null',
    check: true).stdout().strip().split('\n')

  # onelua is the same sources again in one file, and the system compiler
  # refuses loslib against these headers too: nothing there declares
  # struct tm or system().
  notours = ['onelua', 'loslib']

  foreach tgt : ['amd64', 'riscv64', 'riscv32', 'xtensa', 'arm64']
    if ready[tgt]
      foreach f : sources
        base = f.split('/')[-1].split('.c')[0]
        if f != '' and base not in notours
          test(tgt + '-lua-' + base, lua,
            args: [files('test/onefile.lua'), tgt, f],
            protocol: 'tap', suite: 'lua', workdir: src, timeout: 300,
            env: env)
        endif
      endforeach
    endif
  endforeach

  test('cpp', lua, args: [files('test/cppall.lua')],
    protocol: 'tap', suite: 'lua', workdir: src, timeout: 900, env: env)

  # A whole interpreter, built once by ninja rather than by each test that
  # wants one.  Two come out: ours and the system compiler's, so that any
  # difference can only be the code this compiler generates.
  runner = {'amd64': '', 'riscv64': 'qemu-riscv64 ', 'arm64': 'qemu-aarch64 '}
  testfiles = run_command(lua, files('test/testes.lua'), '-list',
    env: env, check: true).stdout().strip().split('\n')

  foreach tgt : ['amd64', 'riscv64', 'arm64']
    if ready[tgt] and get_option('slow_tests')
      luabin = custom_target('lua-' + tgt,
        output: ['lua-' + tgt, 'lua-' + tgt + '.ref'],
        command: [files('tools/buildlua'), tgt, '@OUTPUT0@', '@OUTPUT1@'],
        env: env, build_by_default: true, console: true)

      # a shared object is where the calling convention has to hold up
      # against code no part of this built
      if tgt == 'amd64'
        test('module-abi', lua,
          args: [files('test/mod.lua'), luabin[0], luabin[1]],
          protocol: 'tap', suite: 'lua', workdir: src, timeout: 300,
          env: env)
      endif

      test('luadiff-' + tgt, lua,
        args: [files('test/luadiff.lua'), luabin[0], luabin[1],
               runner[tgt]],
        protocol: 'tap', suite: 'lua', workdir: src, timeout: 300,
        env: env)

      # The upstream suite, a file at a time.  all.lua runs them in one
      # process, which is why it takes a minute; nothing in its preamble
      # needs a file to have run before, so each one gets that preamble to
      # itself and they all go at once.
      foreach f : testfiles
        test(tgt + '-testes-' + f.split('.lua')[0], lua,
          args: [files('test/testes.lua'), luabin[0], f, runner[tgt]],
          protocol: 'tap', suite: 'testes', workdir: src, timeout: 600,
          env: env)
      endforeach
    endif
  endforeach

  if get_option('slow_tests')
    # the one test that cannot be split: the second stage has to be built
    # by the first
    test('bootstrap-amd64', files('bootstrap'), args: ['amd64'],
      protocol: 'tap', suite: 'slow', workdir: src, timeout: 3600, env: env,
      priority: 100)
  endif
endif

# ---- installing ----

# Which commit this copy was built from, so a peer can check in one
# command that what is installed is what they were told to test.
vcs_tag(
  command: ['git', 'rev-parse', '--short=10', 'HEAD'],
  input: 'tools/mccbuild.lua.in',
  output: 'mccbuild.lua',
  fallback: 'unknown',
  install: true,
  install_dir: compdir)

install_data(
  files('ar.lua', 'archive.lua', 'as.lua', 'buf.lua', 'cc.lua', 'cpp.lua',
        'data.lua', 'drive.lua', 'gen.lua', 'ld.lua', 'lex.lua', 'link.lua',
        'ldscript.lua', 'md.lua', 'elf.lua', 'elfread.lua',
        'dis.lua', 'nm.lua', 'objdump.lua', 'parse.lua',
        'peep.lua',
        'ir.lua',
        'so.lua', 'strict.lua', 'sys.lua', 'tree.lua', 'types.lua',
        'widert.lua'),
  install_dir: compdir)
install_data(files('as/amd64.lua', 'as/arm64.lua', 'as/riscv.lua',
                   'as/xtensa.lua'),
  install_dir: compdir / 'as')
install_data(files('dis/amd64.lua'), install_dir: compdir / 'dis')
install_data(files('sys/posix.lua', 'sys/luaos.lua'),
  install_dir: compdir / 'sys')
install_data(
  files('target/amd64.lua', 'target/arm64.lua', 'target/riscv.lua',
        'target/riscv32.lua', 'target/riscv64.lua', 'target/xtensa.lua',
        'target/i386.lua'),
  install_dir: compdir / 'target')
install_subdir('include', install_dir: compdir)
install_subdir('rt', install_dir: compdir)

conf = configuration_data()
conf.set('LUA', lua.full_path())
conf.set('COMPDIR', get_option('prefix') / compdir)
foreach w : ['mcc', 'mas', 'mld', 'mar', 'mnm', 'mobjdump']
  configure_file(input: 'tools/' + w + '.in', output: w,
    configuration: conf, install: true,
    install_dir: get_option('bindir'), install_mode: 'rwxr-xr-x')
endforeach
