# The wrappers are made here and not at the top of the build tree, where
# a file named mcc would stand in the way of the mcc/ module directory.
foreach w : ['mcc', 'mas', 'mld', 'mar', 'mranlib', 'mnm', 'mobjdump', 'msize',
             'mstrip', 'mobjcopy']
  configure_file(input: w + '.in', output: w,
    configuration: conf, install: true,
    install_dir: get_option('bindir'), install_mode: 'rwxr-xr-x')
endforeach
