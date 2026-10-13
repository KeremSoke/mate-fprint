project(
  'mate-fprint',
  ['vala', 'c'],
  version: '1.0.0',
  meson_version: '>= 0.59.0',
)

gnome = import('gnome')
i18n = import('i18n')
gtk = dependency('gtk+-3.0', version: '>= 3.22')
gio = dependency('gio-2.0', version: '>= 2.56')
math = meson.get_compiler('c').find_library('m')
datadir = get_option('prefix') / get_option('datadir')
localedir = get_option('prefix') / get_option('localedir')

add_project_arguments(
  '-DGETTEXT_PACKAGE="@0@"'.format(meson.project_name()),
  language: 'c',
)

conf = configuration_data()
conf.set('PACKAGE_VERSION', meson.project_version())
conf.set_quoted('PKGDATADIR', datadir / 'mate-fprint')
conf.set_quoted('GETTEXT_PACKAGE', meson.project_name())
conf.set_quoted('LOCALEDIR', localedir)

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
desktop_file = i18n.merge_file(
  input: 'data/org.mate.fprint.desktop.in',
  output: 'org.mate.fprint.desktop',
  type: 'desktop',
  po_dir: 'po',
  install: true,
  install_dir: datadir / 'applications',
)
metainfo_file = i18n.merge_file(
  input: 'data/org.mate.fprint.metainfo.xml.in',
  output: 'org.mate.fprint.metainfo.xml',
  po_dir: 'po',
  install: true,
  install_dir: datadir / 'metainfo',
)
install_data('data/pam-configs/mate-fprint', install_dir: '/usr/share/pam-configs')

desktop_validate = find_program('desktop-file-validate', required: false)
if desktop_validate.found()
  test('desktop file', desktop_validate, args: desktop_file)
endif

appstreamcli = find_program('appstreamcli', required: false)
if appstreamcli.found()
  test(
    'appstream metadata',
    appstreamcli,
    args: ['validate', '--no-net', metainfo_file],
  )
endif

subdir('po')
