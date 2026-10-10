project(
  'mate-fprint',
  ['vala', 'c'],
  version: '0.1.0',
  meson_version: '>= 0.59.0',
)

gnome = import('gnome')
gtk = dependency('gtk+-3.0', version: '>= 3.22')
gio = dependency('gio-2.0', version: '>= 2.56')
math = meson.get_compiler('c').find_library('m')
datadir = get_option('prefix') / get_option('datadir')

conf = configuration_data()
conf.set('PACKAGE_VERSION', meson.project_version())
conf.set_quoted('PKGDATADIR', datadir / 'mate-fprint')

config_file = configure_file(
  input: 'src/config.vala.in',
  output: 'config.vala',
  configuration: conf,
)

executable(
  'mate-fprint',
  ['src/main.vala', config_file],
  dependencies: [gtk, gio, math],
  vala_args: ['--target-glib=2.56'],
  install: true,
)

install_data('data/mate-fprint.css', install_dir: datadir / 'mate-fprint')
install_data('data/org.mate.fprint.desktop', install_dir: datadir / 'applications')
install_data('data/org.mate.fprint.metainfo.xml', install_dir: datadir / 'metainfo')
install_data('data/pam-configs/mate-fprint', install_dir: '/usr/share/pam-configs')

desktop_validate = find_program('desktop-file-validate', required: false)
if desktop_validate.found()
  test('desktop file', desktop_validate, args: files('data/org.mate.fprint.desktop'))
endif

appstreamcli = find_program('appstreamcli', required: false)
if appstreamcli.found()
  test(
    'appstream metadata',
    appstreamcli,
    args: ['validate', '--no-net', files('data/org.mate.fprint.metainfo.xml')],
  )
endif
